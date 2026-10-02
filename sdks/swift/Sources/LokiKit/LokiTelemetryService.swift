import Foundation

/// 基于 Loki 的遥测服务
///
/// 将事件批量上报到 Grafana Loki，支持离线缓存：
/// - `track` 返回前同步尝试原子写盘；失败计数并保留内存副本
/// - `flush()` 时尝试 HTTP 上报；成功后才删除队列文件
/// - 下次 `flush()` 时自动重传磁盘中的历史批次
///
/// 本地开发对接 Docker Loki，上架后切换 endpoint 到 Grafana Cloud（API 完全兼容）。
public final class LokiTelemetryService: TelemetryService, @unchecked Sendable {

    // MARK: - TelemetryService

    public var isEnabled: Bool

    /// 本实例累计失败的持久化操作次数（非丢失事件数）；读取不执行 I/O。
    public var persistenceFailureCount: Int { queue.persistenceFailureCount }

    // MARK: - Private

    private let queue: TelemetryQueue
    private let shipper: LokiShipper
    private let appLabels: [String: String]

    // MARK: - Init

    /// - Parameters:
    ///   - endpoint: Loki push 端点（本地 Docker: `http://localhost:3100/loki/api/v1/push`）
    ///   - appLabels: 固定标签（附加到所有事件，用于按 app、env、version 等过滤）
    ///   - isEnabled: 是否启用，默认 true
    ///   - authToken: Bearer token（Grafana Cloud 使用 `<user>:<apikey>` base64 编码）
    ///   - storeDirectory: 离线队列目录，nil 使用默认路径（Application Support/telemetry/pending）
    public init(
        endpoint: URL,
        appLabels: [String: String] = [:],
        isEnabled: Bool = true,
        authToken: String? = nil,
        storeDirectory: URL? = nil
    ) {
        self.isEnabled = isEnabled
        self.queue = TelemetryQueue(storeDirectory: storeDirectory)

        var headers: [String: String] = [:]
        if let token = authToken {
            headers["Authorization"] = "Bearer \(token)"
        }
        self.shipper = LokiShipper(endpoint: endpoint, headers: headers)
        self.appLabels = appLabels
    }

    // Instance-owned transport seam for isolated retry/concurrency tests.
    init(queue: TelemetryQueue, shipper: LokiShipper, isEnabled: Bool = true) {
        self.queue = queue
        self.shipper = shipper
        self.appLabels = [:]
        self.isEnabled = isEnabled
    }

    // MARK: - TelemetryService

    public func track(_ event: TelemetryEvent) {
        guard isEnabled else { return }
        queue.enqueue(event)
    }

    public func track(name: String, properties: [String: String]) {
        track(TelemetryEvent(name: name, properties: properties))
    }

    /// 将所有待发送事件上报到 Loki
    ///
    /// 执行顺序：
    /// 先重试历史批次，成功后删除；失败保留，并停止本次发送。
    /// 同一实例并发 flush 不重复发送；发送期间入队的事件留待下次 flush。
    public func flush() async {
        guard isEnabled else { return }

        guard queue.beginFlush() else { return }
        defer { queue.endFlush() }
        do {
            for batch in try queue.batchesForFlush() {
                try await shipper.ship(batch.events, appLabels: appLabels)
                try queue.removeBatch(id: batch.id)
            }
        } catch {
            // The queue retains unsuccessful work and accounts for storage failures.
        }
    }

    public func resetIdentifier() {}
}
