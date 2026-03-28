import SwiftUI
import UniformTypeIdentifiers

struct SmartListImporterView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var showingFilePicker = false
    @State private var resolvedItems: [ResolvedEventItem]? = nil
    @State private var errorMessage: String? = nil
    @State private var eventName: String = "Imported Event"
    
    // Support .cbl, .csv, .md, .txt
    let allowedTypes: [UTType] = [
        .item, // Unrestricted generic
        .content, // Any content
        .data, // Generic raw data
        .plainText,
        .commaSeparatedText,
        .text,
        UTType(filenameExtension: "cbl") ?? .xml,
        UTType(filenameExtension: "csv") ?? .commaSeparatedText,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "txt") ?? .plainText
    ]
    
    var body: some View {
            Group {
                if let items = resolvedItems {
                    EventResolutionSheet(eventName: eventName, resolvedItems: items)
                } else {
                    NavigationStack {
                        VStack(spacing: 24) {
                            Image(systemName: "list.star")
                                .font(.system(size: 60))
                                .foregroundColor(.purple)
                            
                            Text("Smart Reading Lists")
                                .font(.title).bold()
                            
                            Text("Import a .cbl (Comic Book List) or a basic .CSV text list of issues to automatically generate a properly-sequenced custom reading event from your local library.")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Supported Formats:")
                                    .font(.headline)
                                Label("ComicRack .cbl Files", systemImage: "xmark.curlybrace")
                                Label("Comma Separated Values (.csv)", systemImage: "tablecells")
                                Label("Plain Text Lists (.txt)", systemImage: "doc.plaintext")
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            
                            TextField("Event Name", text: $eventName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .padding(.horizontal, 40)
                            
                            Button {
                                showingFilePicker = true
                            } label: {
                                Label("Select List File", systemImage: "folder.fill")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.purple)
                                    .cornerRadius(12)
                                    .padding(.horizontal, 40)
                            }
                            
                            if let err = errorMessage {
                                Text(err)
                                    .foregroundColor(.red)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                            }
                        }
                    }
                }
            }
        .sheet(isPresented: $showingFilePicker) {
            SmartListFileWrapper { urls in
                handleImport(result: .success(urls))
            }
        }
    }
    
    private func handleImport(result: Result<[URL], Error>) {
        do {
            guard let selectedFile: URL = try result.get().first else { return }
            
            // Set default event name to filename if default wasn't changed
            if eventName == "Imported Event" {
                eventName = selectedFile.deletingPathExtension().lastPathComponent
            }
            
            // Handle security scoping flexibly for local copies
            let isAccessing = selectedFile.startAccessingSecurityScopedResource()
            defer { if isAccessing { selectedFile.stopAccessingSecurityScopedResource() } }
            
            // Removed rigorous readability check here since UIDocumentPicker with 'asCopy: true' gives guaranteed local copies in temp.
            // On iOS, checking `isReadableFile` on newly copied temp documents can erroneously return false due to POSIX attribute delays.
            
            let ext = selectedFile.pathExtension.lowercased()
            let cleanFilename = selectedFile.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            
            var requests: [RequestedComicItem] = []
            
            if ext == "cbl" || ext == "xml" {
                requests = try SmartListImporter.shared.parseCBL(from: selectedFile)
            } else if ext == "csv" {
                requests = try SmartListImporter.shared.parseCSVList(from: selectedFile, defaultSeriesName: cleanFilename)
            } else {
                requests = try SmartListImporter.shared.parseTextList(from: selectedFile, defaultSeriesName: cleanFilename)
            }
            
            if requests.isEmpty {
                errorMessage = "No recognizable comic list entries found in the document."
                return
            }
            
            // Perform resolution against local library
            let resolutions = SmartListImporter.shared.resolveList(requests, against: conversionManager.convertedPDFs)
            
            withAnimation {
                self.resolvedItems = resolutions
            }
            
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Bulletproof Picker Wrapper
struct SmartListFileWrapper: UIViewControllerRepresentable {
    var onPicked: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let textTypes: [UTType] = [
            .item,
            .content,
            .data,
            UTType("public.plain-text") ?? .plainText,
            UTType("public.comma-separated-values-text") ?? .commaSeparatedText
        ]
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: textTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: SmartListFileWrapper
        init(_ parent: SmartListFileWrapper) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPicked(urls)
        }
    }
}
