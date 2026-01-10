import SwiftUI

struct PanelEditorView: View {
    // 1. We attempt to grab the manager. 
    // If this fails, the app crashes BEFORE 'body' is even rendered.
    @EnvironmentObject var conversionManager: ConversionManager
    
    let pdf: ConvertedPDF
    let pageIndex: Int
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("Connection Test")
                .font(.largeTitle)
            
            // 2. We try to read a value from the manager.
            // If the manager is missing, this line causes the crash.
            Text("Status: \(conversionManager.statusMessage ?? "Nil")")
                .padding()
                .background(Color.gray.opacity(0.2))
            
            Button("Close") {
                // Placeholder action
            }
        }
        .padding()
        .background(Color.black)
        .foregroundColor(.white)
    }
}
