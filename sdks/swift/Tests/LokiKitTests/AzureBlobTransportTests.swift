import Foundation
import Synchronization
import XCTest
import zlib
@testable import LokiKit

final class AzureBlobTransportTests: XCTestCase {
    private var directory: URL!
    private var http: BlobHTTPFixture!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlobTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        http = BlobHTTPFixture()
    }

    override func tearDownWithError() throws {
        http.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func transport(build: String = "test build+1", now: Date = Date(timeIntervalSince1970: 1_700_000_000),
                           privacy: AzureBlobPrivacyPolicy = fixturePrivacy) throws -> AzureBlobTransport {
        try AzureBlobTransport(containerURL: http.container, sasQuery: "sv=2023-11-03&sr=c&si=synthetic&sig=fake%2Bonly%2F%3D",
            app: "sample", build: build, installID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            privacy: privacy, configuration: http.session.configuration, now: { now })
    }

    // Fixed synthetic code catalogue, never inferred from queued/request data.
    private static var fixturePrivacy: AzureBlobPrivacyPolicy {
        let names = ["synthetic.\"second\n", "synthetic.collision", "synthetic.server-error", "synthetic.errors",
            "synthetic.destination", "synthetic.prefix", "synthetic.suffix", "synthetic.in-flight", "synthetic.later",
            "synthetic.remove", "synthetic.original", "synthetic.different", "synthetic.redirect", "synthetic.marker",
            "synthetic.checksum", "synthetic.history", "synthetic.process"] + (0..<65).map { "synthetic.\($0)" }
        var events = Dictionary(uniqueKeysWithValues: names.map { ($0, [String: AzureBlobPrivacyPolicy.ValueRule]()) })
        events["synthetic.first"] = ["count": .finiteNumber]
        events["synthetic.retry"] = ["count": .finiteNumber]
        events["synthetic.large"] = Dictionary(uniqueKeysWithValues: (0..<12_000).map { ("metric.\($0)", .finiteNumber) })
        return AzureBlobPrivacyPolicy(events: events, apps: ["sample", "new-app"],
            builds: ["test build+1", "next-build", "2", "路径 #+?%", "new-build", "before-kill", "after-kill"])
    }

    func testDefaultPolicyCannotExportCanaryInBodyOrCreateBlobJournal() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let canary = "synthetic-transcript-CANARY\nnot-telemetry"
        queue.enqueue(TelemetryEvent(name: canary, properties: ["error": canary]))
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let sourceFile = directory.appendingPathComponent("\(id).json")
        let sourceBefore = try Data(contentsOf: sourceFile)
        let sender = try AzureBlobTransport(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "sample", build: "test build+1", installID: UUID(), configuration: http.session.configuration)
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await sender.flush(queue); XCTFail("Default export must be rejected") }
        catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
        // On the vulnerable baseline these assertions inspect the ACTUAL gzip sent
        // through URLSession and the durable body, not only an encoder helper.
        for request in http.requests {
            XCTAssertFalse(String(decoding: try gunzip(requestBody(request)), as: UTF8.self).contains("CANARY"))
        }
        let journal = directory.appendingPathComponent("\(id).azure-blob")
        if FileManager.default.fileExists(atPath: journal.path) {
            let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
            let payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(outer["payload"] as? String)))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let body = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(record["body"] as? String)))
            XCTAssertFalse(String(decoding: try gunzip(body), as: UTF8.self).contains("CANARY"))
        }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try Data(contentsOf: sourceFile), sourceBefore)
    }

    private var privacyPolicy: AzureBlobPrivacyPolicy {
        AzureBlobPrivacyPolicy(events: ["synthetic.safe": ["duration": .finiteNumber, "phase": .label(["done", "retry"])]],
            apps: ["sample"], builds: ["test build+1"])
    }

    private func storedBytes() throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    func testClosedLabelsAndFiniteMetricsSurviveWireAndJournalUnchanged() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let values = ["0", "-0", "1.25", "-2", "1e3", "1E-3"]
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        for value in values {
            queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": value, "phase": "done"], timestamp: instant))
        }
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue); XCTFail("Unconfirmed") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        let body = try requestBody(XCTUnwrap(http.requests.first))
        let lines = try gunzip(body).split(separator: 0x0a)
        let properties = try lines.map { try XCTUnwrap((JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["properties"] as? [String: String]) }
        XCTAssertEqual(properties, values.map { ["duration": $0, "phase": "done"] })
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let journal = try XCTUnwrap(AzureBlobBatch.load(id: id, queue: queue))
        XCTAssertEqual(journal.body, body)
        XCTAssertFalse(String(decoding: try gunzip(journal.body), as: UTF8.self).contains("CANARY"))
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), body)
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).batchesForFlush().isEmpty)
    }

    func testUnknownNamesKeysAndUnsafePermittedKeyValuesBlockWholeBatchBeforeBlobWrites() async throws {
        let canary = "synthetic-transcript-prompt-error-CANARY\n用户文本"
        let invalid = [
            TelemetryEvent(name: canary), TelemetryEvent(name: "synthetic.unknown"),
            TelemetryEvent(name: "synthetic.safe", properties: [canary: "1"]),
            TelemetryEvent(name: "synthetic.safe", properties: ["error": canary]),
            TelemetryEvent(name: "synthetic.safe", properties: ["transcript": canary]),
            TelemetryEvent(name: "synthetic.safe", properties: ["phase": canary]),
            TelemetryEvent(name: "synthetic.safe", properties: ["phase": "unknown"])
        ] + ["NaN", "nan", "Infinity", "inf", "-inf", "1e999", "1.0\n", " 1", "0x10", "01", "+1", canary].map {
            TelemetryEvent(name: "synthetic.safe", properties: ["duration": $0])
        }
        for (index, event) in invalid.enumerated() {
            let store = directory.appendingPathComponent("case-\(index)")
            let queue = TelemetryQueue(storeDirectory: store)
            queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1", "phase": "done"]))
            queue.enqueue(event)
            let files = try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)
            let before = try files.map { try Data(contentsOf: $0) }
            for candidate in [queue, TelemetryQueue(storeDirectory: store)] {
                do { try await transport(privacy: privacyPolicy).flush(candidate); XCTFail("Unsafe batch must be blocked") }
                catch {
                    XCTAssertEqual(error as? AzureBlobError, .privacyRejected)
                    XCTAssertEqual(String(describing: error), "privacyRejected", "Fixed content-free rejection")
                }
                XCTAssertTrue(http.requests.isEmpty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil), files)
                XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
                XCTAssertEqual(candidate.persistenceFailureCount, 0, "Privacy rejection is not a storage failure or delivery")
            }
        }
    }

    func testUnsafeDirtyMemorySuffixCannotRewriteDurablePrefixBeforeValidation() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1"]))
        let before = try storedBytes()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["phase": "synthetic-user-text-CANARY"]))
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        do { try await transport(privacy: privacyPolicy).flush(queue); XCTFail("Do not persist rejected suffix") }
        catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
        XCTAssertEqual(try storedBytes(), before)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try queue.batchesForFlush(retryingWrites: false).flatMap(\.events).count, 2, "Keep both memory events")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testStricterPolicyBlocksFrozenJournalWithoutChangingBytesOrAcknowledgingOverwrite() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1.25", "phase": "done"]))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue) } catch {}
        XCTAssertEqual(http.requests.count, 1)
        let before = try storedBytes()
        let stricter = [
            AzureBlobPrivacyPolicy(),
            AzureBlobPrivacyPolicy(events: ["synthetic.safe": ["duration": .finiteNumber, "phase": .label(["retry"])]], apps: ["sample"], builds: ["test build+1"]),
            AzureBlobPrivacyPolicy(events: privacyPolicy.events, apps: ["different-app"], builds: ["test build+1"]),
            AzureBlobPrivacyPolicy(events: privacyPolicy.events, apps: ["sample"], builds: ["new-build"])
        ]
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        for policy in stricter {
            do { try await transport(privacy: policy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Stricter policy must block") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(try storedBytes(), before)
        }
        try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), try requestBody(XCTUnwrap(http.requests.last)))
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).batchesForFlush().isEmpty)
    }

    func testUnsafeLegacyJournalBodyCannotHideBehindApprovedSourceDigest() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1", "phase": "done"], timestamp: Date(timeIntervalSince1970: 1_700_000_000)))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue) } catch {}
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let valid = try XCTUnwrap(AzureBlobBatch.load(id: id, queue: queue))
        let unsafe = Data("{\"name\":\"synthetic.safe\",\"properties\":{\"duration\":\"1\",\"phase\":\"done\"},\"timestamp\":\"2023-11-14T22:13:20Z\",\"transcript\":\"synthetic-CANARY\"}\n".utf8)
        let unsafeGzip = try gzipFixture(unsafe)
        XCTAssertTrue(String(decoding: try gunzip(unsafeGzip), as: UTF8.self).contains("CANARY"))
        // Optional gzip filename/comment metadata is sent too, even if inflation
        // yields approved NDJSON. The exporter has never generated these fields.
        var hiddenFilename = Data(valid.body.prefix(10))
        hiddenFilename[3] = 0x08
        hiddenFilename.append(Data("synthetic-CANARY\0".utf8))
        hiddenFilename.append(valid.body.dropFirst(10))
        XCTAssertEqual(try gunzip(hiddenFilename), try gunzip(valid.body))
        for body in [unsafeGzip, valid.body + unsafeGzip, valid.body + Data("CANARY".utf8), hiddenFilename] {
            let old = AzureBlobBatch(version: valid.version, queueID: valid.queueID, containerURL: valid.containerURL,
                path: valid.path, sourceDigest: valid.sourceDigest, body: body, mayHaveBeenSent: true)
            try old.save(queue: queue)
            let before = try storedBytes()
            http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
            do { try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Validate actual journal bytes") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(try storedBytes(), before)
        }
    }

    func testUnsafeLegacySourceAndMatchingJournalStayBlockedWithoutMigration() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let id = UUID()
        let canary = "synthetic-error-transcript-CANARY"
        let event = TelemetryEvent(name: "synthetic.safe", properties: ["phase": canary], timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try queue.persistBatch(id: id, events: [event])
        let encoded = Data("{\"name\":\"synthetic.safe\",\"properties\":{\"phase\":\"synthetic-error-transcript-CANARY\"},\"timestamp\":\"2023-11-14T22:13:20Z\"}\n".utf8)
        let legacy = AzureBlobBatch(version: 1, queueID: id, containerURL: http.container,
            path: ["sample", "test build+1", "2023-11-14", UUID().uuidString.lowercased(), "\(UUID().uuidString.lowercased()).ndjson.gz"],
            sourceDigest: AzureBlobBatch.digest(encoded), body: try gzipFixture(encoded), mayHaveBeenSent: true)
        try legacy.save(queue: queue)
        let before = try storedBytes()
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        do { try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Old journal is not policy approval") }
        catch { XCTAssertEqual(String(describing: error), "privacyRejected") }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try storedBytes(), before, "No disposal, rewritten receipt, or migration")
        XCTAssertTrue(String(decoding: try gunzip(legacy.body), as: UTF8.self).contains("CANARY"), "Unsafe legacy bytes remain blocked, not erased")
    }

    func testApprovedLegacyGzipIsValidatedButNeverRecompressedOnRetry() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let id = UUID()
        try queue.persistBatch(id: id, events: [TelemetryEvent(name: "synthetic.safe", properties: ["duration": "1.25", "phase": "done"],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000))])
        let approved = Data("{\"name\":\"synthetic.safe\",\"properties\":{\"duration\":\"1.25\",\"phase\":\"done\"},\"timestamp\":\"2023-11-14T22:13:20Z\"}\n".utf8)
        // A legacy stream with an explicit mtime and uncompressed DEFLATE encoding,
        // different from the current compressor, is still an immutable valid request.
        var body = try gzipFixture(approved)
        body[4] = 17
        let legacy = AzureBlobBatch(version: 1, queueID: id, containerURL: http.container,
            path: ["sample", "test build+1", "2023-11-14", UUID().uuidString.lowercased(), "\(UUID().uuidString.lowercased()).ndjson.gz"],
            sourceDigest: AzureBlobBatch.digest(approved), body: body, mayHaveBeenSent: true)
        try legacy.save(queue: queue)
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), body)
        XCTAssertEqual(try gunzip(body), approved)
        XCTAssertEqual(http.requests.first?.url?.path, "/container/" + legacy.path.joined(separator: "/"))
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testUnknownPathMetadataIsRejectedForNewAndExistingBatches() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.safe"))
        let original = try storedBytes()
        for (app, build) in [("synthetic-CANARY", "test build+1"), ("sample", "synthetic-CANARY")] {
            let sender = try AzureBlobTransport(containerURL: http.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
                app: app, build: build, installID: UUID(), privacy: privacyPolicy, configuration: http.session.configuration)
            do { try await sender.flush(queue); XCTFail("Syntax is not provenance") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertEqual(try storedBytes(), original)
        }
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport(privacy: privacyPolicy).flush(queue) } catch {}
        let valid = try XCTUnwrap(AzureBlobBatch.load(id: XCTUnwrap(queue.batchesForFlush().first?.id), queue: queue))
        for index in 0..<5 {
            var path = valid.path
            path[index] = "synthetic-CANARY"
            try AzureBlobBatch(version: valid.version, queueID: valid.queueID, containerURL: valid.containerURL,
                path: path, sourceDigest: valid.sourceDigest, body: valid.body, mayHaveBeenSent: true).save(queue: queue)
            let before = try storedBytes()
            do { try await transport(privacy: privacyPolicy).flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Restored metadata must be validated") }
            catch { XCTAssertEqual(error as? AzureBlobError, .privacyRejected) }
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(try storedBytes(), before)
        }
    }

    func testPutBlockBlobHasEncodedPathHeadersAndGzipNDJSONThenAcknowledges201() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.first", properties: ["count": "1"],
                                    timestamp: Date(timeIntervalSince1970: 1_700_000_000.125)))
        queue.enqueue(TelemetryEvent(name: "synthetic.\"second\n", timestamp: Date(timeIntervalSince1970: 1_700_000_001)))
        try await transport().flush(queue)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-version"), "2023-11-03")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try requestBody(request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        XCTAssertEqual(Array(body.prefix(3)), [0x1f, 0x8b, 0x08])
        XCTAssertEqual(try gunzip(body), Data((
            "{\"name\":\"synthetic.first\",\"properties\":{\"count\":\"1\"},\"timestamp\":\"2023-11-14T22:13:20Z\"}\n" +
            "{\"name\":\"synthetic.\\\"second\\n\",\"properties\":{},\"timestamp\":\"2023-11-14T22:13:21Z\"}\n").utf8))
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.absoluteString.contains("/container/sample/test%20build%2B1/2023-11-14/00000000-0000-4000-8000-000000000001/"))
        XCTAssertNotNil(UUID(uuidString: url.lastPathComponent.replacingOccurrences(of: ".ndjson.gz", with: "")))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       "sv=2023-11-03&sr=c&si=synthetic&sig=fake%2Bonly%2F%3D")
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testAmbiguousUploadThenRestartReplaysExactBytesAndPathBeforeAcknowledgingOverwrite() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.retry", properties: ["count": "2"],
                                    timestamp: Date(timeIntervalSince1970: 1_700_000_000.987)))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue); XCTFail("Timeout must retain work") } catch {}
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        let first = try XCTUnwrap(http.requests.first)
        let firstBody = try requestBody(first)
        let restarted = TelemetryQueue(storeDirectory: directory)
        http.state.withLock {
            $0.error = nil
            $0.status = 403
            $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"]
        }
        // Recovered JSON has only whole-second timestamps; build and wall clock changed.
        try await transport(build: "next-build", now: Date(timeIntervalSince1970: 1_800_000_000)).flush(restarted)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests.last?.url, first.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), firstBody)
        XCTAssertTrue(try restarted.batchesForFlush().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testInvalidConfigurationFailsBeforeAnyRequestIncludingMalformedSAS() throws {
        for endpoint in ["http://example.invalid/container", "https://u:p@example.invalid/container",
                         "https://example.invalid/container?sig=fake", "https://example.invalid/container#fragment",
                         "https://example.invalid/container/extra", "https://example.invalid/%63ontainer"] {
            XCTAssertThrowsError(try AzureBlobTransport(containerURL: XCTUnwrap(URL(string: endpoint)),
                sasQuery: "sr=c&sig=fake", app: "sample", build: "1", installID: UUID(), configuration: http.session.configuration))
        }
        for query in ["sig=fake%ZZ&sr=c", "sr=c&sig=fake value", "sr=c&sig=fake#fragment", "sr=c&sig=fake\n",
                      "sr=c&sig=", "sr=c&sig=fake&sig=other", "sr=c&sig=fake&comp=block", "sr=c&sp=w&sig=fake"] {
            XCTAssertThrowsError(try AzureBlobTransport(containerURL: http.container,
                sasQuery: query, app: "sample", build: "1", installID: UUID(), configuration: http.session.configuration))
        }
        for segment in ["", ".", "..", "a/b", "a\\b", "line\nbreak"] {
            XCTAssertThrowsError(try AzureBlobTransport(containerURL: http.container,
                sasQuery: "sr=c&sig=fake", app: segment, build: "1", installID: UUID(), configuration: http.session.configuration))
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testFirstOverwriteAndRepeatedDefinitiveRejectionsNeverProveDelivery() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.collision"))
        http.state.withLock {
            $0.status = 403
            $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"]
        }
        for _ in 0..<3 {
            let restarted = TelemetryQueue(storeDirectory: directory)
            do { try await transport().flush(restarted); XCTFail("No unresolved earlier upload") } catch {}
            XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.collision"])
        }
        XCTAssertEqual(Set(http.requests.compactMap(\.url)).count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testFirstServerErrorRemainsAmbiguousUntilExactOverwriteReceiptOnRestart() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.server-error"))
        http.state.withLock { $0.status = 503 }
        do { try await transport().flush(queue); XCTFail("Server error is not success") } catch {}
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        let restarted = TelemetryQueue(storeDirectory: directory)
        try await transport().flush(restarted)
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), try requestBody(XCTUnwrap(http.requests.last)))
        XCTAssertTrue(try restarted.batchesForFlush().isEmpty)
    }

    func testAllOtherHTTPFailuresRetainAmbiguousBatchUntil201() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.errors"))
        http.state.withLock { $0.error = URLError(.networkConnectionLost) }
        do { try await transport().flush(queue); XCTFail("Network outcome is unconfirmed") } catch {}
        let original = try requestBody(XCTUnwrap(http.requests.first))
        let cases: [(Int, String?)] = [
            (200, nil), (202, nil), (204, nil), (403, nil), (403, "AuthenticationFailed"),
            (403, "AuthorizationPermissionMismatch"), (403, "Unknown"), (403, "unauthorizedbloboverwrite"),
            (409, nil), (409, "BlobAlreadyExists"), (409, "UnauthorizedBlobOverwrite"),
            (412, "ConditionNotMet"), (429, nil), (503, nil)
        ]
        for (status, code) in cases {
            http.state.withLock {
                $0.error = nil
                $0.status = status
                $0.headers = code.map { ["x-ms-error-code": $0] } ?? [:]
            }
            do { try await transport().flush(queue); XCTFail("Unconfirmed HTTP \(status)") } catch {}
            XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).batchesForFlush().flatMap(\.events).count, 1)
            XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), original)
        }
        http.state.withLock { $0.status = 201; $0.headers = [:] }
        try await transport().flush(queue)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
        XCTAssertEqual(Set(http.requests.compactMap(\.url)).count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 0)
    }

    func testChangedDestinationDoesNotReceiveOldPayloadOrNewSAS() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.destination"))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        let other = BlobHTTPFixture()
        defer { other.close() }
        let changed = try AzureBlobTransport(containerURL: other.container, sasQuery: "sr=c&sig=other-fake",
            app: "new-app", build: "2", installID: UUID(), privacy: Self.fixturePrivacy, configuration: other.session.configuration)
        do { try await changed.flush(TelemetryQueue(storeDirectory: directory)); XCTFail("Destination changed") }
        catch { XCTAssertEqual(error as? AzureBlobError, .destinationChanged) }
        XCTAssertTrue(other.requests.isEmpty)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
    }

    func testDirtyDurablePrefixAndMemorySuffixCannotUploadUntilFullSourceIsDurable() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.prefix"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        queue.enqueue(TelemetryEvent(name: "synthetic.suffix"))
        do { try await transport().flush(queue); XCTFail("Do not upload a non-durable suffix") } catch {}
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(queue.persistenceFailureCount, 2, "Enqueue and validated pre-upload write; Blob snapshot must not retry before privacy validation")
        XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).batchesForFlush().flatMap(\.events).map(\.name),
                       ["synthetic.prefix"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        XCTAssertEqual(try TelemetryQueue(storeDirectory: directory).batchesForFlush().flatMap(\.events).map(\.name),
                       ["synthetic.prefix", "synthetic.suffix"])
        let bytes = try gunzip(requestBody(XCTUnwrap(http.requests.first)))
        XCTAssertEqual(bytes.filter { $0 == 0x0a }.count, 2)
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport().flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertTrue(try TelemetryQueue(storeDirectory: directory).batchesForFlush().isEmpty)
    }

    func testConcurrentFlushFreezesInFlightBatchAndPreservesNewEnqueues() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.in-flight"))
        let entered = expectation(description: "request in flight")
        let release = DispatchSemaphore(value: 0)
        http.state.withLock { $0.onRequest = { entered.fulfill(); _ = release.wait(timeout: .now() + 5) } }
        let sender = try transport()
        let sending = Task { try await sender.flush(queue) }
        await fulfillment(of: [entered], timeout: 3)
        queue.enqueue(TelemetryEvent(name: "synthetic.later"))
        try await sender.flush(queue)
        XCTAssertEqual(http.requests.count, 1)
        http.state.withLock { $0.onRequest = nil }
        release.signal()
        try await sending.value
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.later"])
        try await sender.flush(queue)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertNotEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testConfirmedDeliveryWithFailedRemovalReplaysSameBodyAfterRestart() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.remove"))
        let store = try XCTUnwrap(directory)
        http.state.withLock {
            $0.onRequest = {
                do { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path) }
                catch { XCTFail("Cannot block fixture removal") }
            }
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        do { try await transport().flush(queue); XCTFail("Removal must fail") } catch {}
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        http.state.withLock { $0.onRequest = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport().flush(TelemetryQueue(storeDirectory: store))
        XCTAssertEqual(http.requests.first?.url, http.requests.last?.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), try requestBody(XCTUnwrap(http.requests.last)))
        XCTAssertTrue(try TelemetryQueue(storeDirectory: store).batchesForFlush().isEmpty)
    }

    func testCorruptOrMismatchedJournalCannotAcknowledgeOrOverwriteQueue() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.original"))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let journal = directory.appendingPathComponent("\(id).azure-blob")
        let saved = try Data(contentsOf: journal)
        try Data("corrupt".utf8).write(to: journal)
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        do { try await transport().flush(queue); XCTFail("Corrupt journal") } catch {}
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try Data(contentsOf: journal), Data("corrupt".utf8))
        try saved.write(to: journal)
        try queue.persistBatch(id: id, events: [TelemetryEvent(name: "synthetic.different")])
        let restarted = TelemetryQueue(storeDirectory: directory)
        do { try await transport().flush(restarted); XCTFail("Same ID is not same content") }
        catch { XCTAssertEqual(error as? AzureBlobError, .invalidStoredBatch) }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try restarted.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.different"])
        XCTAssertEqual(try Data(contentsOf: journal), saved)
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(outer["payload"] as? String)))
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("sig="), "Never persist credentials")
    }

    func testRedirectDoesNotSendPayloadOrSASToAnotherHost() async throws {
        let other = BlobHTTPFixture()
        defer { other.close() }
        http.state.withLock {
            $0.status = 307
            $0.redirect = URL(string: other.container.absoluteString + "?sig=fake-redirect")
        }
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.redirect"))
        do { try await transport().flush(queue); XCTFail("Redirect is not delivery") }
        catch { XCTAssertEqual(error as? AzureBlobError, .httpFailure(307)) }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertTrue(other.requests.isEmpty)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
    }

    func testFailedWriteAheadMarkerPreventsNetworkAndCountsStorageFailure() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.marker"))
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "AuthenticationFailed"] }
        do { try await transport().flush(queue) } catch {}
        XCTAssertEqual(http.requests.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        http.state.withLock { $0.status = 201; $0.headers = [:] }
        do { try await transport().flush(queue); XCTFail("Cannot persist attempt marker") }
        catch { XCTAssertEqual(error as? AzureBlobError, .persistenceFailure) }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await transport().flush(queue)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testJournalChecksumMismatchAndUnavailableJournalPreserveSource() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.checksum"))
        http.state.withLock { $0.error = URLError(.timedOut) }
        do { try await transport().flush(queue) } catch {}
        let id = try XCTUnwrap(queue.batchesForFlush().first?.id)
        let journal = directory.appendingPathComponent("\(id).azure-blob")
        let saved = try Data(contentsOf: journal)
        var outer = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(outer["payload"] as? String)))
        payload[payload.startIndex] ^= 1
        outer["payload"] = payload.base64EncodedString()
        try JSONSerialization.data(withJSONObject: outer).write(to: journal)
        do { try await transport().flush(queue); XCTFail("Checksum mismatch") }
        catch { XCTAssertEqual(error as? AzureBlobError, .invalidStoredBatch) }
        XCTAssertEqual(queue.persistenceFailureCount, 1)
        try saved.write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journal.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path) }
        do { try await transport().flush(queue); XCTFail("Unreadable is not absent") }
        catch { XCTAssertEqual(error as? AzureBlobError, .persistenceFailure) }
        XCTAssertEqual(queue.persistenceFailureCount, 2)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
    }

    func testLegacyHistoryAndRotatedLiveBatchesRetainSendOrder() async throws {
        let historyID = UUID()
        let legacy = "[{\"name\":\"synthetic.history\",\"properties\":{},\"timestamp\":\"2023-11-14T22:13:20Z\"}]"
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("\(historyID).json"))
        let queue = TelemetryQueue(storeDirectory: directory)
        for index in 0..<65 { queue.enqueue(TelemetryEvent(name: "synthetic.\(index)")) }
        try await transport().flush(queue)
        let lines = try http.requests.map { try gunzip(requestBody($0)).split(separator: 0x0a) }
        let names = try lines.map { try $0.map { line in
            try XCTUnwrap((JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])?["name"] as? String)
        } }
        XCTAssertEqual(names, [["synthetic.history"], (0..<64).map { "synthetic.\($0)" }, ["synthetic.64"]])
        XCTAssertEqual(Set(http.requests.compactMap(\.url)).count, 3)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testCredentialRotationRetainsOriginalAppInstallBuildPathAndLargeGzipBody() async throws {
        let queue = TelemetryQueue(storeDirectory: directory)
        let largeSynthetic = Dictionary(uniqueKeysWithValues: (0..<12_000).map { ("metric.\($0)", String($0)) })
        queue.enqueue(TelemetryEvent(name: "synthetic.large", properties: largeSynthetic))
        http.state.withLock { $0.error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/?sig=fake-sensitive")!]) }
        do { try await transport(build: "路径 #+?%").flush(queue); XCTFail("Unconfirmed") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        let first = try XCTUnwrap(http.requests.first)
        let body = try requestBody(first)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: gunzip(body)) as? [String: Any])
        XCTAssertEqual(event["properties"] as? [String: String], largeSynthetic)
        XCTAssertTrue(first.url!.absoluteString.contains("%E8%B7%AF%E5%BE%84%20%23%2B%3F%25"))
        http.state.withLock { $0.error = nil; $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        let changed = try AzureBlobTransport(containerURL: http.container, sasQuery: "?sr=c&sp=c&sig=rotated-fake",
            app: "new-app", build: "new-build", installID: UUID(), privacy: Self.fixturePrivacy, configuration: http.session.configuration)
        try await changed.flush(TelemetryQueue(storeDirectory: directory))
        XCTAssertEqual(http.requests.last?.url?.path, first.url?.path)
        XCTAssertEqual(http.requests.last?.url?.query, "sr=c&sp=c&sig=rotated-fake")
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.last)), body)
    }

#if os(macOS)
    func testProcessKillDuringUploadThenRestartRetransmitsExactDurableRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.environment = [:]
        child.arguments = ["-i", "HOME=\(try XCTUnwrap(environment["HOME"]))", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        if let tmp = environment["TMPDIR"] { child.arguments!.append("TMPDIR=\(tmp)") }
        child.arguments! += ["LOKIKIT_BLOB_CRASH_DIRECTORY=\(directory.path)",
                             "LOKIKIT_BLOB_CRASH_CONTAINER=\(http.container.absoluteString)",
                             CommandLine.arguments[0], "-XCTest",
                             "LokiKitTests.AzureBlobTransportTests/testUploadProcessFixture", Bundle(for: Self.self).bundleURL.path]
        let exited = expectation(description: "isolated upload process killed")
        child.terminationHandler = { _ in exited.fulfill() }
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        await fulfillment(of: [exited], timeout: 15)
        guard !child.isRunning else { return }
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
        let captured = try JSONDecoder().decode(CapturedBlobRequest.self,
            from: Data(contentsOf: directory.appendingPathComponent("request.capture")))
        let queue = TelemetryQueue(storeDirectory: directory)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.process"])
        http.state.withLock { $0.status = 403; $0.headers = ["x-ms-error-code": "UnauthorizedBlobOverwrite"] }
        try await transport(build: "after-kill").flush(queue)
        XCTAssertEqual(http.requests.first?.url, captured.url)
        XCTAssertEqual(try requestBody(XCTUnwrap(http.requests.first)), captured.body)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testUploadProcessFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOKIKIT_BLOB_CRASH_DIRECTORY"],
              let endpoint = environment["LOKIKIT_BLOB_CRASH_CONTAINER"] else { return }
        XCTAssertEqual(Set(environment.keys).subtracting(["HOME", "PATH", "TMPDIR",
            "LOKIKIT_BLOB_CRASH_DIRECTORY", "LOKIKIT_BLOB_CRASH_CONTAINER"]), [])
        let fixture = BlobHTTPFixture(container: try XCTUnwrap(URL(string: endpoint)))
        defer { fixture.close() }
        let store = URL(fileURLWithPath: path)
        let queue = TelemetryQueue(storeDirectory: store)
        queue.enqueue(TelemetryEvent(name: "synthetic.process", timestamp: Date(timeIntervalSince1970: 1_700_000_000.321)))
        fixture.state.withLock {
            $0.onRequest = {
                do {
                    let request = try XCTUnwrap(fixture.requests.first)
                    let capture = CapturedBlobRequest(url: try XCTUnwrap(request.url), body: try requestBody(request))
                    try JSONEncoder().encode(capture).write(to: store.appendingPathComponent("request.capture"), options: .atomic)
                    kill(getpid(), SIGKILL)
                } catch { XCTFail("Could not capture synthetic request before kill") }
            }
        }
        let sender = try AzureBlobTransport(containerURL: fixture.container,
            sasQuery: "sv=2023-11-03&sr=c&si=synthetic&sig=fake%2Bonly%2F%3D", app: "sample", build: "before-kill",
            installID: UUID(), privacy: Self.fixturePrivacy, configuration: fixture.session.configuration)
        try await sender.flush(queue)
        XCTFail("Process should have been killed in mocked upload")
    }
#endif
}

private struct CapturedBlobRequest: Codable {
    let url: URL
    let body: Data
}

// Only routing is shared; each fixture owns its session, requests and response behavior.
// Unregistered requests fail closed instead of touching DNS or any live receiver.
private final class BlobHTTPFixture: @unchecked Sendable {
    struct State {
        var requests: [URLRequest] = []
        var status = 201
        var headers: [String: String] = [:]
        var error: URLError?
        var redirect: URL?
        var onRequest: (@Sendable () -> Void)?
    }
    let state = Mutex(State())
    let container: URL
    let session: URLSession
    var requests: [URLRequest] { state.withLock { $0.requests } }

    init(container: URL? = nil) {
        self.container = container ?? URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid/container")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlobURLProtocol.self]
        session = URLSession(configuration: configuration)
        BlobURLProtocol.fixtures.withLock { $0[self.container.host!] = self }
    }

    func close() {
        session.invalidateAndCancel()
        _ = BlobURLProtocol.fixtures.withLock { $0.removeValue(forKey: container.host!) }
    }
}

private final class BlobURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = Mutex<[String: BlobHTTPFixture]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixtures.withLock({ $0[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = fixture.state.withLock { value in
            value.requests.append(request)
            return (value.status, value.headers, value.error, value.onRequest, value.redirect)
        }
        reply.3?()
        if let error = reply.2 {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: reply.1)!
            if let redirect = reply.4 {
                var redirected = request
                redirected.url = redirect
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private func gunzip(_ input: Data) throws -> Data {
    var stream = z_stream()
    XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
    defer { inflateEnd(&stream) }
    return try input.withUnsafeBytes { source in
        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        var output = Data()
        var status: Int32 = Z_OK
        repeat {
            var buffer = [UInt8](repeating: 0, count: 4096)
            status = buffer.withUnsafeMutableBytes { target in
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(target.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            guard status == Z_OK || status == Z_STREAM_END else { throw URLError(.cannotDecodeRawData) }
            output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
        } while status != Z_STREAM_END
        XCTAssertEqual(stream.avail_in, 0)
        return output
    }
}

// Construct legacy/malformed synthetic wire fixtures independently of the exporter.
// RFC1952 header + one uncompressed DEFLATE block + CRC32/ISIZE trailer.
private func gzipFixture(_ bytes: Data) throws -> Data {
    guard bytes.count < 65_536 else { throw AzureBlobError.encodingFailure }
    let count = UInt16(bytes.count)
    var result = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff, 0x01])
    result.append(contentsOf: [UInt8(truncatingIfNeeded: count), UInt8(count >> 8),
                              UInt8(truncatingIfNeeded: ~count), UInt8((~count) >> 8)])
    result.append(bytes)
    let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
    for value in [UInt32(checksum), UInt32(bytes.count)] {
        for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    return result
}
