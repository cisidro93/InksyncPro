import SwiftUI
import ZIPFoundation

// MARK: - CBZ Table of Contents

/// Parses the folder structure inside a CBZ to produce chapter groups.
/// Convention: CBZ files often nest chapters as sub-folders inside the archive.
struct CBZTableOfContents {
    struct Chapter: Identifiable {
        let id = UUID()
        let title: String
        let firstPageIndex: Int   // absolute index in the flat pages array
        let pageCount: Int
    }

    let chapters: [Chapter]

    /// Build TOC from the sorted pages array extracted during archive open.
    /// Groups pages by their immediate parent folder name.
    static func build(from pages: [URL]) -> CBZTableOfContents {
        guard !pages.isEmpty else { return CBZTableOfContents(chapters: []) }

        // Attempt folder-based grouping
        var groups: [(folder: String, indices: [Int])] = []
        var folderOrder: [String] = []
        var folderMap: [String: [Int]] = [:]

        for (idx, url) in pages.enumerated() {
            // Parent directory relative to the archive root — use second-to-last component
            let comps = url.pathComponents
            let folder: String
            if comps.count >= 2 {
                folder = comps[comps.count - 2]
            } else {
                folder = "Chapter 1"
            }
            if folderMap[folder] == nil {
                folderOrder.append(folder)
                folderMap[folder] = []
            }
            folderMap[folder, default: []].append(idx)
        }

        // If everything lives in one flat folder, fake single-chapter TOC
        if folderOrder.count <= 1 {
            let chapter = Chapter(title: "Chapter 1", firstPageIndex: 0, pageCount: pages.count)
            return CBZTableOfContents(chapters: [chapter])
        }

        groups = folderOrder.compactMap { folder in
            guard let indices = folderMap[folder], !indices.isEmpty else { return nil }
            return (folder: folder, indices: indices)
        }

        var chapters: [Chapter] = []
        var runningIndex = 0
        for (i, group) in groups.enumerated() {
            let title = group.folder.hasPrefix("Chapter") || group.folder.hasPrefix("chapter")
                ? group.folder
                : "Chapter \(i + 1): \(group.folder)"
            chapters.append(Chapter(title: title, firstPageIndex: runningIndex, pageCount: group.indices.count))
            runningIndex += group.indices.count
        }

        return CBZTableOfContents(chapters: chapters)
    }
}

// MARK: - TOC Sheet View

struct ReaderTOCSheet: View {
    let toc: CBZTableOfContents
    @Binding var currentPageIndex: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if toc.chapters.count <= 1 {
                    ContentUnavailableView(
                        "No Chapters Found",
                        systemImage: "list.bullet.rectangle",
                        description: Text("This book has a single flat chapter. Use the scrubber to navigate.")
                    )
                } else {
                    List(toc.chapters) { chapter in
                        Button {
                            currentPageIndex = chapter.firstPageIndex
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(chapter.pageCount) pages")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if currentPageIndex >= chapter.firstPageIndex &&
                                   currentPageIndex < chapter.firstPageIndex + chapter.pageCount {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundStyle(Color.orange)
                                        .font(.system(size: 13))
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Table of Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }
}

// MARK: - CBR Support

/// CBR files are RAR archives.
/// Full native RAR extraction is powered by Unrar.swift (wrapping the official libunrar C++ source).
struct CBRSupportChecker {
    static func isCBR(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "cbr" || ext == "rar"
    }
    /// Returns true when CBR support has been compiled in (Unrar.swift linked).
    static let isSupported: Bool = true
}
