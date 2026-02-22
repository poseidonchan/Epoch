#if os(iOS)
import SwiftUI

struct NamePromptSheet: View {
    let title: String
    let subtitle: String?
    let placeholder: String
    let confirmLabel: String
    let isDestructive: Bool
    let initialValue: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String = ""

    init(
        title: String,
        subtitle: String? = nil,
        placeholder: String,
        confirmLabel: String,
        isDestructive: Bool = false,
        initialValue: String = "",
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.placeholder = placeholder
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
        self.initialValue = initialValue
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let subtitle {
                    Section {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField(placeholder, text: $value)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel, role: isDestructive ? .destructive : nil) {
                        onConfirm(value)
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.fraction(0.34), .medium])
    }
}
#endif
