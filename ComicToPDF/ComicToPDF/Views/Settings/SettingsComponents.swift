import SwiftUI

// MARK: - AdvancedOptionsView
struct AdvancedOptionsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    var body: some View {
        Form {
            Section {
                // Fixed header syntax:
                Toggle(isOn: $settingsManager.conversionSettings.enablePanelSplit) {
                    Text("Enable Panel Split")
                }
            } header: {
                Text("Panel Processing")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .navigationTitle("Advanced Options")
    }
}

// MARK: - ConversionPresetsView
struct ConversionPresetsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @State private var showingAddPreset = false
    
    var body: some View {
        List {
            // ✅ Fix: Use indices to create bindings safely
            ForEach($settingsManager.conversionPresets) { $preset in
                NavigationLink(destination: Text("Edit Preset: \(preset.name)")) {
                    Text(preset.name)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let preset = settingsManager.conversionPresets[index]
                    settingsManager.deletePreset(preset)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .navigationTitle("Presets")
        .toolbar {
            Button { showingAddPreset = true } label: { Image(systemName: "plus") }
        }
    }
}

// MARK: - StorageManagerView
struct StorageManagerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
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
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .onAppear {
            storageInfo = conversionManager.calculateStorageInfo()
        }
    }
}

// MARK: - AutoOrganizeView
struct AutoOrganizeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            Text("Auto Organize")
                .font(.title)
                .bold()
            
            Text("This will automatically sort uncategorized PDFs into collections based on their Series metadata or filename matches.")
                .multilineTextAlignment(.center)
                .padding()
            
            Button(action: {
                conversionManager.autoOrganize()
                dismiss()
            }) {
                Text("Start Organization")
                    .bold()
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(10)
            }
        }
        .padding()
    }
}

// MARK: - SendHistoryView
struct SendHistoryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    var body: some View {
        List {
            if settingsManager.sendHistory.isEmpty {
                Text("No history yet.")
                    .foregroundColor(.secondary)
            } else {
                // ✅ Fix: Direct iteration, no binding needed for display
                ForEach(settingsManager.sendHistory) { pdf in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pdf.name)
                                .font(.headline)
                            Text(pdf.formattedSize)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "clock")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .navigationTitle("Send History")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    settingsManager.clearSendHistory()
                }
                .disabled(settingsManager.sendHistory.isEmpty)
            }
        }
    }
}
