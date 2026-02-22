#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit

struct InlineComposerView: View {
    enum Style {
        case standard
        case chatGPT
    }

    let placeholder: String
    @Binding var text: String
    @Binding var isPlanModeEnabled: Bool
    @Binding var selectedModelId: String
    @Binding var selectedThinkingLevel: ThinkingLevel?
    @Binding var selectedPermissionLevel: SessionPermissionLevel
    let submitLabel: String
    var style: Style = .standard
    var statusText: String? = nil
    var statusIconSystemName: String = "sparkles"
    var statusAction: (() -> Void)? = nil
    var attachmentAction: (() -> Void)? = nil
    var showsVoiceButton = true
    var modelOptions: [GatewayModelInfo] = []
    var thinkingLevelOptions: [ThinkingLevel] = ThinkingLevel.allCases
    var contextRemainingFraction: Double? = nil
    var contextWindowTokens: Int = 258_000
    let onSubmit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showsPlusMenu = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedText.isEmpty
    }

    private var selectedModelLabel: String {
        if let model = modelOptions.first(where: { $0.id == selectedModelId }) ?? modelOptions.first {
            return model.name
        }
        return selectedModelId.isEmpty ? "Model" : selectedModelId
    }

    private var selectedThinkingLabel: String {
        let reasoning = modelOptions.first(where: { $0.id == selectedModelId })?.reasoning ?? false
        guard reasoning else { return "Standard" }

        let level = selectedThinkingLevel ?? thinkingLevelOptions.first ?? .medium
        return thinkingLabel(level)
    }

    private var remainingContext: Double {
        if let contextRemainingFraction {
            return min(max(contextRemainingFraction, 0), 1)
        }
        let estimate = 1 - (Double(text.count) / 6000)
        return min(max(estimate, 0.04), 1)
    }

    private var isFullAccessPermission: Bool {
        selectedPermissionLevel == .full
    }

    private var permissionDisplayTitle: String {
        permissionTitle(selectedPermissionLevel)
    }

    private var permissionTint: Color {
        isFullAccessPermission ? .orange : .secondary
    }

    var body: some View {
        switch style {
        case .standard:
            standardComposer
        case .chatGPT:
            chatComposer
        }
    }

    private var standardComposer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                if let attachmentAction {
                    Button(action: attachmentAction) {
                        Image(systemName: "paperclip")
                            .font(.body)
                    }
                }

                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)

                Button(submitLabel) {
                    onSubmit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
    }

    private var chatComposer: some View {
        let hasStatusRow = statusText != nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                plusMenuButton

                VStack(alignment: .leading, spacing: 10) {
                    if let statusText {
                        statusChip(text: statusText, iconSystemName: statusIconSystemName)
                    }

                    HStack(spacing: 10) {
                        modelMenu
                        thinkingMenu

                        if isPlanModeEnabled {
                            Divider()
                                .frame(height: 18)

                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isPlanModeEnabled = false
                                }
                            } label: {
                                Label("Plan", systemImage: "list.bullet.clipboard")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, hasStatusRow ? 0 : 2)

                    HStack(alignment: .bottom, spacing: 8) {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .lineLimit(1...5)
                            .font(.body)
                            .textInputAutocapitalization(.sentences)

                        if showsVoiceButton {
                            Button {} label: {
                                Image(systemName: "mic")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        Circle()
                                            .fill(Color(.tertiarySystemFill))
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Voice input")
                        }

                        Button {
                            guard canSubmit else { return }
                            onSubmit()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(canSubmit ? Color.black : Color(.tertiaryLabel))
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle()
                                        .fill(canSubmit ? Color.white : Color(.tertiarySystemFill))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .accessibilityLabel(submitLabel)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, hasStatusRow ? 8 : 10)
                .padding(.bottom, 10)
                .frame(
                    maxWidth: .infinity,
                    minHeight: hasStatusRow ? 114 : 86,
                    alignment: .topLeading
                )
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(chatComposerBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
            }

            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 0)
                permissionMenu
                ContextRingView(progress: remainingContext, totalContextTokens: contextWindowTokens)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
            .padding(.bottom, 10)
            .background(
                Color(.systemBackground)
                    .opacity(colorScheme == .dark ? 0.98 : 0.92)
                    .ignoresSafeArea(edges: .bottom)
            )
    }

    private var chatComposerBackground: Color {
        return Color(.secondarySystemBackground)
    }

    private var plusMenuButton: some View {
        Button {
            showsPlusMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .background(
                    Circle()
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsPlusMenu, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            plusMenuContent
        }
    }

    private var plusMenuContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let attachmentAction {
                Button {
                    showsPlusMenu = false
                    attachmentAction()
                } label: {
                    Label("Add photos & files", systemImage: "paperclip")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

            Toggle(isOn: $isPlanModeEnabled) {
                Label("Plan mode", systemImage: "list.bullet.clipboard")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(modelOptions, id: \.id) { model in
                Button {
                    selectedModelId = model.id
                } label: {
                    HStack {
                        Text(model.name)
                        if model.id == selectedModelId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            menuChipLabel(selectedModelLabel)
        }
        .buttonStyle(.plain)
    }

    private var thinkingMenu: some View {
        let reasoning = modelOptions.first(where: { $0.id == selectedModelId })?.reasoning ?? false
        return Menu {
            ForEach(thinkingLevelOptions, id: \.self) { level in
                Button {
                    selectedThinkingLevel = level
                } label: {
                    HStack {
                        Text(thinkingLabel(level))
                        if level == selectedThinkingLevel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            menuChipLabel(selectedThinkingLabel)
        }
        .buttonStyle(.plain)
        .disabled(!reasoning)
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(SessionPermissionLevel.allCases, id: \.self) { permission in
                let fullAccess = permission == .full
                Button {
                    selectedPermissionLevel = permission
                } label: {
                    HStack {
                        permissionGlyph(isFullAccess: fullAccess, size: 15)
                        Text(permissionTitle(permission))
                        if permission == selectedPermissionLevel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                permissionGlyph(isFullAccess: isFullAccessPermission, size: 14)
                Text(permissionDisplayTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(permissionTint)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func permissionGlyph(isFullAccess: Bool, size: CGFloat) -> some View {
        if isFullAccess {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: size, weight: .semibold))
        } else {
            Image(uiImage: DefaultPermissionIcon.image(pointSize: size, colorScheme: colorScheme))
                .renderingMode(.original)
        }
    }

    private enum DefaultPermissionIcon {
        nonisolated(unsafe) private static var cache: [String: UIImage] = [:]

        static func image(pointSize: CGFloat, colorScheme: ColorScheme) -> UIImage {
            let key = "\(Int(round(pointSize * 10)))-\(colorScheme == .dark ? "dark" : "light")"
            if let cached = cache[key] { return cached }

            let side = max(18, pointSize + 7)
            let size = CGSize(width: side, height: side)
            let renderer = UIGraphicsImageRenderer(size: size)
            let strokeColor = colorScheme == .dark
                ? UIColor.white.withAlphaComponent(0.94)
                : UIColor.black.withAlphaComponent(0.94)
            let glyphColor = colorScheme == .dark
                ? UIColor.white
                : UIColor.black

            let image = renderer.image { ctx in
                ctx.cgContext.setShouldAntialias(true)
                ctx.cgContext.setAllowsAntialiasing(true)

                let config = UIImage.SymbolConfiguration(pointSize: pointSize + 1, weight: .semibold)
                if let outline = UIImage(systemName: "shield", withConfiguration: config)?
                    .withTintColor(strokeColor, renderingMode: .alwaysOriginal) {
                    let symbolRect = CGRect(
                        x: (size.width - outline.size.width) / 2,
                        y: (size.height - outline.size.height) / 2,
                        width: outline.size.width,
                        height: outline.size.height
                    )
                    let inner = symbolRect.insetBy(dx: symbolRect.width * 0.30, dy: symbolRect.height * 0.36)
                    let lineWidth = max(1.35, pointSize * 0.11)
                    let leftX = inner.minX + inner.width * 0.04
                    let midX = inner.minX + inner.width * 0.60
                    let topY = inner.minY + inner.height * 0.10
                    let midY = inner.midY
                    let bottomY = inner.maxY - inner.height * 0.10
                    let curveInX = inner.minX + inner.width * 0.46

                    let promptPath = UIBezierPath()
                    promptPath.move(to: CGPoint(x: leftX, y: topY))
                    promptPath.addQuadCurve(
                        to: CGPoint(x: midX, y: midY),
                        controlPoint: CGPoint(x: curveInX, y: inner.minY + inner.height * 0.20)
                    )
                    promptPath.addQuadCurve(
                        to: CGPoint(x: leftX, y: bottomY),
                        controlPoint: CGPoint(x: curveInX, y: inner.maxY - inner.height * 0.20)
                    )
                    let underscoreStartX = midX + inner.width * 0.01
                    let underscoreEndX = inner.maxX - inner.width * 0.01
                    let underscoreY = inner.midY + inner.height * 0.24
                    promptPath.move(to: CGPoint(x: underscoreStartX, y: underscoreY))
                    promptPath.addLine(to: CGPoint(x: underscoreEndX, y: underscoreY))

                    ctx.cgContext.saveGState()
                    ctx.cgContext.clip(to: symbolRect.insetBy(dx: symbolRect.width * 0.10, dy: symbolRect.height * 0.19))
                    ctx.cgContext.setStrokeColor(glyphColor.cgColor)
                    ctx.cgContext.setLineWidth(lineWidth)
                    ctx.cgContext.setLineCap(.round)
                    ctx.cgContext.setLineJoin(.round)
                    ctx.cgContext.addPath(promptPath.cgPath)
                    ctx.cgContext.strokePath()
                    ctx.cgContext.restoreGState()

                    outline.draw(in: symbolRect)
                }
            }
            .withRenderingMode(.alwaysOriginal)

            cache[key] = image
            return image
        }
    }

    private func menuChipLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func statusChip(text: String, iconSystemName: String) -> some View {
        if let statusAction {
            Button(action: statusAction) {
                chipLabel(text: text, iconSystemName: iconSystemName)
            }
            .buttonStyle(.plain)
        } else {
            chipLabel(text: text, iconSystemName: iconSystemName)
        }
    }

    private func chipLabel(text: String, iconSystemName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconSystemName)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.blue)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.75 : 0.06))
        )
    }

    private func thinkingLabel(_ level: ThinkingLevel) -> String {
        switch level {
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "Extra High"
        }
    }

    private func permissionTitle(_ level: SessionPermissionLevel) -> String {
        switch level {
        case .default:
            return "Default Permission"
        case .full:
            return "Full Access"
        }
    }
}

	private struct ContextRingView: View {
	    let progress: Double
	    let totalContextTokens: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsTooltip = false
    @State private var hideTooltipTask: DispatchWorkItem?

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var usedPercent: Int {
        Int(round((1 - clampedProgress) * 100))
    }

    private var remainingPercent: Int {
        Int(round(clampedProgress * 100))
    }

	    private var usedTokens: Int {
	        Int(round(Double(totalContextTokens) * (1 - clampedProgress)))
	    }
	
	    private var remainingTokens: Int {
	        max(0, totalContextTokens - usedTokens)
	    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 3)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    Color.blue,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .contentShape(Circle())
        .onHover { isHovering in
            hideTooltipTask?.cancel()
            withAnimation(.easeInOut(duration: 0.14)) {
                showsTooltip = isHovering
            }
        }
        .onTapGesture {
            showTooltipTemporarily()
        }
        .popover(isPresented: $showsTooltip, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            tooltipView
                .presentationCompactAdaptation(.popover)
        }
	        .frame(width: 22, height: 22)
	        .help(
	            "Context window: \(remainingTokens.formatted()) tokens left (\(remainingPercent)%). \(usedTokens.formatted()) / \(totalContextTokens.formatted()) used"
	        )
	        .accessibilityElement(children: .ignore)
	        .accessibilityLabel("Remaining context")
	        .accessibilityValue("\(remainingPercent) percent remaining, \(remainingTokens.formatted()) tokens left")
	        .onDisappear {
	            hideTooltipTask?.cancel()
	        }
	    }

	    private var tooltipView: some View {
	        VStack(alignment: .leading, spacing: 4) {
	            Text("Context window:")
	                .font(.caption.weight(.medium))
	                .foregroundStyle(.secondary)

            Text("\(usedPercent)% used (\(remainingPercent)% left)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

	            Text("\(usedTokens.formatted()) / \(totalContextTokens.formatted()) tokens used")
	                .font(.caption2.weight(.medium))
	                .foregroundStyle(.secondary)
	
	            Text("\(remainingTokens.formatted()) tokens left")
	                .font(.caption2.weight(.semibold))
	                .foregroundStyle(.secondary)
	        }
	        .padding(.horizontal, 10)
	        .padding(.vertical, 8)
        .frame(maxWidth: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 8, y: 4)
    }

    private func showTooltipTemporarily() {
        hideTooltipTask?.cancel()
        withAnimation(.easeInOut(duration: 0.14)) {
            showsTooltip = true
        }

        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.14)) {
                showsTooltip = false
            }
        }
        hideTooltipTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: task)
    }
}

struct ProjectFilesSheet: View {
    let title: String
    let uploadedFiles: [Artifact]
    let onAddPhotos: () -> Void
    let onAddFiles: () -> Void
    var onDeleteFile: ((String) -> Void)? = nil
    let onClose: () -> Void

    private var sortedFiles: [Artifact] {
        uploadedFiles.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var hasFiles: Bool {
        !sortedFiles.isEmpty
    }

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 46, height: 5)
                .padding(.top, 8)

            HStack(spacing: 10) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.secondarySystemFill)))
                }
                .buttonStyle(.plain)
            }

            if hasFiles {
                fileList
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.secondary)

                    Text("No project files yet. Add files so every session in this project can use them.")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
                .padding(.top, 8)
            }

            VStack(spacing: 10) {
                actionButton(
                    title: "Add Photos",
                    systemImage: "photo",
                    action: onAddPhotos
                )

                actionButton(
                    title: "Add Files",
                    systemImage: "paperclip",
                    action: onAddFiles
                )
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents(hasFiles ? [.fraction(0.62)] : [.fraction(0.46)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.ultraThinMaterial)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current files")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(sortedFiles) { file in
                        fileRow(file)
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(sortedFiles.count) * 80, 260))
        }
    }

    private func fileRow(_ file: Artifact) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fileIconTint(for: file.path).opacity(0.18))
                    .frame(width: 44, height: 44)

                Image(systemName: fileIcon(for: file.path))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(fileIconTint(for: file.path))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Text(fileTypeLabel(for: file.path))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let onDeleteFile {
                Button(role: .destructive) {
                    onDeleteFile(file.path)
                } label: {
                    Image(systemName: "trash")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete file")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func fileTypeLabel(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }

    private func fileIcon(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "pdf":
            return "doc.text"
        case "png", "jpg", "jpeg", "heic":
            return "photo"
        case "csv", "tsv":
            return "tablecells"
        case "md", "txt":
            return "text.alignleft"
        case "json":
            return "curlybraces"
        case "py":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }

    private func fileIconTint(for path: String) -> Color {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "pdf":
            return .red
        case "png", "jpg", "jpeg", "heic":
            return .green
        case "csv", "tsv":
            return .orange
        default:
            return .secondary
        }
    }
}

struct ComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
