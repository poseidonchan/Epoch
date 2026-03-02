import Foundation

public enum InternalDeepLink: Hashable, Sendable {
    case artifact(projectID: UUID, path: String)
    case run(projectID: UUID, runID: UUID)
    case session(projectID: UUID, sessionID: UUID)
}

public enum DeepLinkCodec {
    public static func parse(url: URL) -> InternalDeepLink? {
        guard url.scheme == "app", url.host == "project" else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard let projectToken = components.first,
              let projectID = UUID(uuidString: projectToken)
        else {
            return nil
        }

        if components.count >= 2, components[1] == "artifact" {
            guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let encodedPath = queryItems.first(where: { $0.name == "path" })?.value
            else {
                return nil
            }
            return .artifact(projectID: projectID, path: encodedPath)
        }

        if components.count >= 3, components[1] == "run", let runID = UUID(uuidString: components[2]) {
            return .run(projectID: projectID, runID: runID)
        }

        if components.count >= 3, components[1] == "session", let sessionID = UUID(uuidString: components[2]) {
            return .session(projectID: projectID, sessionID: sessionID)
        }

        return nil
    }

    public static func artifactURL(projectID: UUID, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "app"
        components.host = "project"
        components.path = "/\(projectID.uuidString)/artifact"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url ?? URL(string: "app://project")!
    }

    public static func runURL(projectID: UUID, runID: UUID) -> URL {
        URL(string: "app://project/\(projectID.uuidString)/run/\(runID.uuidString)")!
    }

    public static func sessionURL(projectID: UUID, sessionID: UUID) -> URL {
        URL(string: "app://project/\(projectID.uuidString)/session/\(sessionID.uuidString)")!
    }
}
