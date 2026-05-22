import SwiftUI

// MARK: - Library Pill Customize Sheet
//
// Presented when the user long-presses Row B of LibraryHeaderView.
// Lets them show/hide each action pill independently.
// Changes take effect immediately via LibraryPillConfig.shared.

struct LibraryPillCustomizeSheet: View {

    @ObservedObject private var pillConfig = LibraryPillConfig.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(LibraryPillConfig.Key.allCases, id: \.self) { key in
                        HStack(spacing: 14) {
                            Image(systemName: key.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(pillConfig.isEnabled(key) ? Theme.orange : Theme.textSecondary)
                                .frame(width: 28)

                            Text(key.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.text)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { pillConfig.isEnabled(key) },
                                set: { pillConfig.setEnabled(key, $0) }
                            ))
                            .labelsHidden()
                            .tint(Theme.orange)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { pillConfig.toggle(key) }
                    }
                } header: {
                    Text("Visible Action Pills")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(nil)
                } footer: {
                    Text("Long-press the action bar anytime to return here.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Customize Toolbar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
