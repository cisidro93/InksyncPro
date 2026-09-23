import SwiftUI

// MARK: - OPDS Entry Detail Sheet

struct OPDSEntryDetailSheet: View {
    let entry: OPDSEntry
    let server: OPDSServer
    @Environment(\.dismiss) private var dismiss

    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String? = nil
    @State private var didDownload = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Cover artwork
                    if let coverURL = entry.coverURL(relativeTo: server.url) {
                        AsyncImage(url: coverURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 280)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                            case .failure:
                                placeholderCover
                            case .empty:
                                ProgressView()
                                    .frame(height: 200)
                            @unknown default:
                                placeholderCover
                            }
                        }
                        .padding(.top, 16)
                    } else {
                        placeholderCover
                            .padding(.top, 16)
                    }

                    // Metadata
                    VStack(spacing: 8) {
                        Text(entry.title)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.primary)

                        Text(entry.authorString)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)

                        // Available Formats
                        HStack(spacing: 8) {
                            ForEach(entry.acquisitionLinks, id: \.self) { link in
                                Text(link.formatBadge)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)

                    // Download Button
                    if let primaryLink = entry.primaryAcquisitionLink {
                        Button {
                            startDownload(link: primaryLink)
                        } label: {
                            HStack(spacing: 10) {
                                if isDownloading {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Downloading & Opening...")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                } else if didDownload {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Opened in Library")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Download to Library (\(primaryLink.formatBadge))")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(didDownload ? Color.green : Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 3)
                        }
                        .disabled(isDownloading || didDownload)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 20)
                    }

                    // Book Description / Summary
                    if let summary = entry.summary ?? entry.content {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About This Book")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            Text(cleanHTML(summary))
                                .font(.system(size: 14, weight: .regular))
                                .lineSpacing(4)
                                .foregroundColor(.primary.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                    }
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Book Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var placeholderCover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 140, height: 200)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.6))
        }
    }

    private func startDownload(link: OPDSLink) {
        guard !isDownloading else { return }
        isDownloading = true
        errorMessage = nil

        Task {
            do {
                _ = try await OPDSNetworkClient.shared.downloadPublication(
                    entry: entry,
                    link: link,
                    server: server
                )
                await MainActor.run {
                    self.isDownloading = false
                    self.didDownload = true
                    // Give user brief visual confirmation, then dismiss sheet
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cleanHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else {
            // Strip tags with regex fallback
            return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
