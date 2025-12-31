import SwiftUI

struct StorageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var storageInfo: StorageInfo?
    
    var body: some View {
        List {
            if let info = storageInfo {
                Section(header: Text("Overview")) {
                    HStack {
                        Text("Total Space Used")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: info.totalSize, countStyle: .file))
                            .bold()
                            .foregroundColor(.blue)
                    }
                    HStack {
                        Text("Total Files")
                        Spacer()
                        Text("\(info.pdfCount)")
                    }
                }
                
                Section(header: Text("Largest Files")) {
                    if let largest = info.largestFile {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(largest.name).lineLimit(1)
                                Text("Largest File").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(largest.formattedSize)
                        }
                    }
                }
                
                Section(header: Text("Usage by Collection")) {
                    ForEach(info.byCollection, id: \.collection?.id) { item in
                        HStack {
                            Text(item.collection?.name ?? "Uncategorized")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Storage Manager")
        .task {
            storageInfo = conversionManager.calculateStorageInfo()
        }
        .refreshable {
            storageInfo = conversionManager.calculateStorageInfo()
        }
    }
}
