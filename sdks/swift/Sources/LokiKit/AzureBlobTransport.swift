import Foundation
import Synchronization
import zlib

/// Internal, default-deny transport core. Product-owned rules are explicit;
/// TelemetryEvent properties do NOT inherit LokiLogSink's filtering.
struct AzureBlobTransport: Sendable {
    private let containerURL: URL
    private let sasQuery: String
    private let prefix: [String]
    private let protocolClasses: [AnyClass]?
    private let now: @Sendable () -> Date
    private let privacy: AzureBlobPrivacyPolicy

    init(containerURL: URL, sasQuery: String, app: String, build: String, installID: UUID,
         privacy: AzureBlobPrivacyPolicy = .init(),
         configuration: URLSessionConfiguration = .ephemeral, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let url = URLComponents(url: containerURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.percentEncodedPath.range(of: "^/[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
              !url.path.contains("--"),
              [app, build].allSatisfy(Self.validSegment),
              Self.validSAS(sasQuery)
        else { throw AzureBlobError.invalidConfiguration }
        self.containerURL = containerURL
        self.sasQuery = sasQuery.hasPrefix("?") ? String(sasQuery.dropFirst()) : sasQuery
        self.prefix = [app, build, installID.uuidString.lowercased()]
        // Only trusted protocol injection crosses this internal test seam. Never
        // inherit a caller's delegate, credential/cookie stores, headers or proxies.
        self.protocolClasses = configuration.protocolClasses
        self.now = now
        self.privacy = privacy
    }

    func flush(_ queue: TelemetryQueue, control: BlobRequestControl? = nil,
               responseBytesObserved: (@Sendable (Int) -> Void)? = nil) async throws {
        guard queue.beginFlush() else { return }
        defer { queue.endFlush() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let responseDelegate = BlobRequestDelegate(control: control, responseBytesObserved: responseBytesObserved)
        let session = URLSession(configuration: configuration, delegate: responseDelegate, delegateQueue: nil)
        // Reuse connections only within this flush; release session/delegate resources
        // on success, storage/network failure and cancellation, with no caller lifecycle.
        defer { session.invalidateAndCancel() }
        for batch in try queue.batchesForFlush(retryingWrites: false) {
            try privacy.validate(batch.events)
            let stored = try AzureBlobBatch.load(id: batch.id, queue: queue)
            if let stored {
                guard stored.containerURL == containerURL else { throw AzureBlobError.destinationChanged }
                try privacy.validatePath(stored.path)
            } else {
                try privacy.validateMetadata(app: prefix[0], build: prefix[1])
            }
            let source = try Self.ndjson(batch.events)
            var prepared: AzureBlobBatch
            if let stored {
                guard stored.sourceDigest == AzureBlobBatch.digest(source) else {
                    throw AzureBlobError.invalidStoredBatch
                }
                // A source digest is not privacy approval of the saved wire body.
                // Require its ENTIRE gzip stream to match currently approved source.
                try Self.validateGzip(stored.body, equals: source)
                prepared = stored
            } else {
                // A failed enqueue rewrite may have left only a prefix on disk. Never
                // send the memory suffix until the FULL source is restart-recoverable.
                try queue.persistBatch(id: batch.id, events: batch.events)
                prepared = AzureBlobBatch(version: 1, queueID: batch.id, containerURL: containerURL,
                    path: [prefix[0], prefix[1], Self.day(now()), prefix[2], "\(UUID().uuidString.lowercased()).ndjson.gz"],
                    sourceDigest: AzureBlobBatch.digest(source), body: try Self.gzip(source), mayHaveBeenSent: false)
            }
            let retransmission = prepared.mayHaveBeenSent
            if !retransmission {
                // Write-ahead marker covers termination during URLSession. Neither
                // bytes nor destination are ever regenerated for an unresolved attempt.
                prepared.mayHaveBeenSent = true
                try prepared.save(queue: queue)
            }
            let reply = try await put(prepared.body, path: prepared.path, session: session,
                responseDelegate: responseDelegate, retransmission: retransmission, controlled: control != nil)
            guard Self.confirmsDelivery(reply, retransmission: retransmission) else {
                if !retransmission && reply.status < 500 {
                    // A completed first rejection does not prove an earlier upload.
                    // A 5xx may follow a partial server operation; keep its marker.
                    prepared.mayHaveBeenSent = false
                    try prepared.save(queue: queue)
                }
                throw AzureBlobError.httpFailure(reply.status)
            }
            try queue.removeBatch(id: batch.id)
            // Source deletion only follows delivery. A crash/cleanup failure here
            // can leave an inert sidecar; old/new queue readers ignore that suffix.
            try prepared.remove(queue: queue)
        }
    }

    private func put(_ body: Data, path: [String], session: URLSession,
                     responseDelegate: BlobRequestDelegate, retransmission: Bool,
                     controlled: Bool) async throws -> (status: Int, code: String?) {
        var url = URLComponents(url: containerURL, resolvingAgainstBaseURL: false)!
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        url.percentEncodedPath = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.percentEncodedPath = "/" + url.percentEncodedPath + "/" + path.map {
            $0.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "/")
        url.percentEncodedQuery = sasQuery
        guard let endpoint = url.url else { throw AzureBlobError.invalidConfiguration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.httpBody = body
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.setValue("2023-11-03", forHTTPHeaderField: "x-ms-version")
        request.setValue(Self.httpDate(now()), forHTTPHeaderField: "x-ms-date")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        do {
            let reply = try await responseDelegate.response(for: request, using: session, overwriteReceiptEligible: retransmission)
            // Cancellation after completion but before the async handoff is also
            // conservative: retain the batch rather than acknowledge cancelled work.
            if !controlled { try Task.checkCancellation() }
            return reply
        } catch let error as AzureBlobError {
            throw error
        } catch {
            // URLSession errors can embed the SAS URL. Never propagate it or response bodies.
            throw AzureBlobError.networkFailure
        }
    }

    static func confirmsDelivery(_ response: BlobRequestDelegate.Response, retransmission: Bool) -> Bool {
        response.status == 201 || (retransmission && response.status == 403 && response.code == "UnauthorizedBlobOverwrite")
    }

    private static func validSegment(_ value: String) -> Bool {
        !value.isEmpty && !value.hasSuffix(".") && !value.contains("/") && !value.contains("\\")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validSAS(_ input: String) -> Bool {
        let query = input.hasPrefix("?") ? String(input.dropFirst()) : input
        // Validate before assigning percentEncodedQuery (Foundation traps on malformed
        // escapes). Preserve signed bytes; never decode/re-encode the signature.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?%")
        guard !query.isEmpty, query.removingPercentEncoding != nil,
              query.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
        var components = URLComponents()
        components.percentEncodedQuery = query
        let items = components.queryItems ?? []
        let names = Set(items.map(\.name))
        let supported: Set<String> = ["sv", "sr", "si", "sp", "st", "se", "spr", "sip", "sig"]
        guard names.count == items.count, names.isSubset(of: supported),
              items.contains(where: { $0.name == "sig" && !($0.value ?? "").isEmpty }),
              items.contains(where: { $0.name == "sr" && $0.value == "c" }),
              !items.contains(where: { $0.name == "sp" && $0.value != "c" }),
              !items.contains(where: { $0.name == "spr" && $0.value != "https" }) else { return false }
        return true
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func ndjson(_ events: [TelemetryEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Canonicalize from the first send to the existing queue's restart precision.
        encoder.dateEncodingStrategy = .iso8601
        var result = Data()
        for event in events {
            result.append(try encoder.encode(event))
            result.append(0x0a)
        }
        return result
    }

    private static func gzip(_ input: Data) throws -> Data {
        guard input.count <= Int(uInt.max) else { throw AzureBlobError.encodingFailure }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16,
                           MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                           Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AzureBlobError.encodingFailure
        }
        defer { deflateEnd(&stream) }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data()
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw AzureBlobError.encodingFailure }
                result.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
            } while status != Z_STREAM_END
            return result
        }
    }

    private static func validateGzip(_ input: Data, equals approved: Data) throws {
        // The original exporter used a plain gzip header. Optional filename,
        // comment or extra fields could carry content outside the inflated NDJSON.
        guard input.count >= 18, input.count <= Int(uInt.max), input[3] == 0 else {
            throw AzureBlobError.privacyRejected
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AzureBlobError.privacyRejected
        }
        defer { inflateEnd(&stream) }
        try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var offset = 0
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard status == Z_OK || status == Z_STREAM_END,
                      count <= approved.count - offset,
                      approved[offset..<(offset + count)].elementsEqual(buffer.prefix(count)) else {
                    throw AzureBlobError.privacyRejected
                }
                offset += count
            } while status != Z_STREAM_END
            // No ignored tail, concatenated gzip member or extra JSON field may leak.
            guard offset == approved.count, stream.avail_in == 0 else { throw AzureBlobError.privacyRejected }
        }
    }
}

enum AzureBlobError: Error, Equatable {
    case invalidConfiguration, encodingFailure, networkFailure, invalidResponse
    case persistenceFailure, invalidStoredBatch, destinationChanged
    case privacyRejected
    case cancelled
    case httpFailure(Int)
}

// The owned session uses this delegate for BOTH connection- and task-level policy.
final class BlobRequestDelegate: NSObject, URLSessionDataDelegate, Sendable {
    typealias Response = (status: Int, code: String?)

    private struct Pending {
        let task: URLSessionDataTask
        var continuation: CheckedContinuation<Response, any Error>?
        var response: Response?
        var cancelled = false
    }

    // flush sends sequentially. Retain one task/continuation and fixed-size receipt
    // metadata, never a response body, untrusted error string, or response history.
    private let pending = Mutex<Pending?>(nil)
    private let control: BlobRequestControl?

    private let responseBytesObserved: (@Sendable (Int) -> Void)?

    init(control: BlobRequestControl? = nil, responseBytesObserved: (@Sendable (Int) -> Void)? = nil) {
        self.control = control
        self.responseBytesObserved = responseBytesObserved
        super.init()
    }

    func response(for request: URLRequest, using session: URLSession, overwriteReceiptEligible: Bool = false) async throws -> Response {
        if let control {
            return try await control.response(for: request, using: session, overwriteReceiptEligible: overwriteReceiptEligible)
        }
        let task = session.dataTask(with: request) // No completion-handler aggregation.
        pending.withLock {
            precondition($0 == nil, "Blob requests must be sequential")
            $0 = Pending(task: task)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let start = pending.withLock { value in
                    guard var current = value, !current.cancelled else {
                        value = nil
                        return false
                    }
                    current.continuation = continuation
                    value = current
                    return true
                }
                if start {
                    task.resume()
                } else {
                    task.cancel()
                    continuation.resume(throwing: AzureBlobError.networkFailure)
                }
            }
        } onCancel: {
            let continuation = self.pending.withLock { value -> CheckedContinuation<Response, any Error>? in
                guard var current = value, current.task === task else { return nil }
                if let continuation = current.continuation {
                    value = nil
                    return continuation
                }
                // Cancellation can arrive before the continuation is installed.
                current.cancelled = true
                value = current
                return nil
            }
            if let continuation {
                task.cancel()
                continuation.resume(throwing: AzureBlobError.networkFailure)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let control {
            control.receive(response, task: dataTask)
            completionHandler(.allow)
            return
        }
        pending.withLock { value in
            guard value?.task === dataTask else { return }
            if let http = response as? HTTPURLResponse, http.url == dataTask.originalRequest?.url {
                // Only this exact code participates in receipts; do not retain
                // arbitrary headers/error bodies from a failed request.
                let overwrite = http.value(forHTTPHeaderField: "x-ms-error-code") == "UnauthorizedBlobOverwrite"
                value?.response = (http.statusCode, overwrite ? "UnauthorizedBlobOverwrite" : nil)
            } else {
                value?.response = nil
            }
        }
        completionHandler(.allow) // Drain to terminal completion; headers alone are not a receipt.
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Streaming discard: no buffering, file output, logging or intentional cancellation.
        // Internal, session-owned observation only; never participates in receipts.
        // Invoke outside locks and expose only the count, not response content.
        responseBytesObserved?(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let control { control.complete(task: task, error: error); return }
        let completion = pending.withLock { value -> (CheckedContinuation<Response, any Error>, Result<Response, any Error>)? in
            guard let current = value, current.task === task, let continuation = current.continuation else { return nil }
            value = nil
            if error != nil || current.cancelled {
                return (continuation, .failure(AzureBlobError.networkFailure))
            }
            guard let response = current.response else {
                return (continuation, .failure(AzureBlobError.invalidResponse))
            }
            return (continuation, .success(response))
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(to challenge: URLAuthenticationChallenge,
                         completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// Instance-owned, internal scheduling only. Nil in ordinary construction.
struct BlobRequestSynchronization: Sendable {
    enum StartEvent: Sendable { case didInvokeResume, didFinishStartAttempt }
    var afterGenerationRegistered: (@Sendable () async -> Void)?
    var afterCallerControlCancelled: (@Sendable () -> Void)?
    var afterGenerationFinished: (@Sendable () -> Void)?
    var beforeWorkerErrorHandling: (@Sendable () async -> Void)?
    var beforeRequestStart: (@Sendable () async -> Void)?
    var afterReceiptCommitted: (@Sendable () async -> Void)?
    var observeStart: (@Sendable (StartEvent) -> Void)?
}

/// One public flush generation. Cancellation is permanent; continuations have one owner.
final class BlobRequestControl: Sendable {
    typealias Response = BlobRequestDelegate.Response
    private struct Pending {
        let task: URLSessionDataTask
        let continuation: CheckedContinuation<Response, any Error>
        let overwriteReceiptEligible: Bool
        var response: Response?
    }
    private struct State { var cancelled = false; var pending: Pending? }
    struct Cancellation: Sendable {
        let first: Bool
        let task: URLSessionTask?
        let continuation: CheckedContinuation<Response, any Error>?
        func perform() {
            task?.cancel()
            continuation?.resume(throwing: AzureBlobError.cancelled)
        }
    }
    private let state = Mutex(State())
    private let synchronization: BlobRequestSynchronization?
    init(synchronization: BlobRequestSynchronization? = nil) { self.synchronization = synchronization }

    // May be called under the service mutex; effects are deliberately returned, not executed here.
    func cancel() -> Cancellation {
        state.withLock { value in
            let first = !value.cancelled
            value.cancelled = true
            let pending = value.pending
            value.pending = nil
            return Cancellation(first: first, task: pending?.task, continuation: pending?.continuation)
        }
    }

    func response(for request: URLRequest, using session: URLSession, overwriteReceiptEligible: Bool) async throws -> Response {
        try await withTaskCancellationHandler {
            if Task.isCancelled { throw AzureBlobError.cancelled }
            await synchronization?.beforeRequestStart?() // Cut S: handler installed, no Foundation task yet.
            let task = session.dataTask(with: request)
            return try await withCheckedThrowingContinuation { continuation in
                let resumed = state.withLock { value -> Bool in
                    guard !value.cancelled else { return false }
                    precondition(value.pending == nil, "Blob requests must be sequential")
                    value.pending = Pending(task: task, continuation: continuation,
                        overwriteReceiptEligible: overwriteReceiptEligible)
                    task.resume() // The real start and final refusal share this arbitration.
                    return true
                }
                if resumed { synchronization?.observeStart?(.didInvokeResume) }
                synchronization?.observeStart?(.didFinishStartAttempt)
                if !resumed {
                    task.cancel()
                    continuation.resume(throwing: AzureBlobError.cancelled)
                }
            }
        } onCancel: { self.cancel().perform() }
    }

    func receive(_ response: URLResponse, task: URLSessionDataTask) {
        state.withLock { value in
            guard value.pending?.task === task else { return }
            if let http = response as? HTTPURLResponse, http.url == task.originalRequest?.url {
                value.pending?.response = (http.statusCode,
                    http.value(forHTTPHeaderField: "x-ms-error-code") == "UnauthorizedBlobOverwrite" ? "UnauthorizedBlobOverwrite" : nil)
            } else { value.pending?.response = nil }
        }
    }

    func complete(task: URLSessionTask, error: (any Error)?) {
        let completion = state.withLock { value -> (CheckedContinuation<Response, any Error>, Result<Response, any Error>, Bool)? in
            guard let pending = value.pending, pending.task === task else { return nil }
            value.pending = nil
            if error != nil { return (pending.continuation, .failure(AzureBlobError.networkFailure), false) }
            guard let reply = pending.response else { return (pending.continuation, .failure(AzureBlobError.invalidResponse), false) }
            return (pending.continuation, .success(reply), AzureBlobTransport.confirmsDelivery(reply, retransmission: pending.overwriteReceiptEligible))
        }
        guard let (continuation, result, delivered) = completion else { return }
        if delivered, let afterReceipt = synchronization?.afterReceiptCommitted {
            // Cut T: the winner already owns completion. Do not block Foundation's delegate queue.
            Task { await afterReceipt(); continuation.resume(with: result) }
        } else { continuation.resume(with: result) }
    }
}
