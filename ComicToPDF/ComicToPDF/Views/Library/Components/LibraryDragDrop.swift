import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let libraryDragPayload = UTType(importedAs: "com.inksyncpro.library.dragpayload")
}

// MARK: - Drag Payload

struct LibraryDragPayload: Codable, Transferable {
    let pdfID: UUID                     // cover issue (or primary file)
    let pdfName: String?                // clean file name for smart naming
    let currentSeriesName: String?      // nil = ungrouped standalone file
    /// Non-nil only when dragging an entire series group.
    let seriesGroupTitle: String?
    /// All issue IDs belonging to the dragged series (empty for single-file drags).
    let issueIDs: [UUID]

    /// Convenience init for single-file drags (preserves backward compatibility).
    init(pdfID: UUID, pdfName: String?, currentSeriesName: String?) {
        self.pdfID = pdfID
        self.pdfName = pdfName
        self.currentSeriesName = currentSeriesName
        self.seriesGroupTitle = nil
        self.issueIDs = []
    }

    /// Init for dragging an entire series group.
    init(seriesGroup: SeriesGroup) {
        self.pdfID = seriesGroup.coverIssueID ?? seriesGroup.issues.first?.id ?? UUID()
        self.pdfName = seriesGroup.issues.first?.name
        self.currentSeriesName = seriesGroup.title
        self.seriesGroupTitle = seriesGroup.title
        self.issueIDs = seriesGroup.issues.map(\.id)
    }

    var isSeriesDrag: Bool { seriesGroupTitle != nil }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .libraryDragPayload)
    }
}

// MARK: - Drop Resolution Info

struct DropResolutionInfo: Identifiable {
    let id = UUID()
    let draggedID: UUID
    let draggedSeriesName: String?
    let destinationSeriesName: String
    let isFileDroppingOntoSeries: Bool  // true = file→series or series→series, false = file→file
    /// Non-empty when dragging an entire series (series→series combine).
    let allDraggedIssueIDs: [UUID]

    init(
        draggedID: UUID,
        draggedSeriesName: String?,
        destinationSeriesName: String,
        isFileDroppingOntoSeries: Bool,
        allDraggedIssueIDs: [UUID] = []
    ) {
        self.draggedID = draggedID
        self.draggedSeriesName = draggedSeriesName
        self.destinationSeriesName = destinationSeriesName
        self.isFileDroppingOntoSeries = isFileDroppingOntoSeries
        self.allDraggedIssueIDs = allDraggedIssueIDs
    }
}

// MARK: - Drop Resolution Sheet

struct DropResolutionSheet: View {
    let info: DropResolutionInfo
    let onConfirm: (String) -> Void

    @State private var customName: String = ""
    @State private var useCustomName = false
    @Environment(\.dismiss) private var dismiss

    private var smartDefault: String { info.destinationSeriesName }
    private var hasAlternative: Bool {
        let dName = info.draggedSeriesName ?? ""
        return !dName.isEmpty && dName != info.destinationSeriesName
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Icon + headline
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.inkBlue.opacity(0.15))
                            .frame(width: 80, height: 80)
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.inkBlue.gradient)
                    }
                    .padding(.top, 32)

                    Text(info.allDraggedIssueIDs.isEmpty
                         ? (info.isFileDroppingOntoSeries ? "Add to Series" : "Create / Merge Series")
                         : "Combine Series")
                        .font(.title3.bold())
                        .foregroundColor(.primary)

                    Text(info.allDraggedIssueIDs.isEmpty
                         ? (info.isFileDroppingOntoSeries
                            ? "Which series name should this issue use?"
                            : "These two files will be grouped. Choose a series name.")
                         : "\(info.allDraggedIssueIDs.count) issue\(info.allDraggedIssueIDs.count == 1 ? "" : "s") from \"\(info.draggedSeriesName ?? "source")\" will move into this series. Which name should they use?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 28)

                // Options
                VStack(spacing: 10) {
                    // Smart default: destination name
                    OptionRow(
                        label: "Keep destination series name",
                        value: info.destinationSeriesName,
                        isSelected: !useCustomName,
                        accent: .inkBlue
                    ) {
                        useCustomName = false
                    }

                    // Alternative: dragged item's series name (only shown if different)
                    if hasAlternative, let altName = info.draggedSeriesName {
                        OptionRow(
                            label: "Use dragged item's series name",
                            value: altName,
                            isSelected: false,
                            accent: .inkViolet
                        ) {
                            useCustomName = true
                            customName = altName
                        }
                    }

                    // Custom name input
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "pencil")
                                .foregroundColor(useCustomName ? .inkAmber : .secondary)
                            Text("Use a custom name")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(useCustomName ? .inkAmber : .secondary)
                            Spacer()
                            if useCustomName {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.inkAmber)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { useCustomName = true }

                        if useCustomName {
                            TextField("Series name…", text: $customName)
                                .padding(12)
                                .background(Color.inkSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.inkAmber.opacity(0.5), lineWidth: 1))
                                .autocorrectionDisabled()
                        }
                    }
                    .padding(14)
                    .background(Color.inkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 20)

                Spacer()

                // Confirm button
                Button {
                    let resolved = useCustomName
                        ? customName.trimmingCharacters(in: .whitespacesAndNewlines)
                        : smartDefault
                    guard !resolved.isEmpty else { return }
                    onConfirm(resolved)
                    dismiss()
                } label: {
                    Text("Confirm")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.inkBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .disabled(useCustomName && customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Option Row

private struct OptionRow: View {
    let label: String
    let value: String
    let isSelected: Bool
    let accent: Color
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? accent : .secondary)
                .font(.system(size: 22))
        }
        .padding(14)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Smart Naming Algorithm

func extractSmartGroupName(str1: String, str2: String) -> String {
    let clean1 = str1.trimmingCharacters(in: .whitespacesAndNewlines)
    let clean2 = str2.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Find common prefix
    var common = ""
    let chars1 = Array(clean1)
    let chars2 = Array(clean2)
    let maxLen = min(chars1.count, chars2.count)
    
    for i in 0..<maxLen {
        if chars1[i].lowercased() == chars2[i].lowercased() {
            common.append(chars1[i])
        } else {
            break
        }
    }
    
    // Clean up trailing characters (numbers, dashes, spaces, hashes)
    var result = common
    while let last = result.last, last.isNumber || last.isWhitespace || last == "-" || last == "#" || last == "_" || last == "." || last == "(" || last == ")" {
        result.removeLast()
    }
    
    // If resulting string is too short (e.g. empty or only 1-2 chars), fallback to the target file's title
    if result.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
        return clean2
    }
    
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
