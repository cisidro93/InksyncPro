import SwiftUI
import UniformTypeIdentifiers

struct SmartListImporterView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var resolvedItems: [ResolvedEventItem]? = nil
    @State private var errorMessage: String? = nil
    @State private var eventName: String = "Imported Event"
    @State private var pastedText: String = ""

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
                                .foregroundColor(Color(.secondaryLabel))
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
                            
                            HStack(spacing: 16) {
                                Button(action: {
                                    ImportCoordinator.present(type: .smartList) { urls in
                                        if let first = urls.first {
                                            handleImport(result: .success([first]))
                                        }
                                    }
                                }) {
                                    Label("Import CSV/CBL File", systemImage: "tablecells")
                                        .font(.headline)
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .frame(maxWidth: .infinity)
                                        .background(Color(.systemBlue).opacity(0.15))
                                        .foregroundColor(Color(.systemBlue))
                                        .cornerRadius(12)
                                }
                                
                                Button(action: {
                                    ImportCoordinator.present(type: .smartList) { urls in
                                        if let first = urls.first {
                                            handleImport(result: .success([first]))
                                        }
                                    }
                                }) {
                                    Label("Import Text File", systemImage: "doc.plaintext")
                                        .font(.headline)
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .frame(maxWidth: .infinity)
                                        .background(Color(.systemGreen).opacity(0.15))
                                        .foregroundColor(Color(.systemGreen))
                                        .cornerRadius(12)
                                }
                            }
                            .padding(.horizontal, 40)
                            
                            TextField("Event Name", text: $eventName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .padding(.horizontal, 40)
                            
                            
                            Text("Or paste your list directly:")
                                .font(.subheadline)
                                .foregroundColor(Color(.secondaryLabel))
                            
                            TextEditor(text: $pastedText)
                                .frame(height: 120)
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                                .padding(.horizontal, 40)
                            
                            if !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button {
                                    handlePastedText()
                                } label: {
                                    Label("Parse Pasted List", systemImage: "doc.text.magnifyingglass")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .padding()
                                        .frame(maxWidth: .infinity)
                                        .background(Color.green)
                                        .cornerRadius(12)
                                        .padding(.horizontal, 40)
                                }
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
    
    private func handlePastedText() {
        let clean = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        
        let safeName = eventName.isEmpty || eventName == "Imported Event" ? "Pasted Event" : eventName
        self.eventName = safeName // make sure UI reflects this
        
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).csv")
            try clean.write(to: tempURL, atomically: true, encoding: .utf8)
            handleImport(result: .success([tempURL]))
        } catch {
            errorMessage = "Failed to process text."
        }
    }
}


