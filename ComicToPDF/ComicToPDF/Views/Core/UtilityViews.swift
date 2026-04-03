import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook



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
