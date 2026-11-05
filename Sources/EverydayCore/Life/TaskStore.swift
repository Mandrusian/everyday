import Foundation

public final class TaskStore: @unchecked Sendable {
    private let db: Database
    public init(db: Database) { self.db = db }

    public func all() -> [TaskItem] { (try? db.all("task", limit: 5000)) ?? [] }
    public func open() -> [TaskItem] {
        all().filter { !$0.isDone }.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): if a != b { return a < b }
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return $0.priority.rawValue > $1.priority.rawValue
        }
    }
    public func completed() -> [TaskItem] { all().filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) } }

    public func save(_ t: TaskItem) { try? db.put("task", id: t.id, sort: (t.due ?? t.createdAt).timeIntervalSince1970, t) }
    public func delete(_ t: TaskItem) { try? db.delete("task", id: t.id) }
    @discardableResult public func deleteCompleted() -> [TaskItem] { let done = completed(); for t in done { delete(t) }; return done }
    @discardableResult public func deleteAll() -> [TaskItem] { let all = self.all(); for t in all { delete(t) }; return all }

    public func toggle(_ t: TaskItem) -> TaskItem {
        var x = t
        x.completedAt = t.isDone ? nil : Date()
        save(x)
        if !t.isDone, let r = t.repeats {      // completing a repeating task schedules the next one
            var n = TaskItem(title: t.title, notes: t.notes, due: r.next(after: t.due), priority: t.priority, source: t.source, sourceDescription: t.sourceDescription, threadId: t.threadId)
            n.repeats = r
            save(n)
        }
        return x
    }

    @discardableResult
    public func accept(_ s: TaskSuggestion) -> TaskItem {
        let t = TaskItem(title: s.title, due: s.due, priority: s.priority, source: .email, sourceDescription: s.sourceDescription, threadId: s.threadId)
        save(t)
        var d = s; d.dismissed = true
        try? db.put("taskSuggestion", id: s.id, sort: 0, d)
        return t
    }

    public func weekProgress() -> (done: Int, total: Int) {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let all = self.all()
        let doneThisWeek = all.filter { ($0.completedAt ?? .distantPast) >= start }.count
        let openDueThisWeek = all.filter { !$0.isDone && ($0.due.map { $0 < start.addingTimeInterval(7 * 86400) } ?? false) }.count
        return (doneThisWeek, doneThisWeek + openDueThisWeek)
    }
}
