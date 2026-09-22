import Foundation
import TelemetryDeck

/// Instance-owned boundary; injected implementations need not construct SDK objects.
internal protocol TelemetryDeckClient {
    func initialize(appID: String, testMode: Bool?, defaultUser: String?)
    func signal(_ name: String, parameters: [String: String])
    func requestImmediateSync()
    func generateNewSession()
}

private struct LiveTelemetryDeckClient: TelemetryDeckClient {
    func initialize(appID: String, testMode: Bool?, defaultUser: String?) {
        let config = TelemetryDeck.Config(appID: appID)
        if let testMode {
            config.testMode = testMode
        }
        config.defaultUser = defaultUser
        TelemetryDeck.initialize(config: config)
    }

    func signal(_ name: String, parameters: [String: String]) {
        TelemetryDeck.signal(name, parameters: parameters)
    }

    func requestImmediateSync() {
        TelemetryDeck.requestImmediateSync()
    }

    func generateNewSession() {
        TelemetryDeck.generateNewSession()
    }
}

/// TelemetryDeck-backed 遥测服务
///
/// 将 ``TelemetryService`` 协议映射到 TelemetryDeck SwiftSDK，
/// 支持通过 App ID 快速接入 TelemetryDeck 的隐私优先分析平台。
///
/// **初始化示例（App 启动时调用一次）：**
/// ```swift
/// let telemetry = TelemetryDeckService(appID: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
/// ```
///
/// TelemetryDeck SDK 内部自动管理批量发送与重试逻辑，
/// 无需手动调用 ``flush()``；本实现的 ``flush()`` 会触发一次立即同步尝试。
public final class TelemetryDeckService: TelemetryService, @unchecked Sendable {

    // MARK: - TelemetryService

    public var isEnabled: Bool
    private let client: any TelemetryDeckClient

    // MARK: - Init

    /// 创建并初始化 TelemetryDeck 服务。
    ///
    /// - Parameters:
    ///   - appID: TelemetryDeck 控制台中的 App ID（UUID 格式字符串）。
    ///   - isEnabled: 是否启用遥测，默认 `true`。设为 `false` 可在用户退出同意后关闭。
    ///   - testMode: 为 `true` 时信号标记为测试信号（仅在 TelemetryDeck 测试模式视图中可见）。
    ///     默认值跟随 `DEBUG` 编译条件：Debug 构建下自动为 `true`，Release 构建为 `false`。
    ///   - defaultUser: 可选的默认用户标识（哈希后发送，原始值不离开设备）。
    public init(
        appID: String,
        isEnabled: Bool = true,
        testMode: Bool? = nil,
        defaultUser: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.client = LiveTelemetryDeckClient()
        client.initialize(appID: appID, testMode: testMode, defaultUser: defaultUser)
    }

    /// Inject before initialization, including when disabled. No live SDK fallback.
    internal init(
        appID: String,
        isEnabled: Bool = true,
        testMode: Bool? = nil,
        defaultUser: String? = nil,
        client: any TelemetryDeckClient
    ) {
        self.isEnabled = isEnabled
        self.client = client
        client.initialize(appID: appID, testMode: testMode, defaultUser: defaultUser)
    }

    // MARK: - TelemetryService

    public func track(_ event: TelemetryEvent) {
        guard isEnabled else { return }
        client.signal(event.name, parameters: event.properties)
    }

    public func track(name: String, properties: [String: String]) {
        guard isEnabled else { return }
        client.signal(name, parameters: properties)
    }

    /// 请求立即同步缓存信号到服务器。
    ///
    /// TelemetryDeck SDK 会自动在合适时机发送，通常无需手动调用。
    /// 在用户即将离开 App 前（如 `sceneDidEnterBackground`）调用有助于减少数据丢失。
    public func flush() async {
        client.requestImmediateSync()
    }

    /// 生成新的 TelemetryDeck 会话 ID，用于在逻辑会话边界处重置用户追踪。
    public func resetIdentifier() {
        client.generateNewSession()
    }
}
