import SwiftUI

struct AdvancedWorkspaceView: View {
    let pdf: ConvertedPDF
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.yellow)
                Text("Advanced Workspace is disabled in Go Mode")
                    .font(.headline)
                Text("Use Go Mode for streamlined comic conversions.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Work Area")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
