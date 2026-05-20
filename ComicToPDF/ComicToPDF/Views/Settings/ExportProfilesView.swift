import SwiftUI

struct ExportProfilesView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @State private var showingAddPreset = false
    @State private var newPresetName = ""
    @State private var newPresetSettings = ConversionSettings()

    var body: some View {
        List {
            Section(header: Text("Saved Profiles")) {
                if settingsManager.conversionPresets.isEmpty {
                    Text("No custom profiles saved yet. Tap + to create one based on your current settings.")
                        .foregroundColor(.secondary)
                        .font(.callout)
                        .padding(.vertical, 8)
                } else {
                    ForEach(settingsManager.conversionPresets) { preset in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name)
                                .font(.headline)
                            HStack {
                                Text(preset.settings.outputFormat.rawValue)
                                Text("•")
                                Text(preset.settings.compressionQuality.rawValue)
                                if preset.settings.mangaMode {
                                    Text("•")
                                    Text("Manga RTL")
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        settingsManager.conversionPresets.remove(atOffsets: indexSet)
                        conversionManager.saveLibrary()
                    }
                }
            }
            
            Section {
                Button(action: {
                    newPresetName = ""
                    newPresetSettings = settingsManager.conversionSettings // Default to current global settings
                    showingAddPreset = true
                }) {
                    Label("Create New Profile", systemImage: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .navigationTitle("Export Profiles")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showingAddPreset) {
            NavigationStack {
                Form {
                    Section(header: Text("Profile Info")) {
                        TextField("Name (e.g., Manga Oasis, Webtoon PDF)", text: $newPresetName)
                    }
                    
                    Section(header: Text("Core Settings")) {
                        Picker("Output Format", selection: $newPresetSettings.outputFormat) {
                            ForEach(OutputFormat.allCases) { format in Label(format.rawValue, systemImage: format.icon).tag(format) }
                        }
                        Picker("Compression", selection: $newPresetSettings.compressionQuality) {
                            ForEach(CompressionPreset.allCases, id: \.self) { preset in Text(preset.rawValue).tag(preset) }
                        }
                        Toggle("Default Manga Mode (RTL)", isOn: $newPresetSettings.mangaMode)
                    }
                    
                    if newPresetSettings.outputFormat == .epub {
                        Section(header: Text("EPUB Advanced")) {
                            Picker("Conversion Pipeline", selection: $newPresetSettings.outputPipeline) {
                                ForEach(OutputPipeline.allCases) { pipeline in Text(pipeline.rawValue).tag(pipeline) }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listRowBackground(Color.inkSurface.opacity(0.4))
                .navigationTitle("New Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { showingAddPreset = false }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            let finalName = newPresetName.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom Profile" : newPresetName
                            let preset = ConversionPreset(name: finalName, settings: newPresetSettings)
                            settingsManager.conversionPresets.append(preset)
                            conversionManager.saveLibrary()
                            showingAddPreset = false
                        }
                        .fontWeight(.bold)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
