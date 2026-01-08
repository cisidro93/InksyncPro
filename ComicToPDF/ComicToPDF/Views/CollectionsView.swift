import SwiftUI

struct CollectionsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingAddCollection = false
    @State private var newCollectionName = ""
    
    var body: some View {
        NavigationView {
            List {
                if conversionManager.collections.isEmpty {
                    Text("No collections yet. Create one to organize your comics.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(conversionManager.collections) { collection in
                        // ✅ FIX: Calculate count here and pass it down
                        let count = conversionManager.convertedPDFs.filter { $0.collectionId == collection.id }.count
                        CollectionRow(collection: collection, itemCount: count)
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { index in
                            let collection = conversionManager.collections[index]
                            conversionManager.deleteCollection(collection)
                        }
                    }
                }
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddCollection = true }) {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .alert("New Collection", isPresented: $showingAddCollection) {
                TextField("Collection Name", text: $newCollectionName)
                Button("Cancel", role: .cancel) { newCollectionName = "" }
                Button("Create") {
                    if !newCollectionName.isEmpty {
                        conversionManager.createCollection(name: newCollectionName, icon: "folder", color: "Blue")
                        newCollectionName = ""
                    }
                }
            }
        }
    }
}

// ✅ FIX: Simplified Row (Values only, no logic)
struct CollectionRow: View {
    let collection: PDFCollection
    let itemCount: Int
    
    var body: some View {
        NavigationLink(destination: CollectionDetailView(collection: collection)) {
            HStack {
                Image(systemName: collection.icon)
                    .foregroundColor(.blue)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(collection.name)
                        .font(.headline)
                    Text("\(itemCount) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct CollectionDetailView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let collection: PDFCollection
    
    var collectionPDFs: [ConvertedPDF] {
        conversionManager.convertedPDFs.filter { $0.collectionId == collection.id }
    }
    
    var body: some View {
        List {
            ForEach(collectionPDFs) { pdf in
                NavigationLink(destination: ConvertView(pdf: pdf)) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundColor(.orange)
                        Text(pdf.name)
                    }
                }
            }
        }
        .navigationTitle(collection.name)
    }
}
