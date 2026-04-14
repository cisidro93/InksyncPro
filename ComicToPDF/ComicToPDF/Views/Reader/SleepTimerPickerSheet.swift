import SwiftUI

// MARK: - Sleep Timer Picker Sheet

struct SleepTimerPickerSheet: View {
    @ObservedObject private var sleepTimer = SleepTimerManager.shared
    @Environment(\.dismiss) private var dismiss

    private let presets: [(label: String, minutes: Int)] = [
        ("5 minutes",  5),
        ("10 minutes", 10),
        ("15 minutes", 15),
        ("20 minutes", 20),
        ("30 minutes", 30),
        ("45 minutes", 45),
        ("60 minutes", 60),
    ]

    var body: some View {
        NavigationStack {
            List {
                // Active timer section
                if sleepTimer.isActive {
                    Section {
                        HStack {
                            Image(systemName: "moon.zzz.fill")
                                .foregroundStyle(Color.orange)
                                .font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Timer Active")
                                    .font(.system(size: 15, weight: .semibold))
                                Text(sleepTimer.formattedRemaining + " remaining")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cancel Timer") {
                                sleepTimer.stop()
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Current Timer")
                    }
                }

                // Presets
                Section {
                    ForEach(presets, id: \.minutes) { preset in
                        Button {
                            sleepTimer.start(minutes: preset.minutes)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "moon.zzz")
                                    .foregroundStyle(Color.orange)
                                    .frame(width: 28)
                                Text(preset.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if sleepTimer.isActive && sleepTimer.remainingSeconds == preset.minutes * 60 {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.orange)
                                        .font(.system(size: 13, weight: .bold))
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                } header: {
                    Text("Start Sleep Timer")
                } footer: {
                    Text("The reader will close automatically when the timer expires.")
                        .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
