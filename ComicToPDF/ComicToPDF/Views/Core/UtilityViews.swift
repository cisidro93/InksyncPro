import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook

// MARK: - DocumentPicker
struct DocumentPicker: UIViewControllerRepresentable {
    var onDocumentsPicked: ([URL]) -> Void
    var onError: ((String) -> Void)? = nil // Added optional error handler

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let pdf = UTType.pdf
        let zip = UTType.zip
        let epub = UTType(filenameExtension: "epub")
        let cbz = UTType(filenameExtension: "cbz")
        let cbr = UTType(filenameExtension: "cbr")
        
        let types = [pdf, zip, epub, cbz, cbr].compactMap { $0 }
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onDocumentsPicked(urls)
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Optional cancellation handling
        }
    }
}

// MARK: - FolderPicker
struct FolderPicker: UIViewControllerRepresentable {
    var onFolderPicked: (URL) -> Void
    var onError: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.folder, .directory]
        // Hack for iOS 16+: Set allowsMultipleSelection to true so "Open" remains enabled
        // even if the user just wants to select the current directory they're viewing.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        if #available(iOS 16.0, *) {
             picker.allowsMultipleSelection = true
        } else {
             picker.allowsMultipleSelection = false
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FolderPicker

        init(_ parent: FolderPicker) {
            self.parent = parent
        }

        // Modern API
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onFolderPicked(url)
            }
        }
        
        // Fallback for some iOS targets that glitch on the modern array version when `.folder` is used
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
            parent.onFolderPicked(url)
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Optional cancellation handling
        }
    }
}

// MARK: - ShareSheet & DocumentExporter
// Common Button Style
struct BorderlessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DocumentExporter {
    static func shareFile(url: URL) -> ShareSheet {
        return ShareSheet(activityItems: [url])
    }
}

// MARK: - QuickLookView
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: QuickLookView
        
        init(_ parent: QuickLookView) {
            self.parent = parent
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.url as QLPreviewItem
        }
    }
}

// MARK: - TaskMonitorRow
struct TaskMonitorRow: View {
    @ObservedObject var task: AppBackgroundTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title) // ✅ Fix: Use title instead of description
                    .font(.headline)
                Spacer()
                Text("\(Int(task.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: task.progress)
                .progressViewStyle(LinearProgressViewStyle())
        }
        .padding(.vertical, 8)
    }
}
