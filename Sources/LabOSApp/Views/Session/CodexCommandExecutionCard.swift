#if os(iOS)
import LabOSCore
import SwiftUI

struct CodexCommandExecutionCard: View {
    let item: CodexCommandExecutionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Command")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.command)
                .font(.system(.body, design: .monospaced))

            Text("cwd: \(item.cwd)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let output = item.aggregatedOutput, !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 56, maxHeight: 180)
                .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                Text(item.status)
                    .font(.caption.bold())
                if let code = item.exitCode {
                    Text("exit \(code)")
                        .font(.caption)
                }
                if let durationMs = item.durationMs {
                    Text("\(durationMs)ms")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
