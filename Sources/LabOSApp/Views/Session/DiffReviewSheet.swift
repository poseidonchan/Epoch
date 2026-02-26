#if os(iOS)
import UIKit
import SwiftUI

struct DiffReviewSheet: View {
    let diff: String

    @Environment(\.dismiss) private var dismiss
    @State private var showingRaw = false

    var body: some View {
        let files = DiffParser.parse(diff)

        NavigationStack {
            Group {
                if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No diff available")
                            .font(.headline)
                        Text("Try again after the agent produces file changes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if showingRaw || files.isEmpty {
                    rawDiffView
                } else {
                    List {
                        Section("Files") {
                            ForEach(files) { file in
                                NavigationLink {
                                    DiffFileDetailView(file: file)
                                } label: {
                                    DiffFileRow(file: file)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(showingRaw ? "Files" : "Raw") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingRaw.toggle()
                        }
                    }
                }
            }
        }
    }

    private var rawDiffView: some View {
        ScrollView {
            Text(diff)
                .font(.system(.footnote, design: .monospaced))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
    }
}

private struct DiffFileRow: View {
    let file: DiffParser.DiffFile

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.path)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                if file.additions > 0 || file.deletions > 0 {
                    HStack(spacing: 8) {
                        if file.additions > 0 {
                            Text("+\(file.additions)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct DiffFileDetailView: View {
    let file: DiffParser.DiffFile

    @State private var showCopiedToast = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .navigationTitle(file.path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = file.diff
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCopiedToast = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCopiedToast = false
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy diff")
            }
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("Copied")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return .secondary
        }
        if line.hasPrefix("@@") {
            return .secondary
        }
        if line.hasPrefix("+") {
            return .green
        }
        if line.hasPrefix("-") {
            return .red
        }
        return .primary
    }
}

private enum DiffParser {
    struct DiffFile: Identifiable, Hashable {
        var path: String
        var diff: String
        var additions: Int
        var deletions: Int
        var lines: [String]

        var id: String { path }
    }

    static func parse(_ diff: String) -> [DiffFile] {
        let raw = diff.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }

        var files: [DiffFile] = []
        var currentLines: [String] = []
        var currentPath: String? = nil

        func flush() {
            guard !currentLines.isEmpty else { return }
            let path = currentPath ?? derivePath(from: currentLines) ?? "Changes"
            let text = currentLines.joined(separator: "\n")
            let counts = countEdits(in: currentLines)
            files.append(
                DiffFile(
                    path: path,
                    diff: text,
                    additions: counts.additions,
                    deletions: counts.deletions,
                    lines: currentLines
                )
            )
            currentLines.removeAll(keepingCapacity: true)
            currentPath = nil
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = parseDiffGitPath(line)
            }
            currentLines.append(line)
        }
        flush()

        // If there was no diff header at all, avoid returning a single mega-file called
        // "Changes" when we can infer a path from +++/--- headers.
        if files.count == 1, files.first?.path == "Changes", let inferred = derivePath(from: lines) {
            files[0].path = inferred
        }

        return files
    }

    private static func parseDiffGitPath(_ line: String) -> String? {
        // Example: diff --git a/foo/bar.txt b/foo/bar.txt
        let parts = line.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let aRaw = String(parts[2])
        let bRaw = String(parts[3])
        let a = stripGitPrefix(aRaw)
        let b = stripGitPrefix(bRaw)

        if b == "/dev/null" {
            return a
        }
        return b
    }

    private static func stripGitPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    private static func derivePath(from lines: [String]) -> String? {
        // Look for +++ b/foo or --- a/foo headers.
        for line in lines {
            if line.hasPrefix("+++ ") {
                let token = line.replacingOccurrences(of: "+++ ", with: "")
                return stripGitPrefix(token)
            }
            if line.hasPrefix("--- ") {
                let token = line.replacingOccurrences(of: "--- ", with: "")
                let stripped = stripGitPrefix(token)
                if stripped != "/dev/null" {
                    return stripped
                }
            }
        }
        return nil
    }

    private static func countEdits(in lines: [String]) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in lines {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1; continue }
            if line.hasPrefix("-") { deletions += 1; continue }
        }
        return (additions, deletions)
    }
}

#endif
