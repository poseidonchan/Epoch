import Foundation

enum E2EPaths {
    static var artifactsRoot: URL {
        if let raw = ProcessInfo.processInfo.environment["LABOS_E2E_ARTIFACTS_DIR"], !raw.isEmpty {
            return ensureDirectory(URL(fileURLWithPath: expandPath(raw), isDirectory: true))
        }

        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LabOSE2EArtifacts", isDirectory: true)
        return ensureDirectory(fallback)
    }

    static var stateDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["LABOS_STATE_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: expandPath(raw), isDirectory: true)
        }
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"], !hostHome.isEmpty {
            return URL(fileURLWithPath: hostHome, isDirectory: true)
                .appendingPathComponent(".labos", isDirectory: true)
        }
        return URL(fileURLWithPath: ("~/.labos" as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func artifactsDirectory(for testCaseName: String) -> URL {
        let sanitized = sanitizePathComponent(testCaseName)
        return ensureDirectory(artifactsRoot.appendingPathComponent(sanitized, isDirectory: true))
    }

    static func sanitizePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let candidate = String(filtered)
        let compacted = candidate.replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
        let trimmed = compacted.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return trimmed.isEmpty ? "step" : trimmed
    }

    @discardableResult
    private static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func expandPath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }
}
