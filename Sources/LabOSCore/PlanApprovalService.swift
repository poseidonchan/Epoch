import Foundation

@MainActor
internal final class PlanApprovalService {
    private unowned let store: AppStore

    // State migrated from AppStore
    var pendingApprovalsBySession: [UUID: PendingApproval] = [:]
    var planSessionByPlanID: [UUID: UUID] = [:]

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Approval API

    func pendingApproval(for sessionID: UUID) -> PendingApproval? {
        pendingApprovalsBySession[sessionID]
    }

    func pendingPlan(for sessionID: UUID) -> ExecutionPlan? {
        pendingApprovalsBySession[sessionID]?.plan
    }

    func cancelPlan(sessionID: UUID) {
        guard let pending = pendingApprovalsBySession.removeValue(forKey: sessionID) else { return }

        if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable {
                var planId: UUID
                var decision: String
            }
            Task {
                _ = try? await gatewayClient.request(
                    method: "exec.approval.resolve",
                    params: Params(planId: pending.planId, decision: "reject")
                )
            }
            return
        }

        let cancellation = ChatMessage(
            sessionID: sessionID,
            role: .system,
            text: "Plan canceled. No run was created for project \(pending.projectId.uuidString.prefix(8))."
        )
        store.messagesBySession[sessionID, default: []].append(cancellation)
    }

    func approvePlan(sessionID: UUID, judgmentResponses: JudgmentResponses? = nil) {
        guard let pending = pendingApprovalsBySession.removeValue(forKey: sessionID) else { return }

        if store.isGatewayConnected, let gatewayClient = store.gatewayClient {
            struct Params: Codable, Sendable {
                var planId: UUID
                var decision: String
                var judgmentResponses: JudgmentResponses?
            }
            Task {
                _ = try? await gatewayClient.request(
                    method: "exec.approval.resolve",
                    params: Params(planId: pending.planId, decision: "approve", judgmentResponses: judgmentResponses)
                )
            }
            return
        }

        let plan = pending.plan
        let stepDetails = plan.steps.map { formatStepDetail(step: $0) }

        let run = RunRecord(
            projectID: plan.projectID,
            sessionID: sessionID,
            status: .queued,
            currentStep: 0,
            totalSteps: max(plan.steps.count, 1),
            logSnippet: "Queued and waiting for execution.",
            stepTitles: plan.steps.map(\.title),
            stepDetails: stepDetails,
            activity: [
                RunActionEvent(
                    type: .info,
                    summary: "Plan approved",
                    detail: "Execution queued with \(max(plan.steps.count, 1)) steps."
                )
            ]
        )

        store.runsByProject[plan.projectID, default: []].insert(run, at: 0)
        store.selectedRunID = run.id

        store.projectService.appendRunActivity(
            projectID: plan.projectID,
            runID: run.id,
            sessionID: sessionID,
            type: .info,
            summary: "Execution started (\(max(plan.steps.count, 1)) planned steps)",
            detail: "Run is queued and will stream tool calls and command outputs."
        )

        Task { [weak self] in
            guard let self else { return }
            await self.execute(plan: plan, runID: run.id)
        }
    }

    // MARK: - Gateway Event Handlers

    func handleApprovalRequested(_ payload: ApprovalRequestedPayload) {
        let pending = PendingApproval(
            planId: payload.planId,
            projectId: payload.projectId,
            sessionId: payload.sessionId,
            agentRunId: payload.agentRunId,
            plan: payload.plan,
            required: payload.required,
            judgment: payload.judgment
        )
        pendingApprovalsBySession[payload.sessionId] = pending
        planSessionByPlanID[payload.planId] = payload.sessionId
    }

    func handleApprovalResolved(planID: UUID, decision: String) {
        _ = decision
        if let sessionID = planSessionByPlanID[planID] {
            pendingApprovalsBySession[sessionID] = nil
        }
        planSessionByPlanID[planID] = nil
    }

    // MARK: - Demo Plan Execution

    private func execute(plan: ExecutionPlan, runID: UUID) async {
        let totalSteps = max(plan.steps.count, 1)

        for (idx, step) in plan.steps.enumerated() {
            let detail = formatStepDetail(step: step)

            store.projectService.mutateRun(projectID: plan.projectID, runID: runID) { run in
                run.status = .running
                run.currentStep = idx + 1
                run.logSnippet = detail
            }

            store.projectService.appendRunActivity(
                projectID: plan.projectID,
                runID: runID,
                sessionID: plan.sessionID,
                type: .toolCall,
                summary: "Tool call · Step \(idx + 1)/\(totalSteps): \(step.runtime.rawValue)",
                detail: toolResultTrace(for: step)
            )
            try? await Task.sleep(for: .milliseconds(120))

            for command in commandTrace(for: step) {
                store.projectService.appendRunActivity(
                    projectID: plan.projectID,
                    runID: runID,
                    sessionID: plan.sessionID,
                    type: .command,
                    summary: "Command executed: \(command)",
                    detail: commandOutput(for: step, command: command)
                )
                try? await Task.sleep(for: .milliseconds(120))
            }

            if step.outputs.isEmpty {
                store.projectService.appendRunActivity(
                    projectID: plan.projectID,
                    runID: runID,
                    sessionID: plan.sessionID,
                    type: .info,
                    summary: "No artifact output declared",
                    detail: "Step \(idx + 1) completed with no file output."
                )
            } else {
                for output in step.outputs {
                    store.projectService.appendRunActivity(
                        projectID: plan.projectID,
                        runID: runID,
                        sessionID: plan.sessionID,
                        type: .output,
                        summary: "Output updated: \(output)",
                        detail: "Artifact written successfully."
                    )
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }

            try? await Task.sleep(for: .milliseconds(550))
        }

        let outputPaths = unique(plan.steps.flatMap(\.outputs))
        let artifacts = outputPaths.map { path in
            store.projectService.upsertArtifact(
                projectID: plan.projectID,
                path: path,
                createdBySessionID: plan.sessionID,
                origin: .generated
            )
        }

        store.projectService.mutateRun(projectID: plan.projectID, runID: runID) { run in
            run.status = .succeeded
            run.currentStep = run.totalSteps
            run.completedAt = .now
            run.logSnippet = "Completed all planned steps."
            run.producedArtifactPaths = outputPaths
        }

        store.projectService.appendRunActivity(
            projectID: plan.projectID,
            runID: runID,
            sessionID: plan.sessionID,
            type: .info,
            summary: "Run completed",
            detail: "Execution finished successfully."
        )

        let refs = artifacts.map { artifact in
            ChatArtifactReference(
                displayText: artifact.path,
                projectID: artifact.projectID,
                path: artifact.path,
                artifactID: artifact.id
            )
        }

        let doneMessage = ChatMessage(
            sessionID: plan.sessionID,
            role: .assistant,
            text: finalReportText(runID: runID, stepCount: max(plan.steps.count, 1), outputPaths: outputPaths),
            artifactRefs: refs
        )
        store.messagesBySession[plan.sessionID, default: []].append(doneMessage)

        if let first = refs.first {
            store.openArtifactReference(first)
        }
    }

    private func finalReportText(runID: UUID, stepCount: Int, outputPaths: [String]) -> String {
        let duration = store.projectService.run(runID: runID).map { record in
            (record.completedAt ?? .now).timeIntervalSince(record.initiatedAt)
        } ?? 0

        let durationText = store.durationFormatter.string(from: duration) ?? "under 1m"
        let outputs = outputPaths.isEmpty
            ? "- No files were generated."
            : outputPaths.map { "- `\($0)`" }.joined(separator: "\n")

        return """
        ## Final report
        - Status: Succeeded
        - Completed steps: \(stepCount)/\(stepCount)
        - Runtime: \(durationText)

        ### Generated outputs
        \(outputs)
        """
    }

    private func formatStepDetail(step: PlanStep) -> String {
        let runtime = step.runtime.rawValue
        let inputSummary = step.inputs.isEmpty ? "none" : step.inputs.joined(separator: ", ")
        let outputSummary = step.outputs.isEmpty ? "none" : step.outputs.joined(separator: ", ")
        return "\(runtime) runtime. Inputs: \(inputSummary). Outputs: \(outputSummary)."
    }

    private func commandTrace(for step: PlanStep) -> [String] {
        let input = step.inputs.first ?? "input.dat"
        let output = step.outputs.first ?? "artifacts/output.dat"

        switch step.runtime {
        case .download:
            return ["curl -L \"\(input)\" -o \(output)"]
        case .python:
            return ["python scripts/run_step.py --input \(input) --output \(output)"]
        case .shell:
            return ["sh -lc \"\(step.title.lowercased())\""]
        case .hpcJob:
            return ["sbatch jobs/step_job.sh --input \(input) --output \(output)"]
        case .notebook:
            return ["jupyter nbconvert --execute \(input) --to notebook --output \(output)"]
        }
    }

    private func commandOutput(for step: PlanStep, command: String) -> String {
        _ = command
        switch step.runtime {
        case .download:
            return "HTTP 200 OK. Downloaded source data and saved requested output."
        case .python:
            return "Python finished successfully. Features computed and written to target artifact."
        case .shell:
            return "Shell command exited with code 0."
        case .hpcJob:
            return "Job submitted and completed. Exit status 0."
        case .notebook:
            return "Notebook executed without errors and produced rendered output."
        }
    }

    private func toolResultTrace(for step: PlanStep) -> String {
        switch step.runtime {
        case .download:
            return "Downloader initialized request, validated network path, and staged incoming file."
        case .python:
            return "Python tool loaded inputs and executed the requested transformation pipeline."
        case .shell:
            return "Shell tool prepared environment and executed scripted operation."
        case .hpcJob:
            return "HPC client prepared submission payload and tracked completion."
        case .notebook:
            return "Notebook runner executed cells and collected artifacts."
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
