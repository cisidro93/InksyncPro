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
                    // Logic extracted to helper to fix compiler timeout
                    ForEach(conversionManager.collections) { collection in
                        CollectionRow(collection: collection, itemCount: getPDFCount(for: collection))
                    }
                    .onDelete(perform: deleteCollections)
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
    
    // MARK: - Helpers (Keeps the View Builder simple)
    
    func getPDFCount(for collection: PDFCollection) -> Int {
        return conversionManager.convertedPDFs.filter { $0.collectionId == collection.id }.count
    }
    
    func deleteCollections(at offsets: IndexSet) {
        offsets.forEach { index in
            let collection = conversionManager.collections[index]
            conversionManager.deleteCollection(collection)
        }
    }
}

// Subview for the Row
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

// Subview for the Detail List
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
