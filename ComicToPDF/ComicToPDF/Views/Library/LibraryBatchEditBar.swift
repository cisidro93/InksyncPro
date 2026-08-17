import SwiftUI
import SwiftData

/// Floating Multi-Select Batch Action Bar for Library Management
struct LibraryBatchEditBar: View {
    let selectedPDFs: [ConvertedPDF]
    let onClearSelection: () -> Void
    let onActionCompleted: () -> Void

    @EnvironmentObject private var conversionManager: ConversionManager
    @Environment(\.modelContext) private var modelContext

    @State private var showingPARAPicker = false
    @State private var showingTagPicker = false
    @State private var showingDeleteConfirmation = false
    @State private var tagInputText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Selected item count badge
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.orange)
                    Text("\(selectedPDFs.count) Selected")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkTextPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12), in: Capsule())

                Spacer()

                // 🏷️ Bulk Tag Button
                Button {
                    showingTagPicker = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 16))
                        Text("Tag")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.orange)
                    .frame(width: 44, height: 40)
                }

                // 🚀 PARA Category Button
                Button {
                    showingPARAPicker = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "folder.fill.badge.plus")
                            .font(.system(size: 16))
                        Text("PARA")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.blue)
                    .frame(width: 44, height: 40)
                }

                // 🔒 Move to Vault
                Button {
                    moveToVault()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16))
                        Text("Vault")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.purple)
                    .frame(width: 44, height: 40)
                }

                // 🗑️ Bulk Delete
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16))
                        Text("Delete")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.red)
                    .frame(width: 44, height: 40)
                }

                // ✖️ Cancel Selection
                Button {
                    onClearSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.inkTextTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .confirmationDialog(
            "Delete \(selectedPDFs.count) Selected Item\(selectedPDFs.count > 1 ? "s" : "")?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Selected Items", role: .destructive) {
                bulkDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingPARAPicker) {
            paraPickerSheet
        }
        .sheet(isPresented: $showingTagPicker) {
            tagPickerSheet
        }
    }

    // MARK: - PARA Category Sheet
    private var paraPickerSheet: some View {
        NavigationView {
            List {
                Section("Assign PARA Category to \(selectedPDFs.count) Selected Books") {
                    ForEach([("Project 🚀", "project"), ("Area 🏡", "area"), ("Resource 📚", "resource"), ("Archive 📦", "archive")], id: \.1) { label, category in
                        Button {
                            assignPARACategory(category)
                        } label: {
                            HStack {
                                Text(label)
                                    .font(.system(size: 16, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PARA Batch Assign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPARAPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Tag Picker Sheet
    private var tagPickerSheet: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Add Tag to \(selectedPDFs.count) Selected Items")
                    .font(.headline)
                    .padding(.top, 16)

                TextField("Enter tag name (e.g. Favorite, Sci-Fi)", text: $tagInputText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20)

                Button {
                    applyBulkTag(tagInputText)
                } label: {
                    Text("Apply Tag")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(tagInputText.isEmpty ? Color.gray : Color.orange, in: Capsule())
                }
                .disabled(tagInputText.isEmpty)
                .padding(.horizontal, 20)

                Spacer()
            }
            .navigationTitle("Bulk Tagging")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingTagPicker = false }
                }
            }
        }
        .presentationDetents([.height(240)])
    }

    // MARK: - Actions
    private func moveToVault() {
        for var pdf in selectedPDFs {
            pdf.isPrivate = true
        }
        conversionManager.objectWillChange.send()
        onActionCompleted()
        onClearSelection()
        HapticEngine.success()
    }

    private func bulkDelete() {
        conversionManager.deletePDFs(selectedPDFs)
        onActionCompleted()
        onClearSelection()
        HapticEngine.success()
    }

    private func assignPARACategory(_ category: String) {
        for var pdf in selectedPDFs {
            pdf.metadata.readingEventLabel = category
        }
        showingPARAPicker = false
        conversionManager.objectWillChange.send()
        onActionCompleted()
        onClearSelection()
        HapticEngine.success()
    }

    private func applyBulkTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for var pdf in selectedPDFs {
            if !pdf.metadata.tags.contains(trimmed) {
                pdf.metadata.tags.append(trimmed)
            }
        }
        showingTagPicker = false
        tagInputText = ""
        conversionManager.objectWillChange.send()
        onActionCompleted()
        onClearSelection()
        HapticEngine.success()
    }
}
