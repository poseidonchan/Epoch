import Foundation

public enum APIContract {
    // Projects
    public static let listProjects = "/projects"
    public static let createProject = "/projects"
    public static func renameProject(_ projectID: UUID) -> String { "/projects/\(projectID.uuidString)" }
    public static func deleteProject(_ projectID: UUID) -> String { "/projects/\(projectID.uuidString)" }

    // Sessions
    public static func listSessions(projectID: UUID) -> String {
        "/projects/\(projectID.uuidString)/sessions?includeArchived=true"
    }

    public static func createSession(projectID: UUID) -> String {
        "/projects/\(projectID.uuidString)/sessions"
    }

    public static func updateSession(projectID: UUID, sessionID: UUID) -> String {
        "/projects/\(projectID.uuidString)/sessions/\(sessionID.uuidString)"
    }

    public static func deleteSession(projectID: UUID, sessionID: UUID) -> String {
        "/projects/\(projectID.uuidString)/sessions/\(sessionID.uuidString)"
    }

    // Chat
    public static func postMessage(projectID: UUID, sessionID: UUID) -> String {
        "/projects/\(projectID.uuidString)/sessions/\(sessionID.uuidString)/messages"
    }

    // Artifacts
    public static func listArtifacts(projectID: UUID) -> String {
        "/projects/\(projectID.uuidString)/artifacts"
    }

    public static func artifactContent(projectID: UUID) -> String {
        "/projects/\(projectID.uuidString)/artifacts/content?path=<urlencoded>"
    }

    public static func artifactThumbnail(projectID: UUID) -> String {
        "/projects/\(projectID.uuidString)/artifacts/thumbnail?path=<urlencoded>"
    }

    // Runs
    public static func listRuns(projectID: UUID) -> String {
        "/projects/\(projectID.uuidString)/runs"
    }

    public static func runDetail(projectID: UUID, runID: UUID) -> String {
        "/projects/\(projectID.uuidString)/runs/\(runID.uuidString)"
    }

    public static func createRun(projectID: UUID) -> String {
        "/projects/\(projectID.uuidString)/runs"
    }

    public static func runLogs(projectID: UUID, runID: UUID) -> String {
        "/projects/\(projectID.uuidString)/runs/\(runID.uuidString)/logs"
    }

    // Home resource monitor
    public static let resourceStatus = "/status/resources"
}
