import Foundation
import Network

/// A tiny scripted IMAP server for tests (plain TCP on localhost). Not a full implementation.
final class FakeImapServer: @unchecked Sendable {
    struct Msg { var flags: Set<String>; var raw: Data }
    private let lock = NSLock()
    var validity = 7
    var messages: [Int: Msg] = [:]
    var nextUID = 1
    private(set) var log: [String] = []
    private var listener: NWListener?
    var port: UInt16 = 0
    var rejectLogin = false

    func add(_ raw: String, flags: Set<String> = []) -> Int {
        lock.lock(); defer { lock.unlock() }
        let uid = nextUID; nextUID += 1
        messages[uid] = Msg(flags: flags, raw: Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        return uid
    }
    func remove(_ uid: Int) { lock.lock(); messages[uid] = nil; lock.unlock() }
    func setFlags(_ uid: Int, _ f: Set<String>) { lock.lock(); messages[uid]?.flags = f; lock.unlock() }
    func commands() -> [String] { lock.lock(); defer { lock.unlock() }; return log }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        final class Once: @unchecked Sendable { let k = NSLock(); var d = false; func take() -> Bool { k.lock(); defer { k.unlock() }; if d { return false }; d = true; return true } }
        let once = Once()
        port = try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { st in
                if case .ready = st, once.take() { cont.resume(returning: l.port?.rawValue ?? 0) }
                if case .failed(let e) = st, once.take() { cont.resume(throwing: e) }
            }
            l.start(queue: .global())
        }
    }
    func stop() { listener?.cancel() }

    private func send(_ c: NWConnection, _ s: String) { c.send(content: Data(s.utf8), completion: .contentProcessed { _ in }) }
    private func send(_ c: NWConnection, data: Data) { c.send(content: data, completion: .contentProcessed { _ in }) }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global())
        send(c, "* OK fake imap ready\r\n")
        var buf = Data()
        var pendingAppend: (tag: String, need: Int)?
        func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buf.append(data) }
                while true {
                    if let p = pendingAppend {
                        guard buf.count >= p.need + 2 else { break }
                        buf.removeFirst(p.need + 2)
                        self.send(c, "\(p.tag) OK APPEND completed\r\n"); pendingAppend = nil; continue
                    }
                    guard let r = buf.range(of: Data([13, 10])) else { break }
                    let line = String(decoding: buf.subdata(in: buf.startIndex..<r.lowerBound), as: UTF8.self)
                    buf.removeSubrange(buf.startIndex..<r.upperBound)
                    if let need = self.process(line, c) { pendingAppend = need }
                }
                if err == nil && !done { loop() } else { c.cancel() }
            }
        }
        loop()
    }

    private func process(_ line: String, _ c: NWConnection) -> (tag: String, need: Int)? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let tag = parts[0], cmd = parts[1]
        lock.lock(); log.append(cmd); lock.unlock()
        let up = cmd.uppercased()
        if up.hasPrefix("LOGIN") {
            send(c, rejectLogin ? "\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n" : "\(tag) OK LOGIN completed\r\n")
        } else if up.hasPrefix("CAPABILITY") {
            send(c, "* CAPABILITY IMAP4rev1 MOVE UIDPLUS\r\n\(tag) OK done\r\n")
        } else if up.hasPrefix("LIST") {
            send(c, "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Items\"\r\n* LIST (\\HasNoChildren \\Drafts) \"/\" \"Drafts\"\r\n* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Items\"\r\n\(tag) OK done\r\n")
        } else if up.hasPrefix("SELECT") {
            lock.lock(); let n = messages.count, v = validity, nu = nextUID; lock.unlock()
            send(c, "* \(n) EXISTS\r\n* OK [UIDVALIDITY \(v)] ok\r\n* OK [UIDNEXT \(nu)] ok\r\n\(tag) OK [READ-WRITE] SELECT completed\r\n")
        } else if up.hasPrefix("UID SEARCH") {
            lock.lock(); var uids = messages.keys.sorted(); lock.unlock()
            if let m = up.range(of: #"UID (\d+):\*"#, options: .regularExpression) {
                let n = Int(up[m].dropFirst(4).split(separator: ":")[0]) ?? 1
                let hit = uids.filter { $0 >= n }
                uids = hit.isEmpty ? Array(uids.suffix(1)) : hit      // real servers return the last message when none match
            }
            send(c, "* SEARCH \(uids.map(String.init).joined(separator: " "))\r\n\(tag) OK SEARCH completed\r\n")
        } else if up.hasPrefix("UID FETCH") {
            let toks = cmd.split(separator: " ", maxSplits: 3).map(String.init)
            let set = toks[2]
            let wantBody = up.contains("BODY.PEEK")
            lock.lock(); let snapshot = messages; lock.unlock()
            var uids: [Int] = []
            if set.contains(":") { let lo = Int(set.split(separator: ":")[0]) ?? 1; uids = snapshot.keys.sorted().filter { $0 >= lo } }
            else { uids = set.split(separator: ",").compactMap { Int($0) }.filter { snapshot[$0] != nil } }
            for (i, uid) in uids.enumerated() {
                let m = snapshot[uid]!
                let flags = m.flags.sorted().joined(separator: " ")
                if wantBody {
                    send(c, "* \(i + 1) FETCH (UID \(uid) FLAGS (\(flags)) INTERNALDATE \"05-Nov-2026 06:10:00 +0000\" BODY[]<0> {\(m.raw.count)}\r\n")
                    send(c, data: m.raw); send(c, ")\r\n")
                } else { send(c, "* \(i + 1) FETCH (UID \(uid) FLAGS (\(flags)))\r\n") }
            }
            send(c, "\(tag) OK FETCH completed\r\n")
        } else if up.hasPrefix("UID STORE") || up.hasPrefix("UID MOVE") || up.hasPrefix("UID COPY") || up.hasPrefix("UID EXPUNGE") || up.hasPrefix("EXPUNGE") {
            if up.hasPrefix("UID MOVE") {
                let set = cmd.split(separator: " ")[2]
                lock.lock(); for u in set.split(separator: ",").compactMap({ Int($0) }) { messages[u] = nil }; lock.unlock()
            }
            send(c, "\(tag) OK done\r\n")
        } else if up.hasPrefix("APPEND") {
            let n = Int(up.split(separator: "{").last?.dropLast() ?? "0") ?? 0
            send(c, "+ ready\r\n")
            return (tag, n)
        } else if up.hasPrefix("LOGOUT") {
            send(c, "* BYE\r\n\(tag) OK bye\r\n")
        } else { send(c, "\(tag) BAD unknown\r\n") }
        return nil
    }
}


/// A scripted SMTP server on 127.0.0.1 that records one message, so sending can be checked without touching a real account.
final class FakeSmtp: @unchecked Sendable {
    private var listenFD: Int32 = -1
    let port: Int
    private let lock = NSLock()
    private var log: [String] = []
    var transcript: [String] { lock.lock(); defer { lock.unlock() }; return log }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, listen(fd, 4) == 0 else { throw NSError(domain: "FakeSmtp", code: 1) }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.listenFD = fd
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil); if c < 0 { return }
                self?.serve(c)
            }
        }
    }

    private func write(_ fd: Int32, _ s: String) { _ = s.withCString { Darwin.write(fd, $0, strlen($0)) } }
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        write(fd, "220 fake ESMTP\r\n")
        var buf = [UInt8](repeating: 0, count: 8192), pending = "", inData = false
        while true {
            let n = read(fd, &buf, buf.count); if n <= 0 { return }
            pending += String(decoding: buf[0..<n], as: UTF8.self)
            while let r = pending.range(of: "\r\n") {
                let line = String(pending[pending.startIndex..<r.lowerBound]); pending.removeSubrange(pending.startIndex..<r.upperBound)
                lock.lock(); log.append(line); lock.unlock()
                if inData { if line == "." { inData = false; write(fd, "250 queued\r\n") }; continue }
                let up = line.uppercased()
                if up.hasPrefix("EHLO") || up.hasPrefix("HELO") { write(fd, "250-fake\r\n250 8BITMIME\r\n") }
                else if up.hasPrefix("MAIL FROM") || up.hasPrefix("RCPT TO") { write(fd, "250 ok\r\n") }
                else if up == "DATA" { inData = true; write(fd, "354 go ahead\r\n") }
                else if up == "QUIT" { write(fd, "221 bye\r\n"); return }
                else { write(fd, "250 ok\r\n") }
            }
        }
    }
    deinit { if listenFD >= 0 { close(listenFD) } }
}
