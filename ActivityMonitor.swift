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
    var working: Bool { status == "active" && flags.isEmpty && requests == 0 }
    mutating func snapshot(_ state: [String: Any], revision: Int) {
        let runtime = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
        status = runtime["type"] as? String ?? "notLoaded"
        flags = runtime["activeFlags"] as? [String] ?? []
        requests = (state["requests"] as? [Any])?.count ?? 0
        self.revision = revision
    }
    mutating func patches(_ changes: [[String: Any]], base: Int, revision: Int) -> Bool {
        guard base == self.revision else { status = "notLoaded"; return false }
        for patch in changes {
            let path = patch["path"] as? [Any] ?? []
            let op = patch["op"] as? String ?? ""
            if path.isEmpty, let value = patch["value"] as? [String: Any] {
                snapshot(value, revision: revision)
            } else if path.first as? String == "threadRuntimeStatus" {
                if path.count == 1 {
                    let value = patch["value"] as? [String: Any] ?? [:]
                    status = value["type"] as? String ?? "notLoaded"
                    flags = value["activeFlags"] as? [String] ?? []
                } else if path[1] as? String == "type" {
                    status = patch["value"] as? String ?? "notLoaded"
                } else if path[1] as? String == "activeFlags" {
                    if path.count == 2 { flags = patch["value"] as? [String] ?? [] }
                    else if let index = path[2] as? Int {
                        if op == "remove", flags.indices.contains(index) { flags.remove(at: index) }
                        else if let value = patch["value"] as? String {
                            if op == "add", index <= flags.count { flags.insert(value, at: index) }
                            else if flags.indices.contains(index) { flags[index] = value }
                        }
                    }
                }
            } else if path.first as? String == "requests" {
                if path.count == 1 { requests = (patch["value"] as? [Any])?.count ?? 0 }
                else if path.count == 2 {
                    if op == "add" { requests += 1 }
                    if op == "remove" { requests = max(0, requests - 1) }
                }
            }
        }
        self.revision = revision
        return true
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
        let connected = connected && !unsupportedProtocol
        let count = connected ? tasks.values.filter(\.working).count : 0
        let key = "\(count):\(connected)"
        guard key != published else { return }; published = key
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(count, connected) }
    }
    private func candidates() -> [String] {
        let paths = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        guard let dbPath = paths.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        let query = "SELECT id FROM threads WHERE archived=0 AND source NOT LIKE '%subagent%' ORDER BY updated_at DESC LIMIT 64"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
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
        let ids = Set(candidates())
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
            if !task.patches(patches, base: change["baseRevision"] as? Int ?? -2, revision: revision) {
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
    print("Activity checks passed: running, waiting, approval, resume, completion, and missing revision")
}
