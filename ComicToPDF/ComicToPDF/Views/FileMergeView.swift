import SwiftUI

struct FileMergeView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var isMerging = false
    
    var body: some View {
        VStack {
            Text("Merge Logic Placeholder")
            Button("Merge Test") {
                // ✅ Fix: Match the signature (url, pageCount, fileSize, duration)
                let dummyURL = URL(fileURLWithPath: "/")
                conversionManager.addConvertedPDF(url: dummyURL, pageCount: 10, fileSize: 1024, duration: 0)
            }
        }
    }
}
