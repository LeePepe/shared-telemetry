import Foundation

/// Instance-owned acceptance rules. Names, keys and closed values must
/// be reviewed code/config constants, never populated from the events themselves.
/// Numeric syntax and UUID shape cannot establish the meaning/provenance of data.
public struct AzureBlobPrivacyPolicy: Sendable {
    public enum ValueRule: Sendable {
        case finiteNumber
        case label(Set<String>)

        fileprivate func accepts(_ value: String) -> Bool {
            switch self {
            case .finiteNumber:
                let match = value.range(of: #"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?"#,
                                        options: .regularExpression)
                return match == value.startIndex..<value.endIndex && Double(value)?.isFinite == true
            case .label(let values):
                return values.contains(value)
            }
        }
    }

    let events: [String: [String: ValueRule]]
    let apps: Set<String>
    let builds: Set<String>
    let versions: Set<String>

    public init(events: [String: [String: ValueRule]] = [:], apps: Set<String> = [], builds: Set<String> = [],
                versions: Set<String> = []) {
        self.events = events
        self.apps = apps
        self.builds = builds
        self.versions = versions
    }

    func includingHeartbeat(version: String) throws -> AzureBlobPrivacyPolicy {
        guard versions.contains(version) else { throw AzureBlobTelemetryError.invalidConfiguration }
        var events = events
        events["telemetry.heartbeat"] = ["app": .label(apps), "build": .label(builds), "version": .label(versions),
            "pending_batches": .finiteNumber, "dropped_events": .finiteNumber, "last_successful_upload": .finiteNumber,
            "transport": .label(["enabled", "disabled", "uploading", "failed"])]
        return AzureBlobPrivacyPolicy(events: events, apps: apps, builds: builds, versions: versions)
    }

    /// Reject the complete batch without including a name, key or value in errors.
    func validate(_ batch: [TelemetryEvent]) throws {
        for event in batch {
            guard let fields = events[event.name], event.timestamp.timeIntervalSinceReferenceDate.isFinite else {
                throw AzureBlobError.privacyRejected
            }
            for (key, value) in event.properties {
                guard let rule = fields[key], rule.accepts(value) else { throw AzureBlobError.privacyRejected }
            }
        }
    }

    func validateMetadata(app: String, build: String) throws {
        guard apps.contains(app), builds.contains(build) else { throw AzureBlobError.privacyRejected }
    }

    func validatePath(_ path: [String]) throws {
        guard path.count == 5,
              path[2].range(of: #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) == path[2].startIndex..<path[2].endIndex,
              UUID(uuidString: path[3]) != nil, path[4].hasSuffix(".ndjson.gz"),
              UUID(uuidString: String(path[4].dropLast(".ndjson.gz".count))) != nil else {
            throw AzureBlobError.privacyRejected
        }
        try validateMetadata(app: path[0], build: path[1])
    }
}
