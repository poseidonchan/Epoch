import Foundation

@MainActor
internal final class ProjectService {
    private weak var store: AppStore?

    // Private state migrated from AppStore
    var observedTerminalRunIDs: Set<UUID> = []

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Project CRUD

    func createProject(name: String) async -> Project? {
        guard let store else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled Project" : trimmed

        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable {
                var name: String
                var backendEngine: String?
            }
            do {
                let response = try await store.requestCodex(
                    method: "epoch/project/create",
                    params: Params(name: finalName, backendEngine: store.preferredBackendEngine)
                )
                let project: Project = try store.decodeCodexResult(response.result, key: "project")
                upsertProject(project)
                store.sessionsByProject[project.id] = store.sessionsByProject[project.id] ?? []
                store.artifactsByProject[project.id] = store.artifactsByProject[project.id] ?? []
                store.runsByProject[project.id] = store.runsByProject[project.id] ?? []
                store.activeProjectID = project.id
                store.activeSessionID = nil
                return project
            } catch {
                store.lastGatewayErrorMessage = error.localizedDescription
            }
        }

        if store.isGatewayConfigured {
            if !store.isGatewayConnected {
                let connected = await store.ensureGatewayConnectedForChat()
                guard connected else { return nil }
            }
            guard store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return nil }
            struct Params: Codable, Sendable { var name: String }
            do {
                let res = try await gatewayClient.request(method: "projects.create", params: Params(name: finalName))
                let project: Project = try store.decodeGatewayPayload(res.payload, key: "project")
                upsertProject(project)
                store.sessionsByProject[project.id] = store.sessionsByProject[project.id] ?? []
                store.artifactsByProject[project.id] = store.artifactsByProject[project.id] ?? []
                store.runsByProject[project.id] = store.runsByProject[project.id] ?? []
                store.activeProjectID = project.id
                store.activeSessionID = nil
                return project
            } catch {
                store.gatewayConnectionState = .failed(message: error.localizedDescription)
                store.lastGatewayErrorMessage = error.localizedDescription
                return nil
            }
        }

        let project = Project(name: finalName, backendEngine: store.preferredBackendEngine)
        store.projects.insert(project, at: 0)
        store.sessionsByProject[project.id] = []
        store.artifactsByProject[project.id] = []
        store.runsByProject[project.id] = []
        store.activeProjectID = project.id
        store.activeSessionID = nil
        return project
    }

    func renameProject(projectID: UUID, newName: String) {
        guard let store else { return }
        guard let index = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String; var name: String }
            Task {
                _ = try? await store.requestCodex(
                    method: "epoch/project/rename",
                    params: Params(projectId: AppStore.gatewayID(projectID), name: trimmed)
                )
            }
        } else if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String; var name: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "projects.rename",
                    params: Params(projectId: AppStore.gatewayID(projectID), name: trimmed)
                )
            }
        }

        store.projects[index].name = trimmed
        store.projects[index].updatedAt = .now
    }

    func deleteProject(projectID: UUID) {
        guard let store else { return }
        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String }
            Task {
                _ = try? await store.requestCodex(
                    method: "epoch/project/delete",
                    params: Params(projectId: AppStore.gatewayID(projectID))
                )
            }
            removeProjectLocally(projectID: projectID)
            return
        }
        if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "projects.delete",
                    params: Params(projectId: AppStore.gatewayID(projectID))
                )
            }
            removeProjectLocally(projectID: projectID)
            return
        }
        removeProjectLocally(projectID: projectID)
    }

    func projectPermissionLevel(for projectID: UUID) -> SessionPermissionLevel {
        guard let store else { return .default }
        guard let project = store.projects.first(where: { $0.id == projectID }) else { return .default }
        return AppStore.permissionLevel(forCodexSandbox: project.codexSandbox) ?? .default
    }

    func setProjectPermissionLevel(projectID: UUID, level: SessionPermissionLevel) {
        applyProjectPermissionLevelLocally(projectID: projectID, level: level)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncProjectPermissionLevelRemotely(projectID: projectID, level: level)
        }
    }

    func applyProjectPermissionLevelLocally(projectID: UUID, level: SessionPermissionLevel) {
        guard let store else { return }
        guard let index = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        store.projects[index].codexApprovalPolicy = AppStore.codexApprovalPolicyForPermissionChange
        store.projects[index].codexSandbox = AppStore.codexSandbox(for: level)
        store.projects[index].updatedAt = .now
    }

    func syncProjectPermissionLevelRemotely(projectID: UUID, level: SessionPermissionLevel) async {
        guard let store else { return }
        let codexApprovalPolicy = AppStore.codexApprovalPolicyForPermissionChange
        let codexSandbox = AppStore.codexSandbox(for: level)

        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable {
                var projectId: String
                var codexApprovalPolicy: String
                var codexSandbox: JSONValue
            }
            do {
                let response = try await store.requestCodex(
                    method: "epoch/project/update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        codexApprovalPolicy: codexApprovalPolicy,
                        codexSandbox: codexSandbox
                    )
                )
                if let project: Project = try? store.decodeCodexResult(response.result, key: "project") {
                    upsertProject(project)
                }
                store.lastGatewayErrorMessage = nil
                return
            } catch {
                store.lastGatewayErrorMessage = error.localizedDescription
            }
        }

        guard store.isGatewayConfigured else { return }
        let connected = await store.ensureGatewayConnectedForChat()
        guard connected, store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return }

        struct Params: Codable, Sendable {
            var projectId: String
            var codexApprovalPolicy: String
            var codexSandbox: JSONValue
        }

        do {
            let response = try await gatewayClient.request(
                method: "projects.update",
                params: Params(
                    projectId: AppStore.gatewayID(projectID),
                    codexApprovalPolicy: codexApprovalPolicy,
                    codexSandbox: codexSandbox
                )
            )
            if let project: Project = try? store.decodeGatewayPayload(response.payload, key: "project") {
                upsertProject(project)
            }
            store.lastGatewayErrorMessage = nil
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
        }
    }

    func upsertProject(_ project: Project) {
        guard let store else { return }
        if let idx = store.projects.firstIndex(where: { $0.id == project.id }) {
            store.projects[idx] = project
        } else {
            store.projects.insert(project, at: 0)
        }
    }

    func removeProjectLocally(projectID: UUID) {
        guard let store else { return }
        let removedSessionIDs = Set((store.sessionsByProject[projectID] ?? []).map(\.id))

        store.projects.removeAll { $0.id == projectID }
        store.sessionsByProject[projectID] = nil
        store.artifactsByProject[projectID] = nil
        store.workspaceEntriesByProject[projectID] = nil
        store.runsByProject[projectID] = nil

        for sessionID in removedSessionIDs {
            store.messagesBySession[sessionID] = nil
            store.codexItemsBySession[sessionID] = nil
            store.codexProposedPlanTextBySession[sessionID] = nil
            store.codexPendingApprovalsBySession[sessionID] = nil
            store.codexPendingPromptBySession[sessionID] = nil
            store.codexStatusTextBySession[sessionID] = nil
            store.codexTokenUsageBySession[sessionID] = nil
            store.codexFullAccessBySession[sessionID] = nil
            store.clearCodexTurnLifecycleState(sessionID: sessionID, threadID: store.codexThreadBySession[sessionID])
            store.composerService.clearPendingPermissionSync(sessionID: sessionID)
            if let threadId = store.codexThreadBySession[sessionID] {
                store.codexSessionByThread[threadId] = nil
                store.codexThreadBySession[sessionID] = nil
            }
            store.composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: [])
            store.livePlanBySession[sessionID] = nil
            store.liveAgentEventsBySession[sessionID] = nil
            store.activeInlineProcessBySession[sessionID] = nil
            store.sessionContextBySession[sessionID] = nil
            store.permissionLevelBySession[sessionID] = nil
            store.planModeEnabledBySession[sessionID] = nil
            store.selectedModelIdBySession[sessionID] = nil
            store.selectedThinkingLevelBySession[sessionID] = nil
            store.chatService.sessionHistoryRequestsInFlight.remove(sessionID)
            store.chatService.sessionHistoryLastFetchedAtBySession[sessionID] = nil
        }
        store.clearCodexTrajectoryDurations(sessionIDs: removedSessionIDs)
        store.persistedProcessSummaryByMessageID = store.persistedProcessSummaryByMessageID.filter { summary in
            !removedSessionIDs.contains(summary.value.sessionID)
        }
        store.chatService.sessionHistoryPrefetchTasksByProject[projectID]?.cancel()
        store.chatService.sessionHistoryPrefetchTasksByProject[projectID] = nil

        if store.activeProjectID == projectID {
            store.activeProjectID = nil
            store.activeSessionID = nil
            store.isLeftPanelOpen = false
            store.isRightPanelOpen = false
            store.selectedArtifactPath = nil
            store.selectedRunID = nil
        }

        store.workspaceContentCache = store.workspaceContentCache.filter { !$0.key.hasPrefix("\(projectID.uuidString)::") }
        store.workspaceDataCache = store.workspaceDataCache.filter { !$0.key.hasPrefix("\(projectID.uuidString)::") }
    }

    func refreshProjectsFromGateway() async {
        guard let store else { return }
        guard let gatewayClient = store.gatewayClient else { return }
        struct EmptyParams: Codable, Sendable {}
        do {
            let res = try await gatewayClient.request(method: "projects.list", params: EmptyParams())
            let projects: [Project] = try store.decodeGatewayPayload(res.payload, key: "projects")

            let sorted = projects.sorted { $0.updatedAt > $1.updatedAt }
            let projectIDs = Set(sorted.map(\.id))
            store.projects = sorted
            store.persistProjectsCache(sorted)

            store.sessionsByProject = store.sessionsByProject.filter { projectIDs.contains($0.key) }
            store.artifactsByProject = store.artifactsByProject.filter { projectIDs.contains($0.key) }
            store.workspaceEntriesByProject = store.workspaceEntriesByProject.filter { projectIDs.contains($0.key) }
            store.runsByProject = store.runsByProject.filter { projectIDs.contains($0.key) }
            for (prefetchProjectID, task) in store.chatService.sessionHistoryPrefetchTasksByProject where !projectIDs.contains(prefetchProjectID) {
                task.cancel()
                store.chatService.sessionHistoryPrefetchTasksByProject[prefetchProjectID] = nil
            }
            let validSessionIDs = Set(store.sessionsByProject.values.flatMap { $0.map(\.id) })
            store.chatService.sessionHistoryRequestsInFlight = store.chatService.sessionHistoryRequestsInFlight.filter { validSessionIDs.contains($0) }
            store.chatService.sessionHistoryLastFetchedAtBySession = store.chatService.sessionHistoryLastFetchedAtBySession.filter { validSessionIDs.contains($0.key) }

            if let activeProjectID = store.activeProjectID, !projectIDs.contains(activeProjectID) {
                store.activeProjectID = nil
                store.activeSessionID = nil
            }
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
            store.gatewayConnectionState = .failed(message: error.localizedDescription)
        }
    }

    func refreshProjectsFromCodex() async {
        guard let store else { return }
        struct EmptyParams: Codable, Sendable {}
        do {
            let response = try await store.requestCodex(method: "epoch/project/list", params: EmptyParams())
            let projects: [Project] = try store.decodeCodexResult(response.result, key: "projects")

            let sorted = projects.sorted { $0.updatedAt > $1.updatedAt }
            let projectIDs = Set(sorted.map(\.id))
            store.projects = sorted
            store.persistProjectsCache(sorted)

            store.sessionsByProject = store.sessionsByProject.filter { projectIDs.contains($0.key) }
            store.artifactsByProject = store.artifactsByProject.filter { projectIDs.contains($0.key) }
            store.workspaceEntriesByProject = store.workspaceEntriesByProject.filter { projectIDs.contains($0.key) }
            store.runsByProject = store.runsByProject.filter { projectIDs.contains($0.key) }
            for (prefetchProjectID, task) in store.chatService.sessionHistoryPrefetchTasksByProject where !projectIDs.contains(prefetchProjectID) {
                task.cancel()
                store.chatService.sessionHistoryPrefetchTasksByProject[prefetchProjectID] = nil
            }
            let validSessionIDs = Set(store.sessionsByProject.values.flatMap { $0.map(\.id) })
            store.chatService.sessionHistoryRequestsInFlight = store.chatService.sessionHistoryRequestsInFlight.filter { validSessionIDs.contains($0) }
            store.chatService.sessionHistoryLastFetchedAtBySession = store.chatService.sessionHistoryLastFetchedAtBySession.filter { validSessionIDs.contains($0.key) }

            if let activeProjectID = store.activeProjectID, !projectIDs.contains(activeProjectID) {
                store.activeProjectID = nil
                store.activeSessionID = nil
            }
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
            store.codexConnectionState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Session lifecycle

    func createSession(projectID: UUID, title: String?) async -> Session? {
        guard let store else { return nil }
        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable {
                var projectId: String
                var title: String?
                var backendEngine: String?
            }
            do {
                let response = try await store.requestCodex(
                    method: "epoch/session/create",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        title: title,
                        backendEngine: store.preferredBackendEngine
                    )
                )
                var session: Session = try store.decodeCodexResult(response.result, key: "session")
                if session.codexThreadId == nil,
                   let resultObject = response.result?.objectValue,
                   let threadObject = resultObject["thread"]?.objectValue,
                   let threadId = threadObject["id"]?.stringValue,
                   !threadId.isEmpty {
                    session.codexThreadId = threadId
                }
                store.lastGatewayErrorMessage = nil
                upsertSession(session)
                syncCodexSessionMapping(for: session)
                store.codexItemsBySession[session.id] = store.codexItemsBySession[session.id] ?? []
                store.messagesBySession[session.id] = store.messagesBySession[session.id] ?? []
                store.activeProjectID = session.projectID
                store.activeSessionID = session.id
                return session
            } catch {
                store.lastGatewayErrorMessage = store.normalizeGatewayErrorMessage(error)
                return nil
            }
        }

        if store.isGatewayConfigured {
            let fallbackProjectName = store.projects.first(where: { $0.id == projectID })?.name

            if !store.isGatewayConnected {
                let connected = await store.ensureGatewayConnectedForChat()
                guard connected else { return nil }
            }

            guard store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return nil }
            struct Params: Codable, Sendable { var projectId: String; var title: String? }

            var effectiveProjectID = projectID
            var retriedWithResolvedProject = false

            while true {
                do {
                    let res = try await gatewayClient.request(
                        method: "sessions.create",
                        params: Params(projectId: AppStore.gatewayID(effectiveProjectID), title: title)
                    )
                    let session: Session = try store.decodeGatewayPayload(res.payload, key: "session")
                    store.lastGatewayErrorMessage = nil
                    upsertSession(session)
                    store.messagesBySession[session.id] = store.messagesBySession[session.id] ?? []
                    store.activeProjectID = session.projectID
                    store.activeSessionID = session.id
                    return session
                } catch {
                    if !retriedWithResolvedProject,
                       store.isGatewayProjectNotFoundError(error),
                       let resolvedProjectID = await store.resolveGatewayProjectIDForCreate(
                           requestedProjectID: projectID,
                           fallbackProjectName: fallbackProjectName
                       ) {
                        retriedWithResolvedProject = true
                        effectiveProjectID = resolvedProjectID
                        continue
                    }

                    if store.shouldSetGatewayFailedState(for: error) {
                        store.lastGatewayErrorMessage = error.localizedDescription
                        store.gatewayConnectionState = .failed(message: error.localizedDescription)
                    } else {
                        store.lastGatewayErrorMessage = error.localizedDescription
                    }
                    return nil
                }
            }
        }

        guard store.projects.contains(where: { $0.id == projectID }) else { return nil }

        let sessionCount = (store.sessionsByProject[projectID] ?? []).count + 1
        let finalTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = Session(
            projectID: projectID,
            title: finalTitle?.isEmpty == false ? finalTitle! : "Session \(sessionCount)",
            backendEngine: store.preferredBackendEngine
        )

        store.sessionsByProject[projectID, default: []].insert(session, at: 0)
        store.messagesBySession[session.id] = []

        store.activeProjectID = projectID
        store.activeSessionID = session.id
        store.composerService.ensureComposerPrefs(sessionID: session.id)
        return session
    }

    func renameSession(projectID: UUID, sessionID: UUID, newTitle: String) {
        guard let store else { return }
        guard var sessions = store.sessionsByProject[projectID],
              let index = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String; var title: String }
            Task {
                _ = try? await store.requestCodex(
                    method: "epoch/session/update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        title: trimmed
                    )
                )
            }
        } else if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String; var title: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        title: trimmed
                    )
                )
            }
        }

        sessions[index].title = trimmed
        sessions[index].updatedAt = .now
        store.sessionsByProject[projectID] = sessions
    }

    func generateSessionTitleIfNeeded(projectID: UUID, sessionID: UUID) {
        guard let store else { return }
        guard let sessions = store.sessionsByProject[projectID],
              let session = sessions.first(where: { $0.id == sessionID })
        else { return }

        // Only generate if title matches the default "Session N" pattern
        let defaultPattern = /^Session \d+$/
        guard session.title.wholeMatch(of: defaultPattern) != nil else { return }

        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String }
            Task { [weak store] in
                guard let store else { return }
                let response = try? await store.requestCodex(
                    method: "epoch/session/generateTitle",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID)
                    )
                )
                if let response,
                   let session: Session = try? store.decodeCodexResult(response.result, key: "session") {
                    await MainActor.run { store.projectService.upsertSession(session) }
                }
            }
        } else if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.generateTitle",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID)
                    )
                )
            }
        }
    }

    func archiveSession(projectID: UUID, sessionID: UUID) {
        guard let store else { return }
        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String; var lifecycle: String }
            Task {
                _ = try? await store.requestCodex(
                    method: "epoch/session/update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        lifecycle: "archived"
                    )
                )
            }
        } else if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String; var lifecycle: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        lifecycle: "archived"
                    )
                )
            }
        }

        setSessionLifecycle(projectID: projectID, sessionID: sessionID, lifecycle: .archived)
        if store.activeSessionID == sessionID {
            store.activeSessionID = nil
        }
    }

    func unarchiveSession(projectID: UUID, sessionID: UUID) {
        guard let store else { return }
        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String; var lifecycle: String }
            Task {
                _ = try? await store.requestCodex(
                    method: "epoch/session/update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        lifecycle: "active"
                    )
                )
            }
        } else if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String; var lifecycle: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        lifecycle: "active"
                    )
                )
            }
        }

        setSessionLifecycle(projectID: projectID, sessionID: sessionID, lifecycle: .active)
    }

    func deleteSession(projectID: UUID, sessionID: UUID) {
        guard let store else { return }
        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String }
            Task {
                _ = try? await store.requestCodex(
                    method: "epoch/session/delete",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID)
                    )
                )
            }
            removeSessionLocally(projectID: projectID, sessionID: sessionID)
            return
        }
        if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String; var sessionId: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.delete",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID)
                    )
                )
            }
            removeSessionLocally(projectID: projectID, sessionID: sessionID)
            return
        }
        removeSessionLocally(projectID: projectID, sessionID: sessionID)
    }

    func upsertSession(_ session: Session) {
        guard let store else { return }
        var sessions = store.sessionsByProject[session.projectID, default: []]
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.insert(session, at: 0)
        }
        store.sessionsByProject[session.projectID] = sessions
        store.composerService.ensureComposerPrefs(sessionID: session.id)
        normalizeSessionPermissionState(session)
    }

    func updateSessionBackend(projectID: UUID, sessionID: UUID, backendEngine: String) async {
        guard let store else { return }
        let normalized = store.normalizeBackendEngine(backendEngine) ?? "codex-app-server"
        if normalized == "codex-app-server", !store.shouldUseCodexRPC {
            _ = await store.ensureCodexConnectedForChat()
            if !store.shouldUseCodexRPC {
                store.lastGatewayErrorMessage = "Codex backend is selected, but /codex is not connected."
                return
            }
        }

        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable {
                var projectId: String
                var sessionId: String
                var backendEngine: String
            }
            do {
                let response = try await store.requestCodex(
                    method: "epoch/session/update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        backendEngine: normalized
                    )
                )
                var session: Session = try store.decodeCodexResult(response.result, key: "session")
                if session.codexThreadId == nil,
                   let resultObject = response.result?.objectValue,
                   let threadObject = resultObject["thread"]?.objectValue,
                   let threadId = threadObject["id"]?.stringValue,
                   !threadId.isEmpty {
                    session.codexThreadId = threadId
                }
                upsertSession(session)
                syncCodexSessionMapping(for: session)
                store.lastGatewayErrorMessage = nil
            } catch {
                store.lastGatewayErrorMessage = error.localizedDescription
            }
            return
        }

        if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable {
                var projectId: String
                var sessionId: String
                var backendEngine: String
            }
            do {
                let response = try await gatewayClient.request(
                    method: "sessions.update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        backendEngine: normalized
                    )
                )
                if let updated: Session = try? store.decodeGatewayPayload(response.payload, key: "session") {
                    upsertSession(updated)
                    syncCodexSessionMapping(for: updated)
                } else {
                    mutateLocalSession(projectID: projectID, sessionID: sessionID) { session in
                        session.backendEngine = normalized
                    }
                }
                store.lastGatewayErrorMessage = nil
            } catch {
                store.lastGatewayErrorMessage = error.localizedDescription
            }
            return
        }

        mutateLocalSession(projectID: projectID, sessionID: sessionID) { session in
            session.backendEngine = normalized
        }
    }

    private func mutateLocalSession(projectID: UUID, sessionID: UUID, apply: (inout Session) -> Void) {
        guard let store else { return }
        guard var sessions = store.sessionsByProject[projectID],
              let index = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }
        var session = sessions[index]
        apply(&session)
        session.updatedAt = .now
        sessions[index] = session
        store.sessionsByProject[projectID] = sessions
    }

    private func syncCodexSessionMapping(for session: Session) {
        guard let store else { return }
        if let threadId = session.codexThreadId, !threadId.isEmpty {
            store.codexThreadBySession[session.id] = threadId
            store.codexSessionByThread[threadId] = session.id
        } else if let existingThreadId = store.codexThreadBySession[session.id] {
            store.codexThreadBySession[session.id] = nil
            store.codexSessionByThread[existingThreadId] = nil
        }
    }

    private func clearCodexSessionState(_ sessionID: UUID) {
        guard let store else { return }
        store.codexItemsBySession[sessionID] = nil
        store.codexProposedPlanTextBySession[sessionID] = nil
        store.codexPendingApprovalsBySession[sessionID] = nil
        store.codexPendingPromptBySession[sessionID] = nil
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        if let queued = store.codexQueuedInputsBySession[sessionID] {
            for item in queued {
                for attachment in item.attachments {
                    let stored = attachment.storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !stored.isEmpty else { continue }
                    try? FileManager.default.removeItem(atPath: stored)
                }
            }
        }
        store.codexQueuedInputsBySession[sessionID] = nil
        store.codexQueuedInputsLoadedSessions.remove(sessionID)
        store.clearPersistedCodexQueuedInputs(sessionID: sessionID)
        store.codexActiveTurnIDBySession[sessionID] = nil
        store.codexStatusTextBySession[sessionID] = nil
        store.codexTurnDiffBySession[sessionID] = nil
        store.codexTokenUsageBySession[sessionID] = nil
        store.codexFullAccessBySession[sessionID] = nil
        store.clearCodexTurnLifecycleState(sessionID: sessionID, threadID: store.codexThreadBySession[sessionID])
        store.composerService.clearPendingPermissionSync(sessionID: sessionID)
        if let threadId = store.codexThreadBySession[sessionID] {
            store.codexThreadBySession[sessionID] = nil
            store.codexSessionByThread[threadId] = nil
        }
    }

    func removeSessionLocally(projectID: UUID, sessionID: UUID) {
        guard let store else { return }
        guard var sessions = store.sessionsByProject[projectID] else { return }
        sessions.removeAll { $0.id == sessionID }
        store.sessionsByProject[projectID] = sessions

        store.messagesBySession[sessionID] = nil
        store.codexItemsBySession[sessionID] = nil
        store.codexProposedPlanTextBySession[sessionID] = nil
        store.codexPendingApprovalsBySession[sessionID] = nil
        store.codexPendingPromptBySession[sessionID] = nil
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        if let queued = store.codexQueuedInputsBySession[sessionID] {
            for item in queued {
                for attachment in item.attachments {
                    let stored = attachment.storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !stored.isEmpty else { continue }
                    try? FileManager.default.removeItem(atPath: stored)
                }
            }
        }
        store.codexQueuedInputsBySession[sessionID] = nil
        store.codexQueuedInputsLoadedSessions.remove(sessionID)
        store.clearPersistedCodexQueuedInputs(sessionID: sessionID)
        store.codexActiveTurnIDBySession[sessionID] = nil
        store.codexStatusTextBySession[sessionID] = nil
        store.codexTurnDiffBySession[sessionID] = nil
        store.codexTokenUsageBySession[sessionID] = nil
        store.codexFullAccessBySession[sessionID] = nil
        store.clearCodexTurnLifecycleState(sessionID: sessionID, threadID: store.codexThreadBySession[sessionID])
        store.composerService.clearPendingPermissionSync(sessionID: sessionID)
        if let threadId = store.codexThreadBySession[sessionID] {
            store.codexSessionByThread[threadId] = nil
            store.codexThreadBySession[sessionID] = nil
        }
        store.composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: [])
        store.livePlanBySession[sessionID] = nil
        store.liveAgentEventsBySession[sessionID] = nil
        store.activeInlineProcessBySession[sessionID] = nil
        store.persistedProcessSummaryByMessageID = store.persistedProcessSummaryByMessageID.filter { summary in
            summary.value.sessionID != sessionID
        }
        store.sessionContextBySession[sessionID] = nil
        store.permissionLevelBySession[sessionID] = nil
        store.planModeEnabledBySession[sessionID] = nil
        store.selectedModelIdBySession[sessionID] = nil
        store.selectedThinkingLevelBySession[sessionID] = nil
        store.pendingComposerAttachmentsBySession[sessionID] = nil
        store.chatService.sessionHistoryRequestsInFlight.remove(sessionID)
        store.chatService.sessionHistoryLastFetchedAtBySession[sessionID] = nil
        store.clearCodexTrajectoryDurations(sessionID: sessionID)
        if var runs = store.runsByProject[projectID] {
            for index in runs.indices where runs[index].sessionID == sessionID {
                runs[index].sessionID = nil
            }
            store.runsByProject[projectID] = runs
        }

        if store.activeSessionID == sessionID {
            store.activeSessionID = nil
        }
    }

    func setSessionLifecycle(projectID: UUID, sessionID: UUID, lifecycle: SessionLifecycle) {
        guard let store else { return }
        guard var sessions = store.sessionsByProject[projectID],
              let idx = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }

        sessions[idx].lifecycle = lifecycle
        sessions[idx].updatedAt = .now
        store.sessionsByProject[projectID] = sessions
    }

    private func normalizeSessionPermissionState(_ session: Session) {
        guard let store else { return }
        let level = AppStore.permissionLevel(forCodexSandbox: session.codexSandbox) ?? .default
        store.permissionLevelBySession[session.id] = level
        store.codexFullAccessBySession[session.id] = (level == .full)
    }

    private func mergeRuns(projectID: UUID, incoming: [RunRecord]) {
        guard let store else { return }
        let existing = Dictionary(uniqueKeysWithValues: (store.runsByProject[projectID] ?? []).map { ($0.id, $0) })
        let merged = incoming.map { remote in
            var updated = remote
            if let local = existing[remote.id] {
                if updated.activity.isEmpty, !local.activity.isEmpty { updated.activity = local.activity }
                if updated.stepDetails.isEmpty, !local.stepDetails.isEmpty { updated.stepDetails = local.stepDetails }
            }
            return updated
        }
        store.runsByProject[projectID] = merged
    }

    private func applySessionsSnapshot(projectID: UUID, sessions: [Session]) {
        guard let store else { return }
        store.sessionsByProject[projectID] = sessions
        store.persistSessionsCache()
        for session in sessions {
            store.composerService.ensureComposerPrefs(sessionID: session.id)
            normalizeSessionPermissionState(session)
            if let threadId = session.codexThreadId {
                store.codexThreadBySession[session.id] = threadId
                store.codexSessionByThread[threadId] = session.id
            }
        }
    }

    @discardableResult
    func refreshProjectSessionsFromCodex(projectID: UUID, failHard: Bool = false) async -> Bool {
        guard let store else { return false }
        struct SessionsListParams: Codable, Sendable { var projectId: String; var includeArchived: Bool }
        do {
            let sessionsResponse = try await store.requestCodex(
                method: "epoch/session/list",
                params: SessionsListParams(projectId: AppStore.gatewayID(projectID), includeArchived: true)
            )
            let sessions: [Session] = try store.decodeCodexResult(sessionsResponse.result, key: "sessions")
            applySessionsSnapshot(projectID: projectID, sessions: sessions)
            return true
        } catch {
            if failHard {
                store.lastGatewayErrorMessage = error.localizedDescription
                store.codexConnectionState = .failed(message: error.localizedDescription)
            }
            return false
        }
    }

    @discardableResult
    func refreshProjectSessionsFromGateway(projectID: UUID, failHard: Bool = false) async -> Bool {
        guard let store else { return false }
        guard let gatewayClient = store.gatewayClient else { return false }

        struct SessionsListParams: Codable, Sendable { var projectId: String; var includeArchived: Bool }
        do {
            let sessionsRes = try await gatewayClient.request(
                method: "sessions.list",
                params: SessionsListParams(projectId: AppStore.gatewayID(projectID), includeArchived: true)
            )
            let sessions: [Session] = try store.decodeGatewayPayload(sessionsRes.payload, key: "sessions")
            applySessionsSnapshot(projectID: projectID, sessions: sessions)
            return true
        } catch {
            if failHard {
                store.gatewayConnectionState = .failed(message: error.localizedDescription)
            }
            return false
        }
    }

    func refreshProjectRunsFromCodex(projectID: UUID, failHard: Bool = false) async {
        guard let store else { return }
        struct RunsListParams: Codable, Sendable { var projectId: String; var limit: Int }
        do {
            let runsResponse = try await store.requestCodex(
                method: "epoch/run/list",
                params: RunsListParams(projectId: AppStore.gatewayID(projectID), limit: 500)
            )
            let runs: [RunRecord] = try store.decodeCodexResult(runsResponse.result, key: "runs")
            mergeRuns(projectID: projectID, incoming: runs)
        } catch {
            if failHard {
                store.lastGatewayErrorMessage = error.localizedDescription
                store.codexConnectionState = .failed(message: error.localizedDescription)
            }
        }
    }

    func refreshProjectRunsFromGateway(projectID: UUID, failHard: Bool = false) async {
        guard let store else { return }
        guard let gatewayClient = store.gatewayClient else { return }

        struct RunsListParams: Codable, Sendable { var projectId: String }
        do {
            let runsRes = try await gatewayClient.request(
                method: "runs.list",
                params: RunsListParams(projectId: AppStore.gatewayID(projectID))
            )
            let runs: [RunRecord] = try store.decodeGatewayPayload(runsRes.payload, key: "runs")
            mergeRuns(projectID: projectID, incoming: runs)
        } catch {
            if failHard {
                store.gatewayConnectionState = .failed(message: error.localizedDescription)
            }
        }
    }

    func refreshProjectFromCodex(projectID: UUID) async {
        guard let store else { return }
        struct ArtifactsListParams: Codable, Sendable { var projectId: String; var limit: Int }

        do {
            let sessionsOk = await refreshProjectSessionsFromCodex(projectID: projectID, failHard: true)
            guard sessionsOk else { return }

            let artifactsResponse = try await store.requestCodex(
                method: "epoch/artifact/list",
                params: ArtifactsListParams(projectId: AppStore.gatewayID(projectID), limit: 500)
            )
            let artifacts: [Artifact] = try store.decodeCodexResult(artifactsResponse.result, key: "artifacts")
            store.artifactsByProject[projectID] = artifacts

            await refreshProjectRunsFromCodex(projectID: projectID, failHard: true)
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
            store.codexConnectionState = .failed(message: error.localizedDescription)
        }
    }

    func refreshProjectFromGateway(projectID: UUID) async {
        guard let store else { return }
        guard let gatewayClient = store.gatewayClient else { return }

        struct ArtifactsListParams: Codable, Sendable { var projectId: String; var prefix: String? }

        do {
            let sessionsOk = await refreshProjectSessionsFromGateway(projectID: projectID, failHard: true)
            guard sessionsOk else { return }

            let artifactsRes = try await gatewayClient.request(
                method: "artifacts.list",
                params: ArtifactsListParams(projectId: AppStore.gatewayID(projectID), prefix: nil)
            )
            let artifacts: [Artifact] = try store.decodeGatewayPayload(artifactsRes.payload, key: "artifacts")
            store.artifactsByProject[projectID] = artifacts

            await refreshProjectRunsFromGateway(projectID: projectID, failHard: true)
        } catch {
            store.gatewayConnectionState = .failed(message: error.localizedDescription)
        }
    }

    func refreshWorkspace(
        projectID: UUID,
        includeHidden: Bool = false,
        path: String = ".",
        recursive: Bool = true,
        limit: Int = 10_000
    ) async {
        guard let store else { return }
        guard let gatewayClient = store.gatewayClient else { return }

        struct WorkspaceListParams: Codable, Sendable {
            var projectId: String
            var path: String
            var recursive: Bool
            var includeHidden: Bool
            var limit: Int
        }

        do {
            let response = try await gatewayClient.request(
                method: "workspace.list",
                params: WorkspaceListParams(
                    projectId: AppStore.gatewayID(projectID),
                    path: path,
                    recursive: recursive,
                    includeHidden: includeHidden,
                    limit: max(1, limit)
                )
            )
            let entries: [WorkspaceEntry] = try store.decodeGatewayPayload(response.payload, key: "entries")

            // Invalidate content cache for files that changed
            let oldEntries = store.workspaceEntriesByProject[projectID] ?? []
            let oldByPath: [String: WorkspaceEntry] = Dictionary(
                oldEntries.map { ($0.path, $0) },
                uniquingKeysWith: { _, last in last }
            )
            let prefix = "\(projectID.uuidString)::"
            for entry in entries {
                if let old = oldByPath[entry.path],
                   old.modifiedAt == entry.modifiedAt,
                   old.sizeBytes == entry.sizeBytes {
                    continue
                }
                store.workspaceContentCache.removeValue(forKey: prefix + entry.path)
                store.workspaceDataCache.removeValue(forKey: prefix + entry.path)
            }

            store.workspaceEntriesByProject[projectID] = entries.sorted { $0.path < $1.path }
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Artifact management

    func addProjectLink(projectID: UUID, url: String) async {
        guard let store else { return }
        guard store.projects.contains(where: { $0.id == projectID }) else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if store.isGatewayConnected, let base = store.gatewayHTTPBaseURL() {
            let endpoint = base.appendingPathComponent("projects/\(projectID.uuidString)/links")
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(store.gatewayToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["url": trimmed])

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
                let decoded = try store.gatewayJSONDecoder.decode(AppStore.GatewayUploadResponse.self, from: data)
                _ = upsertArtifact(
                    projectID: projectID,
                    path: decoded.path,
                    createdBySessionID: nil,
                    origin: .linkUpload,
                    sizeBytes: nil,
                    indexStatus: .processing,
                    indexSummary: nil,
                    indexedAt: nil
                )
            } catch {
                // Link upload failed silently
            }
        }
    }

    func uploadProjectFiles(projectID: UUID, files: [AppStore.ProjectUploadFile], createdBySessionID: UUID?) async {
        guard let store else { return }
        guard store.projects.contains(where: { $0.id == projectID }) else { return }

        let cleaned = files.compactMap { file -> AppStore.ProjectUploadFile? in
            let name = sanitizeUploadFileName(file.fileName)
            guard !name.isEmpty, !file.data.isEmpty else { return nil }
            return AppStore.ProjectUploadFile(fileName: name, data: file.data, mimeType: file.mimeType)
        }
        guard !cleaned.isEmpty else { return }

        if store.isGatewayConnected, store.gatewayHTTPBaseURL() != nil {
            for file in cleaned {
                let optimisticPath = "uploads/\(file.fileName)"
                _ = upsertArtifact(
                    projectID: projectID,
                    path: optimisticPath,
                    createdBySessionID: createdBySessionID,
                    origin: .userUpload,
                    sizeBytes: file.data.count,
                    indexStatus: .processing,
                    indexSummary: nil,
                    indexedAt: nil
                )

                do {
                    let response = try await uploadProjectFileToGateway(projectID: projectID, file: file)
                    if response.path != optimisticPath {
                        if var artifacts = store.artifactsByProject[projectID] {
                            artifacts.removeAll { $0.path == optimisticPath }
                            store.artifactsByProject[projectID] = artifacts
                        }
                    }
                    _ = upsertArtifact(
                        projectID: projectID,
                        path: response.path,
                        createdBySessionID: createdBySessionID,
                        origin: .userUpload,
                        sizeBytes: file.data.count,
                        indexStatus: .processing,
                        indexSummary: nil,
                        indexedAt: nil
                    )
                } catch {
                    store.lastGatewayErrorMessage = error.localizedDescription
                    _ = upsertArtifact(
                        projectID: projectID,
                        path: optimisticPath,
                        createdBySessionID: createdBySessionID,
                        origin: .userUpload,
                        sizeBytes: file.data.count,
                        indexStatus: .failed,
                        indexSummary: error.localizedDescription,
                        indexedAt: nil
                    )
                }
            }
        } else {
            addUploadedFiles(projectID: projectID, fileNames: cleaned.map(\.fileName), createdBySessionID: createdBySessionID)
        }

        if let projectIndex = store.projects.firstIndex(where: { $0.id == projectID }) {
            store.projects[projectIndex].updatedAt = .now
        }
    }

    func addUploadedFiles(projectID: UUID, fileNames: [String], createdBySessionID: UUID?) {
        guard let store else { return }
        guard store.projects.contains(where: { $0.id == projectID }) else { return }

        let cleaned = fileNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return }

        for name in cleaned {
            let fileName = URL(fileURLWithPath: name).lastPathComponent
            guard !fileName.isEmpty else { continue }

            let path = "uploads/\(fileName)"
            _ = upsertArtifact(
                projectID: projectID,
                path: path,
                createdBySessionID: createdBySessionID,
                origin: .userUpload,
                indexStatus: .processing
            )
        }

        if let projectIndex = store.projects.firstIndex(where: { $0.id == projectID }) {
            store.projects[projectIndex].updatedAt = .now
        }
    }

    func removeUploadedFile(projectID: UUID, path: String) {
        guard let store else { return }
        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable { var projectId: String; var path: String }
            Task {
                _ = try? await store.requestCodex(
                    method: "epoch/artifact/delete",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        path: path
                    )
                )
            }
            removeUploadedFileLocally(projectID: projectID, path: path)
            return
        }
        if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable { var projectId: String; var path: String }
            Task {
                _ = try? await gatewayClient.request(
                    method: "artifacts.delete",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        path: path
                    )
                )
            }
            removeUploadedFileLocally(projectID: projectID, path: path)
            return
        }
        removeUploadedFileLocally(projectID: projectID, path: path)
    }

    func removeUploadedFileLocally(projectID: UUID, path: String) {
        guard let store else { return }
        guard store.projects.contains(where: { $0.id == projectID }) else { return }

        if var artifacts = store.artifactsByProject[projectID] {
            let origin = artifacts.first(where: { $0.path == path })?.origin
            guard origin == .userUpload || origin == .linkUpload else { return }
            artifacts.removeAll { $0.path == path }
            store.artifactsByProject[projectID] = artifacts
        }

        if var runs = store.runsByProject[projectID] {
            for idx in runs.indices {
                runs[idx].producedArtifactPaths.removeAll { $0 == path }
            }
            store.runsByProject[projectID] = runs
        }

        if store.selectedArtifactPath == path { store.selectedArtifactPath = nil }
        if store.highlightedArtifactPath == path { store.highlightedArtifactPath = nil }

        store.artifactContentCache["\(projectID.uuidString)::\(path)"] = nil
        store.artifactDataCache["\(projectID.uuidString)::\(path)"] = nil

        if let projectIndex = store.projects.firstIndex(where: { $0.id == projectID }) {
            store.projects[projectIndex].updatedAt = .now
        }
    }

    func fetchArtifactContent(projectID: UUID, path: String) async -> String {
        guard let store else { return "" }
        let key = "\(projectID.uuidString)::\(path)"
        if let cached = store.artifactContentCache[key] { return cached }

        if !path.lowercased().hasPrefix("uploads/"),
           store.isGatewayConnected,
           let gatewayClient = store.gatewayClient {
            struct WorkspaceContentParams: Codable, Sendable {
                var projectId: String
                var path: String
                var offset: Int?
                var length: Int?
            }
            struct WorkspaceContentPayload: Codable, Sendable {
                var path: String
                var data: String
                var eof: Bool
                var encoding: String
            }
            do {
                let response = try await gatewayClient.request(
                    method: "workspace.content",
                    params: WorkspaceContentParams(
                        projectId: AppStore.gatewayID(projectID),
                        path: path,
                        offset: nil,
                        length: nil
                    )
                )
                let payload: WorkspaceContentPayload = try store.decodeGatewayPayloadObject(response.payload)
                store.artifactContentCache[key] = payload.data
                return payload.data
            } catch {
                // Fall through to legacy artifact endpoints.
            }
        }

        if store.isGatewayConnected, let base = store.gatewayHTTPBaseURL() {
            var components = URLComponents(
                url: base.appendingPathComponent("projects/\(projectID.uuidString)/artifacts/content"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "path", value: path)]
            if let url = components?.url {
                var req = URLRequest(url: url)
                req.setValue("Bearer \(store.gatewayToken)", forHTTPHeaderField: "Authorization")
                if let (data, _) = try? await URLSession.shared.data(for: req) {
                    let content = String(decoding: data, as: UTF8.self)
                    store.artifactContentCache[key] = content
                    return content
                }
            }
        }

        let content = await store.backend.fetchArtifactContent(projectID: projectID, path: path)
        store.artifactContentCache[key] = content
        return content
    }

    func fetchArtifactData(projectID: UUID, path: String) async -> Data? {
        guard let store else { return nil }
        let key = "\(projectID.uuidString)::\(path)"
        if let cached = store.artifactDataCache[key] { return cached }

        if !path.lowercased().hasPrefix("uploads/"),
           store.isGatewayConnected,
           let gatewayClient = store.gatewayClient {
            struct WorkspaceRawParams: Codable, Sendable {
                var projectId: String
                var path: String
            }
            struct WorkspaceRawPayload: Codable, Sendable {
                var path: String
                var data: String
                var encoding: String
                var sizeBytes: Int?
                var eof: Bool?
            }
            do {
                let response = try await gatewayClient.request(
                    method: "workspace.raw",
                    params: WorkspaceRawParams(projectId: AppStore.gatewayID(projectID), path: path)
                )
                let payload: WorkspaceRawPayload = try store.decodeGatewayPayloadObject(response.payload)
                if payload.encoding.lowercased() == "base64",
                   let decoded = Data(base64Encoded: payload.data) {
                    store.artifactDataCache[key] = decoded
                    return decoded
                }
            } catch {
                // Fall through to legacy artifact endpoints.
            }
        }

        guard store.isGatewayConnected, let base = store.gatewayHTTPBaseURL() else { return nil }

        var components = URLComponents(
            url: base.appendingPathComponent("projects/\(projectID.uuidString)/artifacts/raw"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(store.gatewayToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            store.artifactDataCache[key] = data
            return data
        } catch {
            return nil
        }
    }

    @discardableResult
    func upsertArtifact(
        projectID: UUID,
        path: String,
        createdBySessionID: UUID?,
        origin: ArtifactOrigin,
        sizeBytes: Int? = nil,
        indexStatus: ArtifactIndexStatus? = nil,
        indexSummary: String? = nil,
        indexedAt: Date? = nil
    ) -> Artifact {
        guard let store else { return Artifact(projectID: projectID, path: path, origin: origin) }
        var artifacts = store.artifactsByProject[projectID, default: []]

        if let idx = artifacts.firstIndex(where: { $0.path == path }) {
            artifacts[idx].modifiedAt = .now
            artifacts[idx].createdBySessionID = createdBySessionID
            artifacts[idx].origin = origin
            if let sizeBytes { artifacts[idx].sizeBytes = max(sizeBytes, 0) }
            if let indexStatus {
                artifacts[idx].indexStatus = indexStatus
                if indexStatus == .processing {
                    artifacts[idx].indexSummary = nil
                    artifacts[idx].indexedAt = nil
                }
            }
            if let indexSummary { artifacts[idx].indexSummary = indexSummary }
            if let indexedAt { artifacts[idx].indexedAt = indexedAt }
            let updated = artifacts[idx]
            store.artifactsByProject[projectID] = artifacts
            return updated
        }

        let artifact = Artifact(
            projectID: projectID,
            path: path,
            origin: origin,
            sizeBytes: sizeBytes ?? Int.random(in: 4_096...980_000),
            createdBySessionID: createdBySessionID,
            indexStatus: indexStatus,
            indexSummary: indexSummary,
            indexedAt: indexedAt
        )
        artifacts.append(artifact)
        store.artifactsByProject[projectID] = artifacts
        return artifact
    }

    func upsertArtifactFromEvent(projectID: UUID, artifact: Artifact) {
        guard let store else { return }
        var artifacts = store.artifactsByProject[projectID, default: []]
        if let idx = artifacts.firstIndex(where: { $0.path == artifact.path }) {
            artifacts[idx] = artifact
        } else {
            artifacts.append(artifact)
        }
        store.artifactsByProject[projectID] = artifacts.sorted { $0.path < $1.path }

        let key = "\(projectID.uuidString)::\(artifact.path)"
        store.artifactContentCache[key] = nil
        store.artifactDataCache[key] = nil
    }

    func setTemporaryArtifactHighlight(_ path: String) {
        guard let store else { return }
        store.highlightedArtifactPath = path
        Task { [weak store] in
            try? await Task.sleep(for: .seconds(3))
            guard let store, store.highlightedArtifactPath == path else { return }
            await MainActor.run {
                store.highlightedArtifactPath = nil
            }
        }
    }

    // MARK: - Query helpers

    func sessions(for projectID: UUID) -> [Session] {
        guard let store else { return [] }
        let sessions = store.sessionsByProject[projectID] ?? []
        return sessions.sorted { lhs, rhs in
            if lhs.lifecycle != rhs.lifecycle { return lhs.lifecycle == .active }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func artifacts(for projectID: UUID) -> [Artifact] {
        guard let store else { return [] }
        return (store.artifactsByProject[projectID] ?? []).sorted { $0.path < $1.path }
    }

    func uploadedArtifacts(for projectID: UUID) -> [Artifact] {
        artifacts(for: projectID).filter { $0.origin == .userUpload || $0.origin == .linkUpload }
    }

    func generatedArtifacts(for projectID: UUID) -> [Artifact] {
        artifacts(for: projectID).filter { $0.origin == .generated }
    }

    func workspaceEntries(for projectID: UUID) -> [WorkspaceEntry] {
        guard let store else { return [] }
        return (store.workspaceEntriesByProject[projectID] ?? []).sorted { $0.path < $1.path }
    }

    func fetchWorkspaceContent(projectID: UUID, path: String) async -> String {
        guard let store else { return "" }
        let key = "\(projectID.uuidString)::\(path)"
        if let cached = store.workspaceContentCache[key] { return cached }

        guard store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return "" }

        struct WorkspaceContentParams: Codable, Sendable {
            var projectId: String
            var path: String
        }
        struct WorkspaceContentPayload: Codable, Sendable {
            var path: String
            var data: String
            var eof: Bool
            var encoding: String
        }

        do {
            let response = try await gatewayClient.request(
                method: "workspace.content",
                params: WorkspaceContentParams(projectId: AppStore.gatewayID(projectID), path: path)
            )
            let payload: WorkspaceContentPayload = try store.decodeGatewayPayloadObject(response.payload)
            store.workspaceContentCache[key] = payload.data
            return payload.data
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
            return ""
        }
    }

    func fetchWorkspaceData(projectID: UUID, path: String) async -> Data? {
        guard let store else { return nil }
        let key = "\(projectID.uuidString)::\(path)"
        if let cached = store.workspaceDataCache[key] { return cached }

        guard store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return nil }

        struct WorkspaceRawParams: Codable, Sendable {
            var projectId: String
            var path: String
        }
        struct WorkspaceRawPayload: Codable, Sendable {
            var path: String
            var data: String
            var encoding: String
            var sizeBytes: Int?
            var eof: Bool?
        }

        do {
            let response = try await gatewayClient.request(
                method: "workspace.raw",
                params: WorkspaceRawParams(projectId: AppStore.gatewayID(projectID), path: path)
            )
            let payload: WorkspaceRawPayload = try store.decodeGatewayPayloadObject(response.payload)
            guard payload.encoding.lowercased() == "base64",
                  let data = Data(base64Encoded: payload.data) else {
                return nil
            }
            store.workspaceDataCache[key] = data
            return data
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
            return nil
        }
    }

    func runs(for projectID: UUID) -> [RunRecord] {
        guard let store else { return [] }
        return (store.runsByProject[projectID] ?? []).sorted { $0.initiatedAt > $1.initiatedAt }
    }

    func run(runID: UUID) -> RunRecord? {
        guard let store else { return nil }
        for runs in store.runsByProject.values {
            if let matched = runs.first(where: { $0.id == runID }) { return matched }
        }
        return nil
    }

    func hasActiveRun(projectID: UUID, sessionID: UUID) -> Bool {
        guard let store else { return false }
        return (store.runsByProject[projectID] ?? []).contains { run in
            run.sessionID == sessionID && (run.status == .queued || run.status == .running)
        }
    }

    func runLabel(for run: RunRecord) -> String {
        switch run.status {
        case .queued: return "Queued"
        case .running: return "Running step \(run.currentStep)/\(max(run.totalSteps, 1))"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    // MARK: - Run management

    func mutateRun(projectID: UUID, runID: UUID, mutate: (inout RunRecord) -> Void) {
        guard let store else { return }
        guard var runs = store.runsByProject[projectID],
              let idx = runs.firstIndex(where: { $0.id == runID })
        else { return }

        let previous = runs[idx]
        mutate(&runs[idx])
        let updated = runs[idx]
        store.runsByProject[projectID] = runs
        emitRunCompletionSignalIfNeeded(projectID: projectID, previousRun: previous, updatedRun: updated)
    }

    func upsertRun(projectID: UUID, run: RunRecord) {
        guard let store else { return }
        var runs = store.runsByProject[projectID, default: []]
        var previousRun: RunRecord?
        var updatedRun = run
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            var merged = run
            let existing = runs[idx]
            previousRun = existing
            if merged.activity.isEmpty, !existing.activity.isEmpty { merged.activity = existing.activity }
            if merged.stepDetails.isEmpty, !existing.stepDetails.isEmpty { merged.stepDetails = existing.stepDetails }
            runs[idx] = merged
            updatedRun = merged
        } else {
            runs.insert(run, at: 0)
        }
        store.runsByProject[projectID] = runs.sorted { $0.initiatedAt > $1.initiatedAt }
        if let previousRun {
            emitRunCompletionSignalIfNeeded(projectID: projectID, previousRun: previousRun, updatedRun: updatedRun)
        }
    }

    func appendRunActivity(
        projectID: UUID,
        runID: UUID,
        sessionID: UUID,
        type: RunActionType,
        summary: String,
        detail: String
    ) {
        guard let store else { return }
        let event = RunActionEvent(type: type, summary: summary, detail: detail)
        mutateRun(projectID: projectID, runID: runID) { run in
            run.activity.append(event)
        }
        let body = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? summary
            : "\(summary)\n\(detail)"

        let message = ChatMessage(sessionID: sessionID, role: .tool, text: body)
        store.messagesBySession[sessionID, default: []].append(message)
    }

    func applyRunLogDelta(_ payload: RunLogDeltaPayload) {
        guard let store else { return }
        guard var runs = store.runsByProject[payload.projectId] else { return }
        guard let idx = runs.firstIndex(where: { $0.id == payload.runId }) else { return }
        let trimmed = payload.delta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            runs[idx].logSnippet = trimmed
        }
        store.runsByProject[payload.projectId] = runs
    }

    func emitRunCompletionSignalIfNeeded(
        projectID: UUID,
        previousRun: RunRecord,
        updatedRun: RunRecord
    ) {
        guard let store else { return }
        guard !Self.isTerminalRunStatus(previousRun.status),
              Self.isTerminalRunStatus(updatedRun.status)
        else { return }

        guard store.runCompletionNotificationsEnabled else { return }
        guard observedTerminalRunIDs.insert(updatedRun.id).inserted else { return }

        let projectName = store.projects.first(where: { $0.id == projectID })?.name ?? "Epoch Project"
        store.latestRunCompletionSignal = AppStore.RunCompletionSignal(
            projectID: projectID,
            runID: updatedRun.id,
            sessionID: updatedRun.sessionID,
            projectName: projectName,
            status: updatedRun.status,
            completedAt: updatedRun.completedAt ?? .now
        )
    }

    static func isTerminalRunStatus(_ status: RunStatus) -> Bool {
        switch status {
        case .succeeded, .failed, .canceled: return true
        case .queued, .running: return false
        }
    }

    // MARK: - Private upload helpers

    private func sanitizeUploadFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "upload-\(UUID().uuidString.prefix(8)).bin" }
        let lastPath = URL(fileURLWithPath: trimmed).lastPathComponent
        let cleaned = lastPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return cleaned.isEmpty ? "upload-\(UUID().uuidString.prefix(8)).bin" : cleaned
    }

    private func uploadProjectFileToGateway(
        projectID: UUID,
        file: AppStore.ProjectUploadFile
    ) async throws -> AppStore.GatewayUploadResponse {
        guard let store else {
            throw NSError(
                domain: "Epoch",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Store is no longer available"]
            )
        }
        guard let base = store.gatewayHTTPBaseURL() else {
            throw NSError(
                domain: "Epoch",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Gateway URL is not configured"]
            )
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: base.appendingPathComponent("projects/\(projectID.uuidString)/uploads"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(store.gatewayToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartFormDataBody(file: file, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Epoch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected upload response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw NSError(
                domain: "Epoch",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Upload failed (\(http.statusCode)): \(serverMessage)"]
            )
        }

        return try store.gatewayJSONDecoder.decode(AppStore.GatewayUploadResponse.self, from: data)
    }

    private func multipartFormDataBody(file: AppStore.ProjectUploadFile, boundary: String) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        let safeName = sanitizeUploadFileName(file.fileName)
        let mimeType = file.mimeType ?? "application/octet-stream"

        body.append(Data("--\(boundary)\(lineBreak)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(lineBreak)".utf8))
        body.append(Data("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".utf8))
        body.append(file.data)
        body.append(Data(lineBreak.utf8))
        body.append(Data("--\(boundary)--\(lineBreak)".utf8))
        return body
    }
}
