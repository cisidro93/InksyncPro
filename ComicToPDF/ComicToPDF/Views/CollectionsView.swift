import SwiftUI

struct CollectionsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingAddCollection = false
    @State private var newCollectionName = ""
    
    var body: some View {
        NavigationView {
            List {
                // "All Files" Special Row
                NavigationLink(destination: LibraryFilteredView(collectionId: nil)) {
                    HStack {
                        Image(systemName: "books.vertical.fill")
                            .foregroundColor(.blue)
                            .font(.title2)
                        Text("All Comics")
                        Spacer()
                        Text("\(conversionManager.convertedPDFs.count)")
                            .foregroundColor(.secondary)
                    }
                }
                
                // User Collections
                Section(header: Text("Your Collections")) {
                    ForEach(conversionManager.collections) { collection in
                        NavigationLink(destination: LibraryFilteredView(collectionId: collection.id)) {
                            HStack {
                                Image(systemName: collection.icon)
                                    .foregroundColor(Color(collection.color)) // Requires Color extension or simple string mapping
                                    .font(.title2)
                                Text(collection.name)
                                Spacer()
                                Text("\(countFiles(in: collection))")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let col = conversionManager.collections[index]
                            conversionManager.deleteCollection(col)
                        }
                    }
                }
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAddCollection = true } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .alert("New Collection", isPresented: $showingAddCollection) {
                TextField("Collection Name", text: $newCollectionName)
                Button("Create") {
                    if !newCollectionName.isEmpty {
                        conversionManager.createCollection(name: newCollectionName, icon: "folder.fill", color: "blue")
                        newCollectionName = ""
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
    
    func countFiles(in collection: PDFCollection) -> Int {
        conversionManager.convertedPDFs.filter { $0.collectionId == collection.id }.count
    }
}

// Helper View to show files inside a specific collection
struct LibraryFilteredView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let collectionId: UUID?
    
    var filteredFiles: [ConvertedPDF] {
        if let id = collectionId {
            return conversionManager.convertedPDFs.filter { $0.collectionId == id }
        } else {
            return conversionManager.convertedPDFs
        }
    }
    
    var body: some View {
        List(filteredFiles) { pdf in
            HStack {
                Image(systemName: "doc.text")
                Text(pdf.name)
            }
        }
        .navigationTitle(collectionName)
    }
    
    var collectionName: String {
        if let id = collectionId, let col = conversionManager.collections.first(where: { $0.id == id }) {
            return col.name
        }
        return "All Comics"
    }
}
