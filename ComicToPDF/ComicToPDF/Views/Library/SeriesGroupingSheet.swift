import SwiftUI

/// Presented after a multi-file import when InksyncPro detects that the imported
/// files may belong to a series. The user can confirm, rename, or skip grouping.
struct SeriesGroupingSheet: View {

    /// The imported PDFs awaiting grouping
    let importedPDFs: [ConvertedPDF]

    /// Pre-detected series name (from ComicInfo.xml or filename pattern)
    let suggestedName: String

    /// Called with the chosen series name when the user confirms
    let onConfirm: (String) -> Void

    /// Called when the user skips grouping without changes
    let onSkip: () -> Void

    @State private var seriesName: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header explanation
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color(red: 1, green: 159/255, blue: 10/255).gradient)
                    Text("Group into Series?")
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                    Text("InksyncPro detected \(importedPDFs.count) files that may belong to the same series.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)

                // Series name input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Series Name")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)

                    TextField("e.g. One Piece", text: $seriesName)
                        .font(.body)
                        .padding(14)
                        .background(Color.inkSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                        .foregroundColor(.primary)
                        .tint(Color(red: 1, green: 159/255, blue: 10/255))
                        .padding(.horizontal, 20)
                }

                // Imported files preview grid
                if !importedPDFs.isEmpty {
                    Text("\(importedPDFs.count) files will be grouped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(importedPDFs.prefix(10)) { pdf in
                                VStack(spacing: 4) {
                                    if let data = pdf.coverImageData, let img = UIImage(data: data) {
                                        Image(uiImage: img)
                                            .resizable().scaledToFill()
                                            .frame(width: 64, height: 90)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.inkSurface)
                                            .frame(width: 64, height: 90)
                                            .overlay(Image(systemName: "doc.fill").foregroundColor(.secondary))
                                    }
                                    Text(pdf.name)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                        .frame(width: 64)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            if importedPDFs.count > 10 {
                                VStack {
                                    Text("+\(importedPDFs.count - 10)")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: 64, height: 90)
                                .background(Color.inkSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.top, 4)
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        let name = seriesName.trimmingCharacters(in: .whitespaces)
                        onConfirm(name.isEmpty ? suggestedName : name)
                        dismiss()
                    } label: {
                        Text("Group into Series")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(red: 1, green: 159/255, blue: 10/255))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(seriesName.trimmingCharacters(in: .whitespaces).isEmpty && suggestedName.isEmpty)

                    Button {
                        onSkip()
                        dismiss()
                    } label: {
                        Text("Skip — Import Without Grouping")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onSkip()
                        dismiss()
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // Initialize with suggested name pre-filled
    init(importedPDFs: [ConvertedPDF], suggestedName: String, onConfirm: @escaping (String) -> Void, onSkip: @escaping () -> Void) {
        self.importedPDFs = importedPDFs
        self.suggestedName = suggestedName
        self.onConfirm = onConfirm
        self.onSkip = onSkip
        self._seriesName = State(initialValue: suggestedName)
    }
}
