#if os(iOS)
import Foundation
import LabOSCore
import SwiftUI

struct CodexTrajectoryLeafView: View {
    let leaf: CodexTrajectoryLeaf
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summaryTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("codex.trajectory.leaf.toggle.\(leaf.id.lowercased())")

            if let subtitle = summarySubtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isExpanded {
                detailView
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("codex.trajectory.leaf.detail.\(leaf.id.lowercased())")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    private var summaryTitle: String {
        switch leaf.item {
        case let .commandExecution(item):
            return item.command.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .mcpToolCall(item):
            return "\(item.server).\(item.tool)"
        case let .fileChange(item):
            return "File changes (\(item.changes.count))"
        case .plan:
            return "Plan"
        case .agentMessage:
            return "Assistant message"
        case let .unknown(item):
            return item.type
        case .userMessage:
            return "User message"
        }
    }

    private var summarySubtitle: String? {
        switch leaf.item {
        case let .commandExecution(item):
            return "\(item.status) · \(item.cwd)"
        case let .mcpToolCall(item):
            return item.status
        case let .fileChange(item):
            return item.status
        case let .plan(item):
            return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .agentMessage(item):
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(96))
        case let .unknown(item):
            return unknownText(item)
        case .userMessage:
            return nil
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch leaf.item {
        case let .commandExecution(item):
            commandDetail(item)
        case let .mcpToolCall(item):
            mcpDetail(item)
        case let .fileChange(item):
            fileChangeDetail(item)
        case let .plan(item):
            Text(item.text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        case let .agentMessage(item):
            StreamingMarkdownView(text: item.text, isStreaming: false)
        case let .unknown(item):
            Text(unknownText(item))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .userMessage:
            Text("User messages are not rendered in trajectory details.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commandDetail(_ item: CodexCommandExecutionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            trajectoryField("command", item.command, monospaced: true)
            trajectoryField("cwd", item.cwd, monospaced: true)
            trajectoryField("status", item.status)
            if let exitCode = item.exitCode {
                trajectoryField("exit code", String(exitCode))
            }
            if let durationMs = item.durationMs {
                trajectoryField("duration", "\(durationMs)ms")
            }

            if let output = item.aggregatedOutput,
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 44, maxHeight: 220)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func mcpDetail(_ item: CodexMCPToolCallItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            trajectoryField("tool", item.tool, monospaced: true)
            trajectoryField("server", item.server, monospaced: true)
            trajectoryField("status", item.status)
            if let durationMs = item.durationMs {
                trajectoryField("duration", "\(durationMs)ms")
            }
            if let argumentsSummary = jsonSummary(item.arguments) {
                trajectoryField("args", argumentsSummary, monospaced: true)
            }
            if let resultSummary = jsonSummary(item.result) {
                trajectoryField("result", resultSummary, monospaced: true)
            }
            if let errorSummary = jsonSummary(item.error) {
                trajectoryField("error", errorSummary, monospaced: true)
            }
        }
    }

    private func fileChangeDetail(_ item: CodexFileChangeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            trajectoryField("status", item.status)

            ForEach(Array(item.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                    trajectoryField("path", change.path, monospaced: true)
                    trajectoryField("kind", change.kind)
                    if !change.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(change.diff)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    private func trajectoryField(_ key: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func jsonSummary(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value),
              var text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        if text.count > 1_800 {
            text = String(text.prefix(1_800)) + "…"
        }
        return text
    }

    private func unknownText(_ unknown: CodexUnknownItem) -> String {
        if let text = jsonString(unknown.rawPayload["text"]),
           !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return text
        }
        if let status = jsonString(unknown.rawPayload["status"]),
           !status.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return status
        }
        if let message = jsonString(unknown.rawPayload["message"]),
           !message.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return message
        }
        return "No details available"
    }

    private func jsonString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(text):
            return text
        case let .number(number):
            return String(number)
        case let .bool(flag):
            return flag ? "true" : "false"
        default:
            return nil
        }
    }
}
#endif
