import Foundation
import Synchronization

/// 控制台日志的显式、隐私优先镜像；只保留已审核的固定消息及数值上下文。
public final class LokiLogSink: Sendable {
    struct Record: Codable, Sendable {
        let timestamp: Date
        let level: String
        let subsystem: String
        let message: String
        let file: String
        let function: String
        let line: Int
        let context: [String: Double]
    }

    private struct State {
        var pending: [Record] = []
        var flushing = false
        var restored = false
    }

    private let state = Mutex(State())
    private let endpoint: URL
    private let labels: [String: String]
    private let allowedMessages: Set<String>
    private let allowedContextKeys: Set<String>
    private let capacity: Int
    private let persistenceURL: URL?
    private let session: URLSession
    private let token: String?

    public init(
        endpoint: URL,
        labels: [String: String],
        allowedMessages: Set<String>,
        allowedContextKeys: Set<String> = [],
        capacity: Int = 1_000,
        persistenceURL: URL? = nil,
        token: String? = nil,
        session: URLSession = .shared
    ) {
        precondition(capacity > 0)
        self.endpoint = endpoint
        self.labels = labels
        self.allowedMessages = allowedMessages
        self.allowedContextKeys = allowedContextKeys
        self.capacity = capacity
        self.persistenceURL = persistenceURL
        self.token = token
        self.session = session
    }

    /// 同步入口仅操作有界内存；网络和文件 I/O 均由异步 flush 执行。
    public func record(
        level: LogLevel, subsystem: String, message: String,
        context: [String: Any]?, file: String, function: String, line: Int
    ) {
        var safeContext: [String: Double] = [:]
        for key in allowedContextKeys {
            if let number = context?[key] as? NSNumber, number.doubleValue.isFinite {
                safeContext[key] = number.doubleValue
            }
        }
        let record = Record(
            timestamp: Date(), level: level.name.lowercased(), subsystem: String(subsystem.prefix(128)),
            message: allowedMessages.contains(message) ? message : "[dynamic message redacted]",
            file: (file as NSString).lastPathComponent, function: function, line: line,
            context: safeContext
        )
        state.withLock {
            $0.pending.append(record)
            if $0.pending.count > capacity { $0.pending.removeFirst($0.pending.count - capacity) }
        }
    }

    /// 调用方持有并取消返回的任务；后台不可达时保留最近 capacity 条，下一轮重试。
    public func start(flushInterval: Duration = .seconds(2)) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.flush()
                do { try await Task.sleep(for: flushInterval) } catch { return }
                guard self != nil else { return }
            }
        }
    }

    public func flush() async {
        let acquired = state.withLock {
            if $0.flushing { return false }
            $0.flushing = true
            return true
        }
        guard acquired else { return }
        defer { state.withLock { $0.flushing = false } }

        restoreOnce()
        let batch = state.withLock { value in
            let batch = Array(value.pending.prefix(200))
            value.pending.removeFirst(batch.count)
            return batch
        }
        guard !batch.isEmpty else { return }

        // 先落盘，避免上传中进程退出丢失整个批次。只写过滤后的记录。
        persist(batch + state.withLock { $0.pending })
        do {
            let body = try Self.pushBody(batch, labels: labels)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = body
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        } catch {
            state.withLock { $0.pending = Array((batch + $0.pending).suffix(capacity)) }
        }
        persist(state.withLock { $0.pending })
    }

    private func restoreOnce() {
        let shouldRestore = state.withLock {
            if $0.restored { return false }
            $0.restored = true
            return true
        }
        guard shouldRestore, let persistenceURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: persistenceURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: persistenceURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        // 旧队列重新通过消息白名单，配置收紧后也不会回放未批准内容。
        let safe = records.filter { allowedMessages.contains($0.message) || $0.message == "[dynamic message redacted]" }
            .map { record in
                Record(timestamp: record.timestamp, level: record.level, subsystem: record.subsystem,
                       message: record.message, file: record.file, function: record.function, line: record.line,
                       context: record.context.filter { allowedContextKeys.contains($0.key) && $0.value.isFinite })
            }
        state.withLock { $0.pending = Array((safe + $0.pending).suffix(capacity)) }
    }

    private func persist(_ records: [Record]) {
        guard let persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Array(records.suffix(capacity))).write(to: persistenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
        } catch {
            // 不通过 PrintLogger 记录传输错误，避免日志上传递归。
        }
    }

    static func pushBody(_ records: [Record], labels: [String: String]) throws -> Data {
        let groups = Dictionary(grouping: records, by: \.level)
        let streams: [[String: Any]] = try groups.map { level, records in
            var stream = labels
            stream["level"] = level
            stream["stream"] = "log"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let values = try records.sorted { $0.timestamp < $1.timestamp }.map { record in
                [String(Int64(record.timestamp.timeIntervalSince1970 * 1_000_000_000)),
                 String(decoding: try encoder.encode(record), as: UTF8.self)]
            }
            return ["stream": stream, "values": values]
        }
        return try JSONSerialization.data(withJSONObject: ["streams": streams])
    }
}
