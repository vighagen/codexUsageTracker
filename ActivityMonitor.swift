import Foundation
import Darwin
import SQLite3

/// Minimal projection of desktop IPC state. Message text and tool payloads are never retained.
struct TaskActivity {
    var status: String = "notLoaded"
    var flags: [String] = []
    var requests = 0
    var revision: Int = -1
    var owner = ""
    var streamShowsWork = false
    var working: Bool {
        (status == "active" || (status == "notLoaded" && streamShowsWork)) &&
        !flags.contains("waitingOnUserInput") && !flags.contains("waitingOnApproval") && requests == 0
    }
    mutating func snapshot(_ state: [String: Any], revision: Int) {
        let runtime = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
        status = runtime["type"] as? String ?? "notLoaded"
        flags = runtime["activeFlags"] as? [String] ?? []
        requests = (state["requests"] as? [Any])?.count ?? 0
        streamShowsWork = false
        self.revision = revision
    }
    mutating func patches(_ changes: [[String: Any]], base: Int, revision: Int) -> Bool {
        // Large desktop tasks can send live deltas without an initial snapshot.
        // Apply independent status fields and current-tail execution evidence anyway.
        // A missing revision must not erase work confirmed by another live update.
        let continuous = self.revision == base
        if revision <= self.revision { return true }
        for patch in changes {
            let path = patch["path"] as? [Any] ?? []
            let op = patch["op"] as? String ?? ""
            if path.isEmpty, let value = patch["value"] as? [String: Any] {
                snapshot(value, revision: revision)
            } else if path.first as? String == "threadRuntimeStatus" {
                streamShowsWork = false
                if path.count == 1 {
                    let value = patch["value"] as? [String: Any] ?? [:]
                    status = value["type"] as? String ?? "notLoaded"
                    flags = value["activeFlags"] as? [String] ?? []
                } else if path[1] as? String == "type" {
                    status = patch["value"] as? String ?? "notLoaded"
                } else if path[1] as? String == "activeFlags" {
                    status = "active"
                    if path.count == 2 { flags = patch["value"] as? [String] ?? [] }
                    else if let index = path[2] as? Int {
                        if op == "remove", flags.indices.contains(index) { flags.remove(at: index) }
                        else if let value = patch["value"] as? String {
                            if op == "add", index <= flags.count { flags.insert(value, at: index) }
                            else if flags.indices.contains(index) { flags[index] = value }
                        }
                    }
                }
            } else if status == "notLoaded", Self.isLiveExecutionPatch(path: path, value: patch["value"]) {
                streamShowsWork = true
            } else if path.first as? String == "requests" {
                if path.count == 1 { requests = (patch["value"] as? [Any])?.count ?? 0 }
                else if path.count == 2 {
                    if op == "add" { requests += 1 }
                    if op == "remove" { requests = max(0, requests - 1) }
                }
            }
        }
        self.revision = revision
        return continuous
    }
    private static func isLiveExecutionPatch(path: [Any], value: Any?) -> Bool {
        // Only individual items in the current streaming tail qualify. Loading an
        // old history page, changing a title, or updating usage is not proof of work.
        guard path.count >= 6, path[0] as? String == "turnHistory",
              path[1] as? String == "history", path[2] as? String == "entitiesByKey",
              let key = path[3] as? String, key.hasPrefix("tail:"),
              path[4] as? String == "items", let item = value as? [String: Any],
              let type = item["type"] as? String else { return false }
        if type == "reasoning" { return true }
        return ["mcpToolCall", "dynamicToolCall", "commandExecution", "fileChange", "webSearch", "collabAgentToolCall"].contains(type)
            && ["inProgress", "running"].contains(item["status"] as? String ?? "")
    }
}

/// Connects as an observer; never starts/resumes a thread or accepts an approval.
/// The desktop coordination protocol is internal and can change between app releases.
final class ActivityMonitor {
    var onUpdate: ((Int, Bool) -> Void)?
    private let queue = DispatchQueue(label: "usage-tracker.activity", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var fd: Int32 = -1
    private var tasks: [String: TaskActivity] = [:]
    private var subscribed = Set<String>()
    private var clientID = ""
    private var published = ""
    private var unsupportedProtocol = false
    private let root: URL
    init(root: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")) { self.root = root }
    func start() { queue.async { [weak self] in self?.run() } }
    func stop() {
        lock.lock(); stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func publish(connected: Bool) {
        let count = connected ? tasks.values.filter(\.working).count : 0
        let connected = connected && (!unsupportedProtocol || count > 0)
        let key = "\(count):\(connected)"
        guard key != published else { return }; published = key
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(count, connected) }
    }
    private func candidates() -> [String]? {
        let paths = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        guard let dbPath = paths.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        let query = "SELECT id FROM threads WHERE archived=0 ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { ids.append(String(cString: text)) }
        }
        return ids
    }
    private func send(_ object: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: object), fd >= 0 else { return }
        var size = UInt32(json.count).littleEndian
        var data = Data(bytes: &size, count: 4); data.append(json)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n <= 0 { break }; offset += n
            }
        }
    }
    private func follow(_ id: String, enabled: Bool) {
        send(["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": clientID,
              "version": 1, "params": ["conversationId": id, "hostId": "local", "following": enabled]])
    }
    private func refreshSubscriptions() {
        guard !clientID.isEmpty else { return }
        guard let candidates = candidates() else { return }
        let ids = Set(candidates)
        for id in subscribed.subtracting(ids) { follow(id, enabled: false); tasks.removeValue(forKey: id) }
        for id in ids.subtracting(subscribed) { follow(id, enabled: true) }
        subscribed = ids
    }
    private func receive(_ message: [String: Any]) {
        let type = message["type"] as? String
        if type == "response", message["method"] as? String == "initialize",
           let result = message["result"] as? [String: Any], let id = result["clientId"] as? String {
            clientID = id; refreshSubscriptions(); publish(connected: true); return
        }
        if type == "client-discovery-request" {
            send(["type": "client-discovery-response", "requestId": message["requestId"] ?? "", "response": ["canHandle": false]])
            return
        }
        guard type == "broadcast", let params = message["params"] as? [String: Any] else { return }
        let method = message["method"] as? String
        if method == "thread-stream-following-status-requested", params["hostId"] as? String == "local",
           let id = params["conversationId"] as? String, subscribed.contains(id) {
            follow(id, enabled: true); return
        }
        if method == "client-status-changed", params["status"] as? String == "connected" {
            for id in subscribed { follow(id, enabled: true) }
            return
        }
        if method == "client-status-changed", params["status"] as? String == "disconnected", let owner = params["clientId"] as? String {
            tasks = tasks.filter { $0.value.owner != owner }; publish(connected: !clientID.isEmpty); return
        }
        guard method == "thread-stream-state-changed", params["hostId"] as? String == "local",
              let id = params["conversationId"] as? String, subscribed.contains(id),
              let change = params["change"] as? [String: Any] else { return }
        guard message["version"] as? Int == 11 else { unsupportedProtocol = true; tasks.removeValue(forKey: id); publish(connected: false); return }
        var task = tasks[id] ?? TaskActivity()
        task.owner = message["sourceClientId"] as? String ?? ""
        let revision = change["revision"] as? Int ?? -1
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            task.snapshot(state, revision: revision)
        } else if change["type"] as? String == "patches", let patches = change["patches"] as? [[String: Any]] {
            let wasKnown = task.revision >= 0
            let continuous = task.patches(patches, base: change["baseRevision"] as? Int ?? -2, revision: revision)
            if wasKnown && !continuous {
                follow(id, enabled: false); follow(id, enabled: true)
            }
        }
        tasks[id] = task; publish(connected: true)
    }
    private func run() {
        while !isStopped {
            tasks.removeAll(); subscribed.removeAll(); clientID = ""; unsupportedProtocol = false
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(root.appendingPathComponent("ipc/ipc.sock").path.utf8CString)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            if path.count >= capacity { close(socketFD); publish(connected: false); return }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                path.withUnsafeBytes { source in destination.copyBytes(from: source) }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
            }
            if connected {
                lock.lock(); fd = socketFD; lock.unlock()
                send(["type": "request", "method": "initialize", "requestId": "usage-tracker-activity", "version": 0,
                      "params": ["clientType": "usage-tracker"]])
                var buffer = Data(), bytes = [UInt8](repeating: 0, count: 65536)
                var nextRefresh = Date().addingTimeInterval(3)
                var valid = true
                while !isStopped && valid {
                    let n = recv(socketFD, &bytes, bytes.count, 0)
                    if n > 0 { buffer.append(contentsOf: bytes.prefix(n)) }
                    else if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { break }
                    while buffer.count >= 4 {
                        let size = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                        if size <= 0 || size > 48 * 1024 * 1024 { valid = false; break }
                        guard buffer.count >= size + 4 else { break }
                        let data = buffer.subdata(in: 4..<(size + 4)); buffer.removeSubrange(0..<(size + 4))
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { receive(object) }
                    }
                    if Date() >= nextRefresh { refreshSubscriptions(); publish(connected: !clientID.isEmpty); nextRefresh = Date().addingTimeInterval(3) }
                }
            }
            lock.lock(); fd = -1; close(socketFD); lock.unlock()
            tasks.removeAll(); publish(connected: false)
            if !isStopped { Thread.sleep(forTimeInterval: 2) }
        }
    }
}

func runActivityTests() {
    var state = TaskActivity()
    state.snapshot(["threadRuntimeStatus": ["type": "active", "activeFlags": []], "requests": []], revision: 1)
    precondition(state.working)
    precondition(state.patches([["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"], "value": ["waitingOnUserInput"]]], base: 1, revision: 2))
    precondition(!state.working)
    _ = state.patches([["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0]]], base: 2, revision: 3)
    precondition(state.working)
    _ = state.patches([["op": "add", "path": ["requests", 0], "value": ["type": "approval"]]], base: 3, revision: 4)
    precondition(!state.working)
    _ = state.patches([["op": "remove", "path": ["requests", 0]]], base: 4, revision: 5)
    precondition(state.working)
    _ = state.patches([["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]]], base: 5, revision: 6)
    precondition(!state.working)
    state.snapshot(["threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]]], revision: 7)
    precondition(!state.working)
    precondition(!state.patches([], base: 2, revision: 8) && !state.working)
    var project = TaskActivity()
    let livePath: [Any] = ["turnHistory", "history", "entitiesByKey", "tail:0:local:fixture", "items", 175]
    precondition(!project.patches([["op": "replace", "path": livePath,
                                   "value": ["type": "reasoning"]]], base: 2500, revision: 2501))
    precondition(project.working, "Snapshot-less project streams must count as work")
    let idle = TaskActivity()
    precondition([idle, project].filter(\.working).count == 1, "An idle task must not hide another active task")
    _ = project.patches([["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]]], base: 2501, revision: 2502)
    precondition(!project.working, "Completion must clear inferred work")
    var history = TaskActivity()
    _ = history.patches([["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "page:older", "items", 1],
                          "value": ["type": "reasoning"]]], base: 1, revision: 2)
    precondition(!history.working, "Reading old history must not start the animation")
    print("Activity checks passed: running, waiting, approval, resume, completion, missing revision, snapshot-less project streams, and multiple tasks")
}
