#if os(iOS)
import LabOSCore
import Photos
import SwiftUI
import UIKit

struct InlineComposerView: View {
    struct SkillOption: Identifiable, Hashable {
        var name: String
        var displayName: String
        var description: String?
        var scope: String?

        var id: String { name.lowercased() }
    }

    enum Style {
        case standard
        case chatGPT
    }

    enum ChatComposerChrome {
        case standalone
        case embeddedInDock
    }

    enum PrimaryAction: Hashable {
        case send
        case stop
        case update
    }

    enum VoiceState: Equatable {
        case unavailable
        case idle
        case recording
        case cancelArmed
        case transcribing(progress: Double)
    }

    let placeholder: String
    @Binding var text: String
    @Binding var isPlanModeEnabled: Bool
    @Binding var selectedModelId: String
    @Binding var selectedThinkingLevel: ThinkingLevel?
    @Binding var selectedPermissionLevel: SessionPermissionLevel
    let submitLabel: String
    var style: Style = .standard
    var chatComposerChrome: ChatComposerChrome = .standalone
    var primaryAction: PrimaryAction = .send
    var submitDisabled: Bool = false
    var statusText: String? = nil
    var statusIconSystemName: String = "sparkles"
    var statusAction: (() -> Void)? = nil
    var attachmentAction: (() -> Void)? = nil
    var pendingAttachments: [ComposerAttachment] = []
    var onRemoveAttachment: ((UUID) -> Void)? = nil
    var showsVoiceButton = true
    var voiceState: VoiceState = .idle
    var onVoiceUnavailableTap: (() -> Void)? = nil
    var onVoicePressBegan: (() -> Void)? = nil
    var onVoiceCancelArmedChanged: ((Bool) -> Void)? = nil
    var onVoicePressEnded: ((Bool) -> Void)? = nil
    var onCursorUTF16OffsetChanged: ((Int) -> Void)? = nil
    var modelOptions: [GatewayModelInfo] = []
    var thinkingLevelOptions: [ThinkingLevel] = ThinkingLevel.allCases
    var skillOptions: [SkillOption] = []
    var skillsAreLoading = false
    var skillsErrorText: String? = nil
    var onRefreshSkills: (() -> Void)? = nil
    var contextRemainingFraction: Double? = nil
    var contextWindowTokens: Int = 258_000
    var useEstimatedContextFallback = true
    let onSubmit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPlusMenu = false
    @State private var voiceGestureIsTracking = false
    @State private var voiceGestureCancelArmed = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayStatusText: String? {
        guard let statusText else { return nil }
        let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "completed", "failed":
            return nil
        default:
            return trimmed
        }
    }

    private var voiceShowsStatusRow: Bool {
        switch voiceState {
        case .recording, .cancelArmed, .transcribing:
            return true
        case .unavailable, .idle:
            return false
        }
    }

    private var voicePromptText: String? {
        switch voiceState {
        case .recording:
            return "Recording… slide up to cancel"
        case .cancelArmed:
            return "Release to cancel"
        case .transcribing:
            return "Transcribing…"
        case .unavailable, .idle:
            return nil
        }
    }

    private var canSubmit: Bool {
        if primaryAction == .stop { return true }
        return !trimmedText.isEmpty || !pendingAttachments.isEmpty
    }

    private var isSubmitEnabled: Bool {
        canSubmit && !submitDisabled
    }

    private var primaryActionIconSystemName: String {
        switch primaryAction {
        case .send:
            return "arrow.up"
        case .stop:
            return "square.fill"
        case .update:
            return "checkmark"
        }
    }

    private var primaryActionBackgroundFill: Color {
        guard isSubmitEnabled else { return Color(.tertiarySystemFill) }
        switch primaryAction {
        case .stop:
            return .red
        default:
            return .white
        }
    }

    private var primaryActionForeground: Color {
        guard isSubmitEnabled else { return Color(.tertiaryLabel) }
        switch primaryAction {
        case .stop:
            return .white
        default:
            return .black
        }
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
        if useEstimatedContextFallback {
            let estimate = 1 - (Double(text.count) / 6000)
            return min(max(estimate, 0.04), 1)
        }
        return 1
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

    private struct SkillMention: Hashable {
        var option: SkillOption
        var range: Range<String.Index>
    }

    private struct ActiveSkillToken: Hashable {
        var query: String
        var range: Range<String.Index>
    }

    private var skillLookupByName: [String: SkillOption] {
        Dictionary(uniqueKeysWithValues: skillOptions.map { ($0.name.lowercased(), $0) })
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
                .disabled(!canSubmit || submitDisabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
    }

    private var chatComposer: some View {
        let hasStatusRow = displayStatusText != nil || !pendingAttachments.isEmpty || voiceShowsStatusRow

        return Group {
            if chatComposerChrome == .standalone {
                chatComposerBody(hasStatusRow: hasStatusRow)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(
                        Color(.systemBackground)
                            .opacity(colorScheme == .dark ? 0.98 : 0.92)
                            .ignoresSafeArea(.container, edges: .bottom)
                            .allowsHitTesting(false)
                    )
            } else {
                chatComposerBody(hasStatusRow: hasStatusRow)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                showsPlusMenu = false
                finishVoiceGesture(forceCancel: true)
            }
        }
        .onChange(of: text) { oldValue, newValue in
            handleSkillBackspace(oldValue: oldValue, newValue: newValue)
        }
        .onDisappear {
            showsPlusMenu = false
            finishVoiceGesture(forceCancel: true)
        }
    }

    private func chatComposerBody(hasStatusRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: chatComposerChrome == .embeddedInDock ? 0 : 10) {
            chatComposerSurface(hasStatusRow: hasStatusRow)

            if chatComposerChrome == .embeddedInDock {
                chatComposerDivider
            }

            chatComposerFooter
        }
    }

    private func chatComposerSurface(hasStatusRow: Bool) -> some View {
        Group {
            if chatComposerChrome == .standalone {
                chatComposerSurfaceContent(hasStatusRow: hasStatusRow)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(chatComposerBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
            } else {
                chatComposerSurfaceContent(hasStatusRow: hasStatusRow)
            }
        }
    }

    private func chatComposerSurfaceContent(hasStatusRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !pendingAttachments.isEmpty {
                pendingAttachmentsRow
            }

            if let statusText = displayStatusText {
                statusChip(text: statusText, iconSystemName: statusIconSystemName)
            }

            if let voicePromptText {
                voiceStatusRow(text: voicePromptText)
            }

            if case let .transcribing(progress) = voiceState {
                voiceProgressRow(progress: progress)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    InlineSkillTokenTextEditor(
                        text: $text,
                        skillLookup: skillLookupByName,
                        colorScheme: colorScheme,
                        onSelectionUTF16OffsetChanged: onCursorUTF16OffsetChanged
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if text.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            codexToolbarRow
                .padding(.bottom, hasStatusRow ? 0 : 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, hasStatusRow ? 8 : 10)
        .padding(.bottom, 10)
        .frame(
            maxWidth: .infinity,
            minHeight: hasStatusRow ? 114 : 86,
            alignment: .topLeading
        )
    }

    private var codexToolbarRow: some View {
        HStack(spacing: 12) {
            plusMenuButton
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

            if showsVoiceButton {
                voiceToolbarButton
            }

            submitToolbarButton
        }
        .padding(.top, 2)
    }

    private var voiceToolbarButton: some View {
        Group {
            switch voiceState {
            case .unavailable:
                Button {
                    onVoiceUnavailableTap?()
                } label: {
                    voiceButtonIcon(systemName: "mic.slash.fill")
                }
                .buttonStyle(.plain)
            case .transcribing:
                voiceButtonIcon(systemName: voiceButtonSystemImage)
            case .idle, .recording, .cancelArmed:
                voiceButtonIcon(systemName: voiceButtonSystemImage)
                    .contentShape(Circle())
                    .gesture(voicePressGesture)
            }
        }
        .accessibilityLabel(voiceAccessibilityLabel)
    }

    private var voicePressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard voiceState != .unavailable else { return }
                if case .transcribing = voiceState { return }
                if !voiceGestureIsTracking {
                    voiceGestureIsTracking = true
                    onVoicePressBegan?()
                }
                let cancelArmed = value.translation.height < -44
                if cancelArmed != voiceGestureCancelArmed {
                    voiceGestureCancelArmed = cancelArmed
                    onVoiceCancelArmedChanged?(cancelArmed)
                }
            }
            .onEnded { _ in
                finishVoiceGesture(forceCancel: voiceGestureCancelArmed)
            }
    }

    private var voiceAccessibilityLabel: String {
        switch voiceState {
        case .unavailable:
            return "Voice input unavailable. Open settings."
        case .idle:
            return "Hold to record voice input"
        case .recording:
            return "Recording voice input"
        case .cancelArmed:
            return "Release to cancel recording"
        case .transcribing:
            return "Transcribing voice input"
        }
    }

    private var voiceButtonSystemImage: String {
        switch voiceState {
        case .unavailable:
            return "mic.slash.fill"
        case .idle:
            return "mic"
        case .recording:
            return "waveform.circle.fill"
        case .cancelArmed:
            return "xmark.circle.fill"
        case .transcribing:
            return "waveform"
        }
    }

    private func voiceButtonIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(voiceButtonForeground)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(voiceButtonBackground)
            )
    }

    private var voiceButtonForeground: Color {
        switch voiceState {
        case .unavailable:
            return .secondary
        case .cancelArmed:
            return .white
        case .recording:
            return .white
        case .transcribing:
            return .blue
        case .idle:
            return .secondary
        }
    }

    private var voiceButtonBackground: Color {
        switch voiceState {
        case .unavailable:
            return Color(.tertiarySystemFill)
        case .cancelArmed:
            return .red
        case .recording:
            return .orange
        case .transcribing:
            return Color.blue.opacity(0.16)
        case .idle:
            return Color(.tertiarySystemFill)
        }
    }

    private var submitToolbarButton: some View {
        Button {
            guard isSubmitEnabled else { return }
            onSubmit()
        } label: {
            Image(systemName: primaryActionIconSystemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryActionForeground)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(primaryActionBackgroundFill)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || submitDisabled)
        .accessibilityLabel(submitLabel)
        .accessibilityIdentifier("composer.send")
    }

    private var chatComposerDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(CodexDockTokens.dividerOpacity))
            .frame(height: CodexDockTokens.dividerThickness)
            .padding(.horizontal, CodexDockTokens.dividerHorizontalInset)
    }

    private var chatComposerFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            Spacer(minLength: 0)
            permissionMenu
            if useEstimatedContextFallback || contextRemainingFraction != nil {
                ContextRingView(progress: remainingContext, totalContextTokens: contextWindowTokens)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var imageAttachments: [ComposerAttachment] {
        pendingAttachments.filter { ($0.mimeType ?? "").lowercased().hasPrefix("image/") }
    }

    private var fileAttachments: [ComposerAttachment] {
        pendingAttachments.filter { !($0.mimeType ?? "").lowercased().hasPrefix("image/") }
    }

    private var pendingAttachmentsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !imageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(imageAttachments.enumerated()), id: \.element.id) { index, attachment in
                            composerImageThumbnail(attachment)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("composer.attachment.thumbnail.\(index)")
                        }
                    }
                    .padding(.trailing, 2)
                }
            }

            if !fileAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(fileAttachments.enumerated()), id: \.element.id) { index, attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachmentIconName(for: attachment.mimeType))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Text(attachment.displayName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)

                                if let onRemoveAttachment {
                                    Button {
                                        onRemoveAttachment(attachment.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color(.tertiarySystemFill))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.08))
                            )
                            .accessibilityIdentifier("composer.attachment.filechip.\(index)")
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func composerImageThumbnail(_ attachment: ComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let preview = composerPreviewImage(for: attachment) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                        Image(systemName: "photo")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let onRemoveAttachment {
                Button {
                    onRemoveAttachment(attachment.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
    }

    private func composerPreviewImage(for attachment: ComposerAttachment) -> UIImage? {
        guard let base64 = attachment.inlineDataBase64,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    private func attachmentIconName(for mimeType: String?) -> String {
        let lowered = (mimeType ?? "").lowercased()
        if lowered.hasPrefix("image/") {
            return "photo"
        }
        if lowered.contains("pdf") {
            return "doc.richtext"
        }
        return "doc"
    }

    private var chatComposerBackground: Color {
        return Color(.secondarySystemBackground)
    }

    private var plusMenuButton: some View {
        Button {
            showsPlusMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.plus")
        .popover(isPresented: $showsPlusMenu, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            plusMenuContent
        }
    }

    private var plusMenuContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let attachmentAction {
                Button {
                    showsPlusMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        attachmentAction()
                    }
                } label: {
                    Label("Add photos & files", systemImage: "paperclip")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.plus.attachments")
            }

            Toggle(isOn: Binding(
                get: { isPlanModeEnabled },
                set: { newValue in
                    isPlanModeEnabled = newValue
                    showsPlusMenu = false
                }
            )) {
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
        .accessibilityIdentifier("composer.model.menu")
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
        .accessibilityIdentifier("composer.thinking.menu")
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
        .accessibilityIdentifier("composer.permission.menu")
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
                .font(.subheadline.weight(.semibold))
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

    private func voiceStatusRow(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: voiceState == .cancelArmed ? "xmark.circle.fill" : "mic.fill")
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(voiceState == .cancelArmed ? Color.red : Color.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.75 : 0.06))
        )
    }

    private func voiceProgressRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption.weight(.semibold))
                Text("Transcribing…")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.blue)
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(.blue)
        }
    }

    private func finishVoiceGesture(forceCancel: Bool) {
        guard voiceGestureIsTracking else { return }
        let cancelled = forceCancel || voiceGestureCancelArmed
        onVoicePressEnded?(cancelled)
        voiceGestureIsTracking = false
        voiceGestureCancelArmed = false
        onVoiceCancelArmedChanged?(false)
    }

    private struct InlineSkillTokenTextEditor: UIViewRepresentable {
        @Binding var text: String
        var skillLookup: [String: SkillOption]
        var colorScheme: ColorScheme
        var onSelectionUTF16OffsetChanged: ((Int) -> Void)? = nil

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.delegate = context.coordinator
            textView.backgroundColor = .clear
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.textColor = .label
            textView.adjustsFontForContentSizeCategory = true
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            textView.textContainer.lineBreakMode = .byWordWrapping
            textView.isScrollEnabled = true
            textView.showsHorizontalScrollIndicator = false
            textView.alwaysBounceHorizontal = false
            textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            textView.setContentCompressionResistancePriority(.required, for: .vertical)
            textView.setContentHuggingPriority(.required, for: .vertical)
            textView.autocapitalizationType = .sentences
            textView.accessibilityIdentifier = "composer.input"

            context.coordinator.applyRenderedText(
                to: textView,
                rawText: text,
                lookup: skillLookup,
                colorScheme: colorScheme,
                preserveSelectionFromCurrent: false
            )
            return textView
        }

        func updateUIView(_ uiView: UITextView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.applyRenderedText(
                to: uiView,
                rawText: text,
                lookup: skillLookup,
                colorScheme: colorScheme,
                preserveSelectionFromCurrent: true
            )
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
            guard let width = proposal.width else { return nil }
            return CGSize(width: width, height: visibleHeight(for: uiView))
        }

        private func visibleHeight(for textView: UITextView) -> CGFloat {
            let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
            return ceil(font.lineHeight * 2 + verticalInsets)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: InlineSkillTokenTextEditor
            private var isApplyingProgrammaticChange = false
            private var lastLookupSignature = 0
            private var lastRawText = ""
            private var lastColorScheme: ColorScheme = .light

            init(parent: InlineSkillTokenTextEditor) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                guard !isApplyingProgrammaticChange else { return }
                let raw = Self.rawText(from: textView.attributedText ?? NSAttributedString())
                if parent.text != raw {
                    parent.text = raw
                }
                let rawSelection = Self.rawSelectionRange(
                    fromAttributedSelection: textView.selectedRange,
                    in: textView.attributedText ?? NSAttributedString()
                )
                parent.onSelectionUTF16OffsetChanged?(rawSelection.location)

                applyRenderedText(
                    to: textView,
                    rawText: raw,
                    lookup: parent.skillLookup,
                    colorScheme: parent.colorScheme,
                    preserveSelectionFromCurrent: true
                )
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                guard !isApplyingProgrammaticChange else { return }
                let rawSelection = Self.rawSelectionRange(
                    fromAttributedSelection: textView.selectedRange,
                    in: textView.attributedText ?? NSAttributedString()
                )
                parent.onSelectionUTF16OffsetChanged?(rawSelection.location)
            }

            func applyRenderedText(
                to textView: UITextView,
                rawText: String,
                lookup: [String: SkillOption],
                colorScheme: ColorScheme,
                preserveSelectionFromCurrent: Bool
            ) {
                let lookupSignature = Self.lookupSignature(lookup)
                let needsRerender = rawText != lastRawText
                    || lookupSignature != lastLookupSignature
                    || colorScheme != lastColorScheme

                guard needsRerender else { return }

                let currentAttributed = textView.attributedText ?? NSAttributedString()
                let currentSelection = textView.selectedRange
                let rawSelection = Self.rawSelectionRange(fromAttributedSelection: currentSelection, in: currentAttributed)
                let baseFont = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
                let rendered = Self.renderedAttributedText(
                    rawText: rawText,
                    lookup: lookup,
                    baseFont: baseFont,
                    colorScheme: colorScheme
                )

                isApplyingProgrammaticChange = true
                textView.attributedText = rendered

                if preserveSelectionFromCurrent {
                    textView.selectedRange = Self.attributedSelectionRange(fromRawSelection: rawSelection, in: rendered)
                } else {
                    let end = Self.attributedOffset(fromRawOffset: rawText.utf16.count, in: rendered)
                    textView.selectedRange = NSRange(location: end, length: 0)
                }
                isApplyingProgrammaticChange = false

                let updatedSelection = Self.rawSelectionRange(
                    fromAttributedSelection: textView.selectedRange,
                    in: rendered
                )
                parent.onSelectionUTF16OffsetChanged?(updatedSelection.location)

                lastLookupSignature = lookupSignature
                lastRawText = rawText
                lastColorScheme = colorScheme
            }

            private static func lookupSignature(_ lookup: [String: SkillOption]) -> Int {
                var hasher = Hasher()
                for key in lookup.keys.sorted() {
                    hasher.combine(key)
                    if let option = lookup[key] {
                        hasher.combine(option.name)
                        hasher.combine(option.displayName)
                    }
                }
                return hasher.finalize()
            }

            private static func renderedAttributedText(
                rawText: String,
                lookup: [String: SkillOption],
                baseFont: UIFont,
                colorScheme: ColorScheme
            ) -> NSAttributedString {
                let baseAttributes: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .foregroundColor: UIColor.label,
                ]
                let attributed = NSMutableAttributedString(string: "")
                let mentions = InlineComposerView.parseSkillMentions(in: rawText, lookup: lookup)
                var cursor = rawText.startIndex

                for mention in mentions {
                    if cursor < mention.range.lowerBound {
                        let prefix = String(rawText[cursor..<mention.range.lowerBound])
                        attributed.append(NSAttributedString(string: prefix, attributes: baseAttributes))
                    }

                    let token = "$\(mention.option.name)"
                    let attachment = SkillTokenAttachment(
                        token: token,
                        displayName: mention.option.displayName,
                        baseFont: baseFont,
                        colorScheme: colorScheme
                    )
                    let attachmentString = NSMutableAttributedString(attachment: attachment)
                    attachmentString.addAttributes(baseAttributes, range: NSRange(location: 0, length: attachmentString.length))
                    attributed.append(attachmentString)

                    cursor = mention.range.upperBound
                }

                if cursor < rawText.endIndex {
                    let suffix = String(rawText[cursor..<rawText.endIndex])
                    attributed.append(NSAttributedString(string: suffix, attributes: baseAttributes))
                }

                if attributed.length == 0 {
                    attributed.append(NSAttributedString(string: "", attributes: baseAttributes))
                }

                return attributed
            }

            private static func rawText(from attributed: NSAttributedString) -> String {
                guard attributed.length > 0 else { return "" }
                var output = ""
                attributed.enumerateAttributes(
                    in: NSRange(location: 0, length: attributed.length),
                    options: []
                ) { attributes, range, _ in
                    if let attachment = attributes[.attachment] as? SkillTokenAttachment {
                        output.append(attachment.token)
                    } else {
                        output.append(attributed.attributedSubstring(from: range).string)
                    }
                }
                return output
            }

            private static func rawSelectionRange(
                fromAttributedSelection selection: NSRange,
                in attributed: NSAttributedString
            ) -> NSRange {
                let start = rawOffset(fromAttributedOffset: selection.location, in: attributed)
                let end = rawOffset(fromAttributedOffset: selection.location + selection.length, in: attributed)
                return NSRange(location: start, length: max(0, end - start))
            }

            private static func attributedSelectionRange(
                fromRawSelection rawSelection: NSRange,
                in attributed: NSAttributedString
            ) -> NSRange {
                let start = attributedOffset(fromRawOffset: rawSelection.location, in: attributed)
                let end = attributedOffset(fromRawOffset: rawSelection.location + rawSelection.length, in: attributed)
                return NSRange(location: start, length: max(0, end - start))
            }

            private static func rawOffset(fromAttributedOffset offset: Int, in attributed: NSAttributedString) -> Int {
                guard attributed.length > 0 else { return 0 }
                let clampedOffset = max(0, min(offset, attributed.length))
                var cursor = 0
                var rawOffset = 0

                while cursor < clampedOffset {
                    var range = NSRange(location: 0, length: 0)
                    let attributes = attributed.attributes(at: cursor, effectiveRange: &range)
                    let step = min(range.length, clampedOffset - cursor)
                    if let attachment = attributes[.attachment] as? SkillTokenAttachment {
                        if step > 0 {
                            rawOffset += attachment.token.utf16.count
                        }
                    } else {
                        rawOffset += step
                    }
                    cursor += step
                }

                return rawOffset
            }

            private static func attributedOffset(fromRawOffset rawOffset: Int, in attributed: NSAttributedString) -> Int {
                guard attributed.length > 0 else { return 0 }
                let target = max(0, rawOffset)
                var rawCursor = 0
                var attributedCursor = 0

                while attributedCursor < attributed.length {
                    var range = NSRange(location: 0, length: 0)
                    let attributes = attributed.attributes(at: attributedCursor, effectiveRange: &range)
                    if let attachment = attributes[.attachment] as? SkillTokenAttachment {
                        let tokenLength = attachment.token.utf16.count
                        if target <= rawCursor {
                            return attributedCursor
                        }
                        if target < rawCursor + tokenLength {
                            return attributedCursor + range.length
                        }
                        rawCursor += tokenLength
                        attributedCursor = range.location + range.length
                        continue
                    }

                    let textLength = range.length
                    if target <= rawCursor {
                        return attributedCursor
                    }
                    if target <= rawCursor + textLength {
                        return attributedCursor + (target - rawCursor)
                    }

                    rawCursor += textLength
                    attributedCursor = range.location + range.length
                }

                return attributed.length
            }
        }

        private final class SkillTokenAttachment: NSTextAttachment {
            let token: String

            init(token: String, displayName: String, baseFont: UIFont, colorScheme: ColorScheme) {
                self.token = token
                super.init(data: nil, ofType: nil)

                let badge = Self.badgeImage(displayName: displayName, baseFont: baseFont, colorScheme: colorScheme)
                image = badge
                let verticalOffset = (baseFont.capHeight - badge.size.height) / 2 - 1
                bounds = CGRect(origin: CGPoint(x: 0, y: verticalOffset), size: badge.size)
            }

            required init?(coder: NSCoder) {
                nil
            }

            private static func badgeImage(displayName: String, baseFont: UIFont, colorScheme: ColorScheme) -> UIImage {
                let fontSize = max(13, floor(baseFont.pointSize * 0.82))
                let textFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
                let textAttributes: [NSAttributedString.Key: Any] = [
                    .font: textFont,
                    .foregroundColor: UIColor.systemPurple,
                ]
                let label = displayName
                let textSize = (label as NSString).size(withAttributes: textAttributes)

                let horizontalPadding: CGFloat = 10
                let verticalPadding: CGFloat = 4
                let size = CGSize(
                    width: ceil(textSize.width + horizontalPadding * 2),
                    height: ceil(textSize.height + verticalPadding * 2)
                )

                let fillColor = UIColor.systemPurple.withAlphaComponent(colorScheme == .dark ? 0.28 : 0.14)
                let strokeColor = UIColor.systemPurple.withAlphaComponent(colorScheme == .dark ? 0.42 : 0.30)

                let renderer = UIGraphicsImageRenderer(size: size)
                return renderer.image { context in
                    let rect = CGRect(origin: .zero, size: size)
                    let pillRect = rect.insetBy(dx: 0.5, dy: 0.5)
                    let path = UIBezierPath(
                        roundedRect: pillRect,
                        cornerRadius: floor(pillRect.height / 2)
                    )
                    fillColor.setFill()
                    path.fill()
                    strokeColor.setStroke()
                    path.lineWidth = 1
                    path.stroke()

                    let textRect = CGRect(
                        x: floor((size.width - textSize.width) / 2),
                        y: floor((size.height - textSize.height) / 2),
                        width: ceil(textSize.width),
                        height: ceil(textSize.height)
                    )
                    (label as NSString).draw(in: textRect, withAttributes: textAttributes)

                    context.cgContext.flush()
                }
            }
        }
    }

    private func handleSkillBackspace(oldValue: String, newValue: String) {
        guard oldValue != newValue else { return }
        // Backspace support: when a mention token is at the end, remove it as a unit.
        guard oldValue.hasPrefix(newValue), oldValue.count == newValue.count + 1 else { return }
        guard let mention = Self.trailingSkillToken(in: oldValue) else { return }
        guard mention.range.upperBound == oldValue.endIndex else { return }

        let prefix = String(oldValue[..<mention.range.lowerBound])
        text = prefix
    }

    private static func parseSkillMentions(in rawText: String, lookup: [String: SkillOption]) -> [SkillMention] {
        let coreLookup = lookup.reduce(into: [String: CodexSkillMentionOption]()) { partial, entry in
            partial[entry.key] = CodexSkillMentionOption(
                name: entry.value.name,
                displayName: entry.value.displayName
            )
        }

        return CodexSkillMentionCodec.parseMentions(in: rawText, lookup: coreLookup).compactMap { mention in
            guard let option = lookup[mention.option.name.lowercased()] else { return nil }
            return SkillMention(option: option, range: mention.range)
        }
    }

    private static func trailingSkillToken(in rawText: String) -> ActiveSkillToken? {
        guard let token = CodexSkillMentionCodec.trailingToken(in: rawText) else { return nil }
        return ActiveSkillToken(query: token.query, range: token.range)
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
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                dismissTooltip()
            }
        }
	        .frame(width: 22, height: 22)
	        .help(
	            "Context window: \(remainingTokens.formatted()) tokens left (\(remainingPercent)%). \(usedTokens.formatted()) / \(totalContextTokens.formatted()) used"
	        )
	        .accessibilityElement(children: .ignore)
	        .accessibilityLabel("Remaining context")
	        .accessibilityValue("\(remainingPercent) percent remaining, \(remainingTokens.formatted()) tokens left")
	            .accessibilityIdentifier("composer.context.ring")
	        .onDisappear {
	            dismissTooltip()
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

    private func dismissTooltip() {
        hideTooltipTask?.cancel()
        hideTooltipTask = nil
        if showsTooltip {
            showsTooltip = false
        }
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
                .accessibilityIdentifier("project.files.close")
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
        .accessibilityIdentifier("project.files.sheet")
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

            indexStatusBadge(for: file)

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

    private func indexStatusBadge(for file: Artifact) -> some View {
        let status = file.indexStatus ?? .processing
        let label: String
        let tint: Color

        switch status {
        case .indexed:
            label = "Indexed"
            tint = .green
        case .failed:
            label = "Failed"
            tint = .red
        case .processing:
            label = "Indexing"
            tint = .blue
        }

        return HStack(spacing: 4) {
            if status == .processing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint)
                    .accessibilityIdentifier("project.upload.progress")
            }
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.14))
        )
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.3))
        )
        .accessibilityIdentifier("project.upload.status.\(status.rawValue)")
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

struct ComposerAttachmentsSheet: View {
    let title: String
    let pendingAttachments: [ComposerAttachment]
    let selectedRecentPhotoTokens: Set<String>
    let onTakePhoto: () -> Void
    let onAddPhotos: () -> Void
    let onSelectRecentPhoto: (String) -> Void
    let onAddFiles: () -> Void
    let onAddTestPhoto: (() -> Void)?
    var onDeleteAttachment: ((UUID) -> Void)? = nil
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var recentPhotos: [RecentPhotoThumbnail] = []
    @State private var recentPhotosAuthorized = false
    @State private var recentPhotosAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isLoadingRecentPhotos = false

    private var imageAttachments: [ComposerAttachment] {
        pendingAttachments.filter {
            ($0.mimeType ?? "").lowercased().hasPrefix("image/")
                && ($0.sourceToken?.isEmpty != false)
        }
    }

    private var fileAttachments: [ComposerAttachment] {
        pendingAttachments.filter { !($0.mimeType ?? "").lowercased().hasPrefix("image/") }
    }

    private var hasAttachments: Bool {
        !pendingAttachments.isEmpty
    }

    private var hasRecentPhotos: Bool {
        !recentPhotos.isEmpty
    }

    private var sheetDetentFraction: CGFloat {
        if !fileAttachments.isEmpty {
            return 0.68
        }
        if !imageAttachments.isEmpty || hasRecentPhotos {
            return 0.56
        }
        return 0.52
    }

    private var recentPhotoPlaceholderTitle: String {
        if recentPhotosAuthorizationStatus == .limited {
            return "Photo access limited"
        }
        return recentPhotosAuthorized ? "No recent photos" : "Photo access needed"
    }

    private var recentPhotoPlaceholderSymbol: String {
        if recentPhotosAuthorizationStatus == .limited {
            return "photo.badge.exclamationmark"
        }
        return recentPhotosAuthorized ? "photo.on.rectangle" : "photo.badge.exclamationmark"
    }

    private var canRequestPhotoAccess: Bool {
        !recentPhotosAuthorized || recentPhotosAuthorizationStatus == .limited
    }

    private var canOpenAllPhotosPicker: Bool {
        recentPhotosAuthorizationStatus == .authorized
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 46, height: 5)
                .padding(.top, 8)

            HStack(alignment: .center, spacing: 10) {
                Text(title.isEmpty ? "Session Attachments" : title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("composer.attachments.title")

                Spacer(minLength: 0)

                Button(action: onAddPhotos) {
                    Text("All Photos")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(canOpenAllPhotosPicker ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canOpenAllPhotosPicker)
                .opacity(canOpenAllPhotosPicker ? 1 : 0.55)
                .accessibilityIdentifier("composer.attachments.allPhotos")

                if let onAddTestPhoto {
                    Button(action: onAddTestPhoto) {
                        Text("Use Test Photo")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.teal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composer.attachments.testPhoto")
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.attachments.close")
            }

            mediaRail

            if !fileAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Attached files")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(fileAttachments) { attachment in
                                fileRow(attachment)
                            }
                        }
                    }
                    .frame(maxHeight: min(CGFloat(fileAttachments.count) * 68, 210))
                }
            }

            Divider()

            Button(action: onAddFiles) {
                HStack(spacing: 14) {
                    Image(systemName: "paperclip")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Files")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text("Import documents from Files")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.08),
                                    Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.attachments.addFiles")

            Text("Items added here stay in this session only.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.fraction(sheetDetentFraction)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.ultraThinMaterial)
        .task {
            await loadRecentPhotos()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await loadRecentPhotos() }
        }
    }

    private var mediaRail: some View {
        HStack(spacing: 10) {
            cameraTile

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if hasRecentPhotos {
                        ForEach(Array(recentPhotos.enumerated()), id: \.element.id) { index, photo in
                            recentPhotoTile(photo)
                                .accessibilityIdentifier("composer.attachments.recent.\(index)")
                        }
                    } else {
                        recentPhotoPlaceholderTile
                    }

                    ForEach(imageAttachments) { attachment in
                        imageTile(attachment)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("composer.attachments.recentRail")
        }
    }

    private var cameraTile: some View {
        Button(action: onTakePhoto) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08),
                                Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.04),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 8) {
                    Image(systemName: "camera")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Take Photo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 108, height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.attachments.cameraTile")
    }

    private var recentPhotoPlaceholderTile: some View {
        Group {
            if canRequestPhotoAccess {
                Button(action: requestPhotoAccess) {
                    placeholderTileBody(
                        title: recentPhotoPlaceholderTitle,
                        symbol: recentPhotoPlaceholderSymbol
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.attachments.requestPhotoAccess")
            } else {
                placeholderTileBody(
                    title: recentPhotoPlaceholderTitle,
                    symbol: recentPhotoPlaceholderSymbol
                )
                .accessibilityIdentifier("composer.attachments.recentPlaceholder")
            }
        }
    }

    private func recentPhotoTile(_ photo: RecentPhotoThumbnail) -> some View {
        let isSelected = selectedRecentPhotoTokens.contains(photo.selectionToken)
        return Button {
            onSelectRecentPhoto(photo.selectionToken)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 108, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? Color.blue : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                    )

                Circle()
                    .fill(isSelected ? Color.blue : Color.black.opacity(0.28))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: isSelected ? "checkmark" : "circle")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    )
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Selected photo" : "Unselected photo")
    }

    @ViewBuilder
    private func imageTile(_ attachment: ComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let preview = previewImage(for: attachment) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08))
                        Image(systemName: "photo")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 108, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let onDeleteAttachment {
                Button {
                    onDeleteAttachment(attachment.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    private func fileRow(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: attachment.mimeType))
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let mime = attachment.mimeType, !mime.isEmpty {
                    Text(mime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let onDeleteAttachment {
                Button(role: .destructive) {
                    onDeleteAttachment(attachment.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func previewImage(for attachment: ComposerAttachment) -> UIImage? {
        guard let base64 = attachment.inlineDataBase64,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    private func iconName(for mimeType: String?) -> String {
        let lowered = (mimeType ?? "").lowercased()
        if lowered.hasPrefix("image/") {
            return "photo"
        }
        if lowered.contains("pdf") {
            return "doc.richtext"
        }
        return "doc"
    }

    @MainActor
    private func loadRecentPhotos() async {
        guard !isLoadingRecentPhotos else { return }
        isLoadingRecentPhotos = true
        defer { isLoadingRecentPhotos = false }

        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var requestedAuthorization = false
        if status == .notDetermined {
            requestedAuthorization = true
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        recentPhotosAuthorizationStatus = status
        let authorized = (status == .authorized || status == .limited)
        recentPhotosAuthorized = authorized
        guard authorized else {
            recentPhotos = await cachedRecentPhotoSnapshots()
            return
        }

        var snapshots = await recentPhotoSnapshots()
        if snapshots.isEmpty && requestedAuthorization {
            // Authorization dialogs can resolve before Photos finishes surfacing assets.
            try? await Task.sleep(nanoseconds: 350_000_000)
            snapshots = await recentPhotoSnapshots()
        }

        if snapshots.isEmpty {
            snapshots = await cachedRecentPhotoSnapshots()
        }

        recentPhotos = snapshots
    }

    private func recentPhotoSnapshots(fetchLimit: Int = 18, maxThumbnails: Int = 12) async -> [RecentPhotoThumbnail] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = fetchLimit
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let assets = fetchRecentImageAssets(options: options)
        guard assets.count > 0 else { return [] }

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .fastFormat
        requestOptions.resizeMode = .exact
        requestOptions.isNetworkAccessAllowed = true

        let dataFallbackOptions = PHImageRequestOptions()
        dataFallbackOptions.isSynchronous = true
        dataFallbackOptions.deliveryMode = .highQualityFormat
        dataFallbackOptions.resizeMode = .none
        dataFallbackOptions.isNetworkAccessAllowed = true

        var snapshots: [RecentPhotoThumbnail] = []
        snapshots.reserveCapacity(min(assets.count, maxThumbnails))

        let tileSize = CGSize(width: 216, height: 192)
        let upperBound = min(assets.count, maxThumbnails)
        for idx in 0..<upperBound {
            let asset = assets.object(at: idx)
            var image: UIImage?
            manager.requestImage(
                for: asset,
                targetSize: tileSize,
                contentMode: .aspectFill,
                options: requestOptions
            ) { rendered, _ in
                image = rendered
            }

            if image == nil {
                manager.requestImageDataAndOrientation(for: asset, options: dataFallbackOptions) { data, _, _, _ in
                    guard let data else { return }
                    image = UIImage(data: data)
                }
            }

            guard let image else { continue }
            snapshots.append(
                RecentPhotoThumbnail(
                    id: "asset:\(asset.localIdentifier)",
                    selectionToken: "asset:\(asset.localIdentifier)",
                    thumbnail: image
                )
            )
        }
        return snapshots
    }

    private func fetchRecentImageAssets(options: PHFetchOptions) -> PHFetchResult<PHAsset> {
        let userLibraryCollections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumUserLibrary,
            options: nil
        )
        if let userLibrary = userLibraryCollections.firstObject {
            let inLibrary = PHAsset.fetchAssets(in: userLibrary, options: options)
            if inLibrary.count > 0 {
                return inLibrary
            }
        }
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    private func cachedRecentPhotoSnapshots() async -> [RecentPhotoThumbnail] {
        let cached = await RecentInlinePhotoCache.shared.snapshot(limit: 12)
        return cached.compactMap { cachedPhoto in
            guard let thumbnail = UIImage(data: cachedPhoto.thumbnailData) ?? UIImage(data: cachedPhoto.data) else {
                return nil
            }
            return RecentPhotoThumbnail(
                id: cachedPhoto.token,
                selectionToken: cachedPhoto.token,
                thumbnail: thumbnail
            )
        }
    }

    @ViewBuilder
    private func placeholderTileBody(title: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 108, height: 96)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    @MainActor
    private func presentLimitedLibraryPicker() {
        guard recentPhotosAuthorizationStatus == .limited else { return }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else {
            return
        }
        let presenter = topMostViewController(from: root)
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    @MainActor
    private func requestPhotoAccess() {
        switch recentPhotosAuthorizationStatus {
        case .denied, .restricted, .limited:
            openPhotoPrivacySettings()
        default:
            Task { await loadRecentPhotos() }
        }
    }

    @MainActor
    private func openPhotoPrivacySettings() {
        let deepLink = URL(string: "App-Prefs:root=Privacy&path=PHOTOS")
        let appSettings = URL(string: UIApplication.openSettingsURLString)

        if let deepLink {
            UIApplication.shared.open(deepLink, options: [:]) { success in
                guard !success, let appSettings else { return }
                UIApplication.shared.open(appSettings)
            }
            return
        }

        if let appSettings {
            UIApplication.shared.open(appSettings)
        }
    }

    private func topMostViewController(from root: UIViewController) -> UIViewController {
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}

struct CameraCaptureSheet: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                picker.dismiss(animated: true)
                onCancel()
                return
            }
            picker.dismiss(animated: true)
            onCapture(image)
        }
    }
}

private struct RecentPhotoThumbnail: Identifiable {
    let id: String
    let selectionToken: String
    let thumbnail: UIImage
}

struct CachedInlinePhoto: Sendable {
    let token: String
    let sourceIdentifier: String?
    let data: Data
    let mimeType: String?
    let fileExtension: String?
    let thumbnailData: Data
}

struct CachedInlinePhotoSeed: Sendable {
    let token: String
    let sourceIdentifier: String?
    let data: Data
    let mimeType: String?
    let fileExtension: String?
    let thumbnailData: Data
}

actor RecentInlinePhotoCache {
    static let shared = RecentInlinePhotoCache()

    private var photos: [CachedInlinePhoto] = []
    private let maxItems = 18

    func remember(_ seeds: [CachedInlinePhotoSeed]) {
        guard !seeds.isEmpty else { return }

        for seed in seeds {
            if let existingIndex = photos.firstIndex(where: { $0.token == seed.token })
                ?? (seed.sourceIdentifier.flatMap { source in
                    photos.firstIndex(where: { $0.sourceIdentifier == source })
                }) {
                let existing = photos.remove(at: existingIndex)
                photos.insert(
                    CachedInlinePhoto(
                        token: seed.token.isEmpty ? existing.token : seed.token,
                        sourceIdentifier: seed.sourceIdentifier ?? existing.sourceIdentifier,
                        data: seed.data,
                        mimeType: seed.mimeType,
                        fileExtension: seed.fileExtension,
                        thumbnailData: seed.thumbnailData
                    ),
                    at: 0
                )
                continue
            }

            photos.insert(
                CachedInlinePhoto(
                    token: seed.token.isEmpty ? "inline:\(UUID().uuidString.lowercased())" : seed.token,
                    sourceIdentifier: seed.sourceIdentifier,
                    data: seed.data,
                    mimeType: seed.mimeType,
                    fileExtension: seed.fileExtension,
                    thumbnailData: seed.thumbnailData
                ),
                at: 0
            )
        }

        if photos.count > maxItems {
            photos.removeLast(photos.count - maxItems)
        }
    }

    func snapshot(limit: Int = 12) -> [CachedInlinePhoto] {
        guard !photos.isEmpty else { return [] }
        return Array(photos.prefix(max(1, limit)))
    }

    func payload(for token: String) -> CachedInlinePhoto? {
        photos.first(where: { $0.token == token })
    }
}

struct ComposerSkillSuggestionState: Equatable {
    typealias SkillOption = InlineComposerView.SkillOption

    let activeToken: CodexActiveSkillToken
    let allOptions: [SkillOption]
    let filteredOptions: [SkillOption]
    let isLoading: Bool
    let errorText: String?
    let canRefresh: Bool

    static func make(
        text: String,
        skillOptions: [SkillOption],
        skillsAreLoading: Bool,
        skillsErrorText: String?,
        canRefresh: Bool
    ) -> ComposerSkillSuggestionState? {
        let normalizedText = CodexSkillMentionCodec.sanitizedUserInput(text)
        guard let activeToken = CodexSkillMentionCodec.trailingToken(in: normalizedText) else { return nil }
#if DEBUG
        if ProcessInfo.processInfo.environment["LABOS_DEBUG_SKILL_SUGGESTIONS"] != nil {
            print("[SkillSuggestions] token=\(activeToken.query) text=\"\(normalizedText)\"")
        }
#endif
        let normalizedQuery = activeToken.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sortedOptions = skillOptions.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        let filtered: [SkillOption]
        if normalizedQuery.isEmpty {
            filtered = sortedOptions
        } else {
            filtered = skillOptions
                .filter { option in
                    option.name.lowercased().contains(normalizedQuery)
                        || option.displayName.lowercased().contains(normalizedQuery)
                        || (option.description ?? "").lowercased().contains(normalizedQuery)
                }
                .sorted { lhs, rhs in
                    let lhsPrefix = lhs.name.lowercased().hasPrefix(normalizedQuery)
                        || lhs.displayName.lowercased().hasPrefix(normalizedQuery)
                    let rhsPrefix = rhs.name.lowercased().hasPrefix(normalizedQuery)
                        || rhs.displayName.lowercased().hasPrefix(normalizedQuery)
                    if lhsPrefix != rhsPrefix {
                        return lhsPrefix && !rhsPrefix
                    }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
        }

        return ComposerSkillSuggestionState(
            activeToken: activeToken,
            allOptions: sortedOptions,
            filteredOptions: filtered,
            isLoading: skillsAreLoading,
            errorText: skillsErrorText,
            canRefresh: canRefresh
        )
    }

    var normalizedErrorText: String? {
        guard let errorText else { return nil }
        let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isVisible: Bool {
        if isLoading { return true }
        if normalizedErrorText != nil { return true }
        if !allOptions.isEmpty { return true }
        return canRefresh
    }

    var limitedSuggestions: [SkillOption] {
        Array(filteredOptions.prefix(9))
    }

    var emptyTitle: String {
        allOptions.isEmpty ? "No skills available" : "No matching skills"
    }

    static func replacingTrailingToken(in text: String, with option: SkillOption) -> String? {
        CodexSkillMentionCodec.replacingTrailingToken(in: text, withSkillName: option.name)
    }
}

struct SkillSuggestionShelfView: View {
    typealias SkillOption = InlineComposerView.SkillOption

    let state: ComposerSkillSuggestionState
    var onSelect: (SkillOption) -> Void
    var onRefresh: (() -> Void)? = nil
    var accessibilityPrefix = "composer.skills.shelf"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isLoading && state.limitedSuggestions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading skills…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .accessibilityIdentifier("\(accessibilityPrefix).loading")
            } else if let error = state.normalizedErrorText, state.limitedSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Could not load skills")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let onRefresh {
                        Button("Retry") {
                            onRefresh()
                        }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("\(accessibilityPrefix).retry")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if state.limitedSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.emptyTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let onRefresh, state.allOptions.isEmpty {
                        Button("Refresh skills") {
                            onRefresh()
                        }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("\(accessibilityPrefix).refresh")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .accessibilityIdentifier("\(accessibilityPrefix).empty")
            } else {
                ForEach(Array(state.limitedSuggestions.enumerated()), id: \.element.id) { index, option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "cube.box")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(option.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let scope = option.scope, !scope.isEmpty {
                                        Text(scope)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if let description = option.description,
                                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(accessibilityPrefix).row.\(index)")

                    if index < state.limitedSuggestions.count - 1 {
                        Divider()
                            .overlay(Color.primary.opacity(0.08))
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .accessibilityIdentifier("\(accessibilityPrefix).container")
    }
}

extension CodexSkillsListState {
    func inlineComposerSkillOptions() -> [InlineComposerView.SkillOption] {
        var deduped: [String: InlineComposerView.SkillOption] = [:]
        for entry in entries {
            for skill in entry.skills {
                let key = skill.name.lowercased()
                if deduped[key] == nil {
                    deduped[key] = InlineComposerView.SkillOption(
                        name: skill.name,
                        displayName: skill.interface?.displayName ?? skill.name,
                        description: skill.shortDescription ?? skill.description,
                        scope: skill.scope
                    )
                }
            }
        }

        return deduped.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

#endif
