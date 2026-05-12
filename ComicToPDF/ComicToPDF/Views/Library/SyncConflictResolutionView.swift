import SwiftUI
import Combine

// Sheet presented when CloudSyncCoordinator detects merge conflicts.
// Uses Theme tokens exclusively. .ultraThinMaterial background.

struct SyncConflictResolutionView: View {
    let conflicts: [SyncConflict]
    let onResolve: ([SyncConflictResolution]) -> Void

    @State private var resolutions: [String: SyncConflictResolution] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(conflicts.indices, id: \.self) { i in
                            conflictRow(conflicts[i])
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Sync Conflicts (\(conflicts.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let allResolved = conflicts.compactMap { conflict -> SyncConflictResolution? in
                            let id = conflictID(conflict)
                            return resolutions[id]
                        }
                        onResolve(allResolved)
                        dismiss()
                    }
                    .disabled(resolutions.count < conflicts.count)
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    @ViewBuilder
    private func conflictRow(_ conflict: SyncConflict) -> some View {
        let id = conflictID(conflict)

        switch conflict {
        case .metadataConflict(let fileID, let local, let remote):
            VStack(alignment: .leading, spacing: 12) {
                Text(local.metadata.name)
                    .font(.headline)
                    .foregroundColor(Color.inkTextPrimary)

                Text("Modified on this device and another device simultaneously.")
                    .font(.subheadline)
                    .foregroundColor(Color.inkTextSecondary)

                HStack(spacing: 12) {
                    Button("Keep This Device's Version") {
                        resolutions[id] = .keepLocal(fileID: fileID)
                    }
                    .buttonStyle(ConflictButtonStyle(isSelected: resolutions[id]?.isLocal == true))

                    Button("Keep Other Device's Version") {
                        resolutions[id] = .keepRemote(fileID: fileID)
                    }
                    .buttonStyle(ConflictButtonStyle(isSelected: resolutions[id]?.isLocal == false))
                }
            }
            .padding()
            .background(
                resolutions[id] != nil
                    ? Color.inkSurface
                    : Theme.orange.opacity(0.12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.orange.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

        case .deleteModifyConflict(let fileID, let survivor):
            VStack(alignment: .leading, spacing: 12) {
                Text(survivor.metadata.name)
                    .font(.headline)
                    .foregroundColor(Color.inkTextPrimary)

                Text("Deleted on another device, but modified here.")
                    .font(.subheadline)
                    .foregroundColor(Color.inkTextSecondary)

                HStack(spacing: 12) {
                    Button("Delete It") {
                        resolutions[id] = .applyDeletion(fileID: fileID)
                    }
                    .buttonStyle(ConflictButtonStyle(isSelected: resolutions[id]?.isDeletion == true, isDanger: true))

                    Button("Keep My Version") {
                        resolutions[id] = .keepLocal(fileID: fileID)
                    }
                    .buttonStyle(ConflictButtonStyle(isSelected: resolutions[id]?.isLocal == true))
                }
            }
            .padding()
            .background(
                resolutions[id] != nil
                    ? Color.inkSurface
                    : Theme.orange.opacity(0.12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.orange.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func conflictID(_ conflict: SyncConflict) -> String {
        switch conflict {
        case .metadataConflict(let id, _, _):    return id
        case .deleteModifyConflict(let id, _):   return id
        }
    }
}

// MARK: - Resolution Enum

enum SyncConflictResolution {
    case keepLocal(fileID: String)
    case keepRemote(fileID: String)
    case applyDeletion(fileID: String)

    var isLocal: Bool {
        if case .keepLocal = self { return true }
        return false
    }

    var isDeletion: Bool {
        if case .applyDeletion = self { return true }
        return false
    }
}

// MARK: - Button Style

private struct ConflictButtonStyle: ButtonStyle {
    var isSelected: Bool
    var isDanger: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(isSelected ? Color.inkBackground : Color.inkTextPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? (isDanger ? Color.inkTextSecondary : Theme.orange)
                    : Color.inkSurface
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
