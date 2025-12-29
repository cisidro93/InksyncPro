import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var kindleEmail: String = ""
    @State private var imageQuality: Double = 0.8
    @State private var autoSplit: Bool = true
    @State private var splitThreshold: Int = 50
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("your_kindle@kindle.com", text: $kindleEmail)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .textContentType(.emailAddress)
                        
                        Text("Find this in your Amazon account under 'Manage Your Content and Devices' → 'Preferences' → 'Personal Document Settings'")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Label("Kindle Email", systemImage: "envelope.fill")
                } footer: {
                    Text("Make sure to add your sending email address to the approved list in Amazon settings.")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Image Quality")
                            Spacer()
                            Text("\(Int(imageQuality * 100))%")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $imageQuality, in: 0.5...1.0, step: 0.1)
                            .tint(.orange)
                        
                        Text("Higher quality = larger file size")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Label("Conversion Quality", systemImage: "photo.fill")
                }
                
                Section {
                    Toggle("Auto-suggest split for large files", isOn: $autoSplit)
                        .tint(.orange)
                    
                    if autoSplit {
                        Picker("Split threshold", selection: $splitThreshold) {
                            Text("25 MB").tag(25)
                            Text("50 MB").tag(50)
                            Text("100 MB").tag(100)
                        }
                    }
                } header: {
                    Label("Large File Handling", systemImage: "scissors")
                } footer: {
                    Text("Amazon Kindle has a 50MB email attachment limit.")
                }
                
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Label("About", systemImage: "info.circle.fill")
                }
                
                Section {
                    HStack {
                        Text("Converted PDFs")
                        Spacer()
                        Text("\(conversionManager.convertedPDFs.count) files")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(conversionManager.totalStorageUsed)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(role: .destructive) {
                        conversionManager.clearAllPDFs()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear All Converted PDFs")
                        }
                    }
                } header: {
                    Label("Storage", systemImage: "internaldrive.fill")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                kindleEmail = conversionManager.kindleEmail
                imageQuality = conversionManager.imageQuality
                autoSplit = conversionManager.autoSplit
                splitThreshold = conversionManager.splitThreshold
            }
            .onChange(of: kindleEmail) { newValue in
                conversionManager.kindleEmail = newValue
            }
            .onChange(of: imageQuality) { newValue in
                conversionManager.imageQuality = newValue
            }
            .onChange(of: autoSplit) { newValue in
                conversionManager.autoSplit = newValue
            }
            .onChange(of: splitThreshold) { newValue in
                conversionManager.splitThreshold = newValue
            }
        }
        .navigationViewStyle(.stack)
    }
}
