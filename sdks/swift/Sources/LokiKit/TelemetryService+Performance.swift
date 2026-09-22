import Foundation

/// TelemetryService 性能监控扩展
///
/// 提供与 ``Logger/performance(_:context:file:function:line:_:)-4vqr7`` 对称的遥测计时接口：
/// 操作完成后自动附加 `duration_ms` 属性并调用 ``TelemetryService/track(name:properties:)``，
/// 操作失败时在事件名末尾追加 `.failed`，不自动提取错误描述或类型。
/// 调用方提供的属性不会被隐私过滤（`duration_ms` 会被自动写入）。
///
/// ### 用法示例
/// ```swift
/// // 自动计时（同步）
/// let result = telemetry.measure("whisper.model.loaded") {
///     loadWhisperModel()
/// }
///
/// // 自动计时（异步）
/// let transcript = try await telemetry.measure("transcription.completed") {
///     try await transcriber.transcribe(audio)
/// }
///
/// // Actor 场景手动计时
/// let start = telemetry.measureStart()
/// await doWork()
/// telemetry.measureEnd("session.created", start: start)
/// ```
public extension TelemetryService {

    // MARK: - 手动计时

    /// 返回当前时刻作为计时起点（适用于 actor 隔离等无法使用闭包的场景）
    func measureStart() -> ContinuousClock.Instant {
        ContinuousClock().now
    }

    /// 计算耗时并发送遥测事件（成功路径）
    ///
    /// - Parameters:
    ///   - eventName: 遥测事件名称
    ///   - start: 由 ``measureStart()`` 返回的起始时刻
    ///   - properties: 附加属性（`duration_ms` 键将被自动写入）
    func measureEnd(
        _ eventName: String,
        start: ContinuousClock.Instant,
        properties: [String: String] = [:]
    ) {
        let ms = millisecondsSince(start)
        var props = properties
        props["duration_ms"] = String(format: "%.2f", ms)
        track(name: eventName, properties: props)
    }

    /// 计算耗时并发送遥测事件（失败路径）
    ///
    /// 事件名自动追加 `.failed`，仅自动写入 `duration_ms`，不读取或序列化错误。
    /// 调用方提供的其他属性原样保留，包括显式提供的 `error` 属性；此接口不执行隐私过滤。
    ///
    /// - Parameters:
    ///   - eventName: 遥测事件名称（不含 `.failed` 后缀）
    ///   - start: 由 ``measureStart()`` 返回的起始时刻
    ///   - error: 操作抛出的错误；为保持调用兼容性保留，不读取其内容
    ///   - properties: 附加属性（`duration_ms` 键将被自动写入）
    func measureEnd(
        _ eventName: String,
        start: ContinuousClock.Instant,
        error: Error,
        properties: [String: String] = [:]
    ) {
        let ms = millisecondsSince(start)
        var props = properties
        props["duration_ms"] = String(format: "%.2f", ms)
        track(name: "\(eventName).failed", properties: props)
    }

    // MARK: - 自动计时（闭包）

    /// 测量同步操作耗时并发送遥测事件
    ///
    /// 操作成功时发送 `eventName`；抛出错误时发送 `eventName.failed`。
    ///
    /// - Parameters:
    ///   - eventName: 遥测事件名称
    ///   - properties: 附加属性（`duration_ms` 键自动写入，勿手动传入）
    ///   - operation: 被测量的同步操作
    /// - Returns: `operation` 的返回值
    @discardableResult
    func measure<T>(
        _ eventName: String,
        properties: [String: String] = [:],
        _ operation: () throws -> T
    ) rethrows -> T {
        let start = measureStart()
        do {
            let result = try operation()
            measureEnd(eventName, start: start, properties: properties)
            return result
        } catch {
            measureEnd(eventName, start: start, error: error, properties: properties)
            throw error
        }
    }

    /// 测量异步操作耗时并发送遥测事件
    ///
    /// 操作成功时发送 `eventName`；抛出错误时发送 `eventName.failed`。
    ///
    /// - Parameters:
    ///   - eventName: 遥测事件名称
    ///   - properties: 附加属性（`duration_ms` 键自动写入，勿手动传入）
    ///   - operation: 被测量的异步操作
    /// - Returns: `operation` 的返回值
    @discardableResult
    func measure<T>(
        _ eventName: String,
        properties: [String: String] = [:],
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let start = measureStart()
        do {
            let result = try await operation()
            measureEnd(eventName, start: start, properties: properties)
            return result
        } catch {
            measureEnd(eventName, start: start, error: error, properties: properties)
            throw error
        }
    }
}

// MARK: - Private

private extension TelemetryService {
    func millisecondsSince(_ start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock().now - start
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
