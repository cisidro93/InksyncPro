import SwiftUI
import UIKit

// Common Button Style
struct BorderlessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

// ✅ The ShareSheet wrapper (Kept here)
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

// ✅ Helper for View usage
struct DocumentExporter {
    static func shareFile(url: URL) -> ShareSheet {
        return ShareSheet(activityItems: [url])
    }
}
