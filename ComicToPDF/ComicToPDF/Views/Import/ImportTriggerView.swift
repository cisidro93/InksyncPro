import SwiftUI
import UniformTypeIdentifiers

struct ImportTriggerView: View {
    @EnvironmentObject var manager: ConversionManager
    @State private var isPresenting = false
    @State private var importedURL: URL? = nil
    @State private var showImportSheet = false

    var body: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.inkBlue)
                Text("Import a comic, book, or document")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.inkTextPrimary)
                Text("CBZ, CBR, EPUB, PDF and more")
                    .font(.system(size: 13))
                    .foregroundColor(.inkTextSecondary)

                Button("Choose File") { isPresenting = true }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.inkBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .dropDestination(for: URL.self) { items, _ in
            guard let first = items.first else { return false }
            let accessing = first.startAccessingSecurityScopedResource()
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(first.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: first, to: dest)
            if accessing { first.stopAccessingSecurityScopedResource() }
            importedURL = dest
            showImportSheet = true
            return true
        }
        .fileImporter(
            isPresented: $isPresenting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                // Copy to temp for analysis
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: url, to: dest)
                if accessing { url.stopAccessingSecurityScopedResource() }
                importedURL = dest
                showImportSheet = true
            }
        }
        .sheet(isPresented: $showImportSheet) {
            if let url = importedURL {
                SmartImportSheet(sourceURL: url)
                    .environmentObject(manager)
            }
        }
    }
}
