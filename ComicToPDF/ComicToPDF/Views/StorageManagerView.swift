import SwiftUI

struct StorageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var storageInfo: StorageInfo?
    
    var body: some View {
        Form {
            if let info = storageInfo {
                Section {
                    Text(ByteCountFormatter.string(fromByteCount: info.totalSize, countStyle: .file))
                } header: {
                    Text("Overview")
                }
            } else {
                Text("Loading...")
            }
        }
        .onAppear {
            storageInfo = conversionManager.calculateStorageInfo()
        }
    }
}
