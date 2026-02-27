import Foundation

public protocol BackendClient: Sendable {
    func fetchArtifactContent(projectID: UUID, path: String) async -> String
}

public struct MockBackendClient: BackendClient {
    public init() {}

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
