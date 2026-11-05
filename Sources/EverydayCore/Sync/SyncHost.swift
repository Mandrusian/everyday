import Foundation
import Network

/// Runs Wi‑Fi sync on the Mac: a Bonjour-advertised TCP listener plus a browser for other devices in the same
/// group. All work happens on one serial queue; `onChange` fires on the main queue after records changed here.
public final class SyncHost: @unchecked Sendable {
    public static let serviceType = "_everyday._tcp"
    public static let keyAccount = "sync.groupKey"

    public struct Seen: Sendable { public let name: String; public let at: Date }

    private let data: SyncData
    private let q = DispatchQueue(label: "everyday.sync")
    private var group: SyncGroup?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: (name: String, endpoint: NWEndpoint)] = [:]
    private var timer: DispatchSourceTimer?
    private var busy = false
    /// Offered with the pairing code: a device presenting this within 10 minutes gets accounts, keys and settings, once.
    private var offer: (token: String, until: Date)?
    /// Set after scanning a code that carries a setup token; sent with the first exchange.
    private var want: String?
    public var onSetup: (@Sendable (String) -> Void)?

    public private(set) var seen: [String: Seen] = [:]
    public private(set) var lastError: String?
    public var onChange: (@Sendable () -> Void)?
    public var onStatus: (@Sendable () -> Void)?

    public init(data: SyncData) { self.data = data }

    public var isPaired: Bool { group != nil || Keychain.get(Self.keyAccount).flatMap(SyncGroup.init(keyBase64:)) != nil }
    public var nearby: Int { q.sync { peers.count } }

    /// The code another device scans or types. Creates the group the first time. With `includeSetup`, the code also
    /// carries a one-time token that hands over accounts, keys and settings for the next 10 minutes.
    public func pairingURI(includeSetup: Bool) throws -> String {
        let g: SyncGroup
        if let x = Keychain.get(Self.keyAccount).flatMap(SyncGroup.init(keyBase64:)) { g = x } else { g = SyncGroup(); try Keychain.set(g.keyBase64, for: Self.keyAccount) }
        start()
        guard includeSetup else { q.sync { offer = nil }; return g.pairingURI }
        let token = SyncKeys.newDeviceID() + SyncKeys.newDeviceID()
        q.sync { offer = (token, Date().addingTimeInterval(600)) }
        return g.pairingURI + ":" + token
    }

    public func join(_ uri: String) throws {
        guard let g = SyncGroup(pairingURI: uri) else { throw SyncError.badCode }
        try Keychain.set(g.keyBase64, for: Self.keyAccount)
        let token = SyncGroup.setupToken(in: uri)
        stop(); q.sync { want = token }; start()
    }

    public func leave() {
        stop(); Keychain.delete(Self.keyAccount)
        try? data.db.delete("sync", id: "state")
        q.sync { seen = [:] }; status()
    }

    public func start() {
        guard let g = Keychain.get(Self.keyAccount).flatMap(SyncGroup.init(keyBase64:)) else { return }
        q.async { [self] in
            guard listener == nil else { return }
            group = g
            let me = data.deviceID, name = data.deviceName
            do {
                let l = try NWListener(using: .tcp)
                l.service = NWListener.Service(name: "everyday-\(me)", type: Self.serviceType, txtRecord: NWTXTRecord(["group": g.id, "device": me, "name": name]))
                l.newConnectionHandler = { [weak self] c in self?.serve(c) }
                l.stateUpdateHandler = { [weak self] s in if case .failed(let e) = s { self?.fail("Sync stopped: \(e.localizedDescription)") } }
                l.start(queue: q); listener = l
            } catch { fail("Couldn't open a port for sync: \(error.localizedDescription)"); return }

            let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
            b.start(queue: q); browser = b

            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 180, repeating: 180)
            t.setEventHandler { [weak self] in self?.syncAll() }
            t.resume(); timer = t
        }
    }

    public func stop() {
        q.sync {
            listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
            timer?.cancel(); timer = nil; peers = [:]; group = nil
        }
    }

    /// Sync with everyone nearby now.
    public func syncNow() { q.async { [self] in syncAll() } }

    // MARK: - On the queue

    private func found(_ results: Set<NWBrowser.Result>) {
        guard let g = group else { return }
        let me = data.deviceID
        var next: [String: (String, NWEndpoint)] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, txt["group"] == g.id, let dev = txt["device"], dev != me else { continue }
            next[dev] = (txt["name"] ?? "Device", r.endpoint)
        }
        let new = Set(next.keys).subtracting(peers.keys)
        peers = next.mapValues { (name: $0.0, endpoint: $0.1) }
        status()
        if !new.isEmpty { syncAll() }
    }

    private func syncAll() {
        guard let g = group, !busy, !peers.isEmpty else { return }
        busy = true
        let list = peers
        var remaining = list.count
        for (id, p) in list {
            let c = NWConnection(to: p.endpoint, using: .tcp)
            c.start(queue: q)
            var state = data.prepare()
            let hello = SyncHello(device: data.deviceID, name: data.deviceName, state: state, setupToken: want)
            send(c, g, hello) { [self] err in
                if let err { done(c, err); return }
                receive(c, g) { [self] result in
                    switch result {
                    case .failure(let e): done(c, e)
                    case .success(let theirs):
                        if let b = theirs.setup { want = nil; let msg = SyncSetup.apply(b); DispatchQueue.main.async { self.onSetup?(msg) } }
                        let changed = state.merge(theirs.state)
                        if data.finish(state, changed: changed) { DispatchQueue.main.async { self.onChange?() } }
                        seen[id] = Seen(name: theirs.name, at: Date()); lastError = nil
                        done(c, nil)
                    }
                }
            }
            func done(_ c: NWConnection, _ e: Error?) {
                c.cancel(); if let e { lastError = e.localizedDescription }
                remaining -= 1; if remaining == 0 { busy = false; status() }
            }
        }
    }

    private func serve(_ c: NWConnection) {
        guard let g = group else { c.cancel(); return }
        c.start(queue: q)
        receive(c, g) { [self] result in
            guard case .success(let theirs) = result else { c.cancel(); return }
            var state = data.prepare()
            let changed = state.merge(theirs.state)
            let any = data.finish(state, changed: changed)
            var reply = SyncHello(device: data.deviceID, name: data.deviceName, state: state)
            if let t = theirs.setupToken, let o = offer, o.token == t, o.until > Date() { reply.setup = SyncSetup.export(); offer = nil }
            send(c, g, reply) { _ in c.cancel() }
            seen[theirs.device] = Seen(name: theirs.name, at: Date())
            if any { DispatchQueue.main.async { self.onChange?() } }
            status()
        }
    }

    private func send(_ c: NWConnection, _ g: SyncGroup, _ h: SyncHello, _ done: @escaping (Error?) -> Void) {
        do {
            let body = try g.seal(JSONEncoder().encode(h))
            var len = UInt32(body.count).bigEndian
            let frame = Data(bytes: &len, count: 4) + body
            c.send(content: frame, completion: .contentProcessed { e in done(e) })
        } catch { done(error) }
    }

    private func receive(_ c: NWConnection, _ g: SyncGroup, _ done: @escaping (Result<SyncHello, Error>) -> Void) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { d, _, _, e in
            guard let d, d.count == 4, e == nil else { done(.failure(SyncError.io(e?.localizedDescription ?? "closed"))); return }
            let n = Int(d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard n > 0, n < 16 << 20 else { done(.failure(SyncError.format("frame size"))); return }
            self.readExactly(c, n, Data()) { body in
                guard let body else { done(.failure(SyncError.io("closed"))); return }
                do { done(.success(try JSONDecoder().decode(SyncHello.self, from: try g.open(body)))) }
                catch let e as SyncError { done(.failure(e)) }
                catch { done(.failure(SyncError.format(error.localizedDescription))) }
            }
        }
    }

    private func readExactly(_ c: NWConnection, _ n: Int, _ acc: Data, _ done: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: n - acc.count) { d, _, complete, e in
            guard let d, e == nil else { done(nil); return }
            let all = acc + d
            if all.count == n { done(all) } else if complete { done(nil) } else { self.readExactly(c, n, all, done) }
        }
    }

    private func fail(_ m: String) { lastError = m; status() }
    private func status() { DispatchQueue.main.async { self.onStatus?() } }
}
