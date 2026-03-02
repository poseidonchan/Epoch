#if os(iOS)
import EpochCore
import SwiftUI

struct CodexFileChangeCard: View {
    let item: CodexFileChangeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("File changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.status)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            ForEach(item.changes, id: \.path) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.path)
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    Text(change.kind)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !change.diff.isEmpty {
                        Text(change.diff)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(6)
                            .padding(8)
                            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
