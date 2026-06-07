import SwiftUI
import SwiftData

/// Full-screen edit sheet for a single SDAnnotation.
/// Allows the user to write/edit their personal thoughts (noteText)
/// and manage custom tags independently from the auto-NLP or Readwise tags.
struct AnnotationEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// The live SwiftData model — mutations here auto-persist.
    @Bindable var annotation: SDAnnotation

    // Local drafts — committed on Save
    @State private var draftNote: String = ""
    @State private var draftTags: [String] = []
    @State private var tagInput: String = ""
    @State private var isSaving: Bool = false

    // Focus management
    @FocusState private var noteFieldFocused: Bool
    @FocusState private var tagFieldFocused: Bool

    // Derived
    private var highlightColor: Color {
        Color(hex: annotation.colorHex ?? "#FFD60A")
    }

    private var allDisplayTags: [String] {
        // Show user tags + Readwise source tags combined, deduplicated
        var combined = draftTags
        let rwTags = (annotation.readwiseTags ?? []) + (annotation.readwiseDocumentTags ?? [])
        for t in rwTags where !combined.contains(t) { combined.append(t) }
        return combined
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // ── Original Highlight ──────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Highlight", systemImage: "highlighter")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(alignment: .top, spacing: 0) {
                            // Color accent bar matching the highlight color
                            RoundedRectangle(cornerRadius: 2)
                                .fill(highlightColor)
                                .frame(width: 4)
                                .padding(.vertical, 2)

                            Text(annotation.selectedText ?? "No highlight text")
                                .font(.body)
                                .foregroundStyle(.primary)
                                .padding(.leading, 12)
                                .padding(.vertical, 8)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                        )

                        // Book + author metadata
                        HStack(spacing: 6) {
                            Image(systemName: annotation.isReadwiseImport ? "bird.fill" : "book.closed.fill")
                                .font(.caption2)
                                .foregroundStyle(annotation.isReadwiseImport ? .blue : .secondary)
                            if let title = annotation.readwiseBookTitle {
                                Text(title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let author = annotation.readwiseAuthor {
                                Text("· \(author)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 4)
                    }

                    Divider()

                    // ── My Thoughts ─────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Label("My Thoughts", systemImage: "text.bubble.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemGroupedBackground))

                            if draftNote.isEmpty {
                                Text("Write your thoughts, reflections, or connections…")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(14)
                                    .allowsHitTesting(false)
                            }

                            TextEditor(text: $draftNote)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .frame(minHeight: 120)
                                .padding(10)
                                .focused($noteFieldFocused)
                        }
                        .frame(minHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(noteFieldFocused
                                        ? Color.accentColor.opacity(0.6)
                                        : Color(UIColor.separator).opacity(0.4),
                                        lineWidth: 1)
                        )
                    }

                    Divider()

                    // ── Tags ────────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tags", systemImage: "tag.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        // Tag input field
                        HStack(spacing: 8) {
                            Image(systemName: "number")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)

                            TextField("Add a tag…", text: $tagInput)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($tagFieldFocused)
                                .onSubmit { commitTag() }
                                .submitLabel(.done)

                            if !tagInput.isEmpty {
                                Button(action: commitTag) {
                                    Image(systemName: "return")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .background(Color.accentColor)
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(tagFieldFocused
                                        ? Color.accentColor.opacity(0.6)
                                        : Color(UIColor.separator).opacity(0.4),
                                        lineWidth: 1)
                        )

                        // Tag chips — user tags + read-only Readwise tags
                        if !allDisplayTags.isEmpty {
                            FlowTagLayout(tags: allDisplayTags,
                                         userTags: draftTags,
                                         onRemove: { tag in
                                             withAnimation(.spring(response: 0.3)) {
                                                 draftTags.removeAll { $0 == tag }
                                             }
                                         })
                        }

                        // Readwise source tag indicators if present
                        if let rwTags = annotation.readwiseTags, !rwTags.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "bird.fill").font(.caption2).foregroundStyle(.blue.opacity(0.7))
                                Text("Readwise tags are shown in blue and cannot be removed.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Edit Highlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear { loadDrafts() }
        }
    }

    // MARK: - Logic

    private func loadDrafts() {
        draftNote = annotation.noteText ?? ""
        // User tags = tags minus the readwise-sourced ones
        let rwTagSet = Set((annotation.readwiseTags ?? []) + (annotation.readwiseDocumentTags ?? []))
        draftTags = (annotation.tags ?? []).filter { !rwTagSet.contains($0) }
    }

    private func commitTag() {
        let cleaned = tagInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
        guard !cleaned.isEmpty, !draftTags.contains(cleaned) else {
            tagInput = ""
            return
        }
        withAnimation(.spring(response: 0.3)) {
            draftTags.append(cleaned)
        }
        tagInput = ""
    }

    private func save() {
        // Commit any pending tag text first
        commitTag()
        isSaving = true

        // Write back to SwiftData model
        annotation.noteText = draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        annotation.modifiedAt = Date()

        // Merge user tags back with read-only Readwise tags
        let rwTagSet: [String] = (annotation.readwiseTags ?? []) + (annotation.readwiseDocumentTags ?? [])
        var merged = draftTags
        for t in rwTagSet where !merged.contains(t) { merged.append(t) }
        annotation.tags = merged.isEmpty ? nil : merged

        try? modelContext.save()
        isSaving = false
        dismiss()
    }
}

// MARK: - Flow Tag Layout
// Wrapping horizontal chip layout — chips wrap to next line naturally.

private struct FlowTagLayout: View {
    let tags: [String]
    let userTags: Set<String>
    let onRemove: (String) -> Void

    init(tags: [String], userTags: [String], onRemove: @escaping (String) -> Void) {
        self.tags = tags
        self.userTags = Set(userTags)
        self.onRemove = onRemove
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 60, maximum: 200), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(tags, id: \.self) { tag in
                let isUser = userTags.contains(tag)
                let chipColor: Color = isUser ? .orange : .blue
                HStack(spacing: 3) {
                    Text("#\(tag)")
                        .font(.caption)
                        .fontWeight(isUser ? .medium : .regular)
                        .foregroundStyle(chipColor)
                        .lineLimit(1)
                    if isUser {
                        Button { onRemove(tag) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(chipColor.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(chipColor.opacity(0.12))
                .overlay(Capsule().stroke(chipColor.opacity(0.25), lineWidth: 1))
                .clipShape(Capsule())
            }
        }
    }
}
