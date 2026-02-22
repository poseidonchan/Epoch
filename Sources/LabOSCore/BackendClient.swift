import Foundation

public struct AssistantResponse: Sendable {
    public var text: String
    public var proposedPlan: ExecutionPlan?
    public var artifactRefs: [ChatArtifactReference]

    public init(text: String, proposedPlan: ExecutionPlan?, artifactRefs: [ChatArtifactReference]) {
        self.text = text
        self.proposedPlan = proposedPlan
        self.artifactRefs = artifactRefs
    }
}

public protocol BackendClient: Sendable {
    func generateAssistantResponse(
        projectID: UUID,
        sessionID: UUID,
        userText: String,
        existingArtifacts: [Artifact]
    ) async -> AssistantResponse

    func fetchArtifactContent(projectID: UUID, path: String) async -> String
}

public struct MockBackendClient: BackendClient {
    public init() {}

    public func generateAssistantResponse(
        projectID: UUID,
        sessionID: UUID,
        userText: String,
        existingArtifacts: [Artifact]
    ) async -> AssistantResponse {
        let normalized = userText.lowercased()
        let shouldPlan = normalized.contains("run")
            || normalized.contains("analyze")
            || normalized.contains("download")
            || normalized.contains("build")
            || normalized.contains("execute")

        guard shouldPlan else {
            let latest = existingArtifacts.sorted { $0.modifiedAt > $1.modifiedAt }.first
            let refs = latest.map {
                [ChatArtifactReference(displayText: $0.path, projectID: projectID, path: $0.path, artifactID: $0.id)]
            } ?? []
            return AssistantResponse(
                text: refs.isEmpty
                    ? "Ready. I can propose a plan when you ask me to run tools or generate files."
                    : "No execution needed yet. Latest artifact is available below.",
                proposedPlan: nil,
                artifactRefs: refs
            )
        }

        var risks: [PlanRiskFlag] = []
        if normalized.contains("download") {
            risks.append(.networkAccess)
            risks.append(.largeDownload)
        }
        if normalized.contains("overwrite") {
            risks.append(.overwriteExisting)
        }

        let plan = ExecutionPlan(
            projectID: projectID,
            sessionID: sessionID,
            steps: [
                PlanStep(
                    title: "Fetch source data",
                    runtime: .download,
                    inputs: ["remote dataset endpoint"],
                    outputs: ["uploads/source.csv"],
                    riskFlags: risks.filter { $0 == .networkAccess || $0 == .largeDownload }
                ),
                PlanStep(
                    title: "Run analysis script",
                    runtime: .python,
                    inputs: ["uploads/source.csv"],
                    outputs: ["artifacts/analysis.py", "notebooks/analysis.ipynb"],
                    riskFlags: []
                ),
                PlanStep(
                    title: "Render summary figure",
                    runtime: .notebook,
                    inputs: ["notebooks/analysis.ipynb"],
                    outputs: ["figures/summary.png", "logs/run.log"],
                    riskFlags: risks.filter { $0 == .overwriteExisting }
                )
            ]
        )

        return AssistantResponse(
            text: "I prepared a plan and need confirmation before executing tools.",
            proposedPlan: plan,
            artifactRefs: []
        )
    }

    public func fetchArtifactContent(projectID: UUID, path: String) async -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        switch ext {
        case "py":
            return "import pandas as pd\n\n# Generated analysis script for project \(projectID.uuidString.prefix(8))\nprint('analysis complete')"
        case "md", "txt", "log":
            return "Artifact preview for \(path)\n\nProject: \(projectID.uuidString)\nStatus: available"
        case "json":
            return "{\n  \"path\": \"\(path)\",\n  \"projectId\": \"\(projectID.uuidString)\"\n}"
        case "ipynb":
            return """
            {
              "cells": [
                {
                  "cell_type": "markdown",
                  "source": [
                    "# Notebook Preview\\n",
                    "This is **markdown** rendered from the notebook preview.\\n"
                  ]
                },
                {
                  "cell_type": "code",
                  "execution_count": 1,
                  "source": [
                    "import math\\n",
                    "print(\\"hello from python\\")\\n",
                    "math.pi\\n"
                  ],
                  "outputs": [
                    {
                      "output_type": "stream",
                      "name": "stdout",
                      "text": ["hello from python\\n"]
                    },
                    {
                      "output_type": "execute_result",
                      "data": {
                        "text/plain": "3.141592653589793",
                        "text/html": "<div style=\\"font-weight:600;\\">pi = 3.141592653589793</div>",
                        "image/png": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5GZfQAAAAASUVORK5CYII="
                      }
                    }
                  ]
                }
              ],
              "metadata": {
                "language_info": { "name": "python" }
              }
            }
            """
        default:
            return "Preview not available for this file type in v0.1."
        }
    }
}
