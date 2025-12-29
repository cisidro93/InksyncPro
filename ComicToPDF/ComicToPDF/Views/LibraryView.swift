import SwiftUI

struct LibraryView: View {
    @State private var files: [URL] = []
    
    var body: some View {
        NavigationView {
            List(files, id: \.self) { file in
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.orange)
                    Text(file.lastPathComponent)
                    Spacer()
                    Button(action: {
                        shareFile(url: file)
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Library")
            .onAppear(perform: loadFiles)
        }
    }
    
    func loadFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "pdf" }
        } catch {
            print("Error loading files: \(error)")
        }
    }
    
    func shareFile(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        // Find existing window scene to present
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true, completion: nil)
        }
    }
}
