import SwiftUI

struct ConversionPresetsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingAddPreset = false
    @State private var newPresetName = ""
    
    var body: some View {
        List {
            ForEach(conversionManager.conversionPresets) { preset in
                HStack {
                    Image(systemName: preset.icon)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text(preset.name)
                            .font(.headline)
                        if preset.isDefault {
                            Text("Default").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Apply") {
                        conversionManager.applyPreset(preset)
                    }
                    .buttonStyle(.bordered)
                }
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        conversionManager.deletePreset(preset)
                    }
                }
            }
            .onDelete { indexSet in
                indexSet.forEach { index in
                    let preset = conversionManager.conversionPresets[index]
                    conversionManager.deletePreset(preset)
                }
            }
            
            Section {
                Button(action: { showingAddPreset = true }) {
                    Label("Save Current Settings as Preset", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Presets")
        .alert("New Preset", isPresented: $showingAddPreset) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") {
                let preset = ConversionPreset(name: newPresetName, settings: conversionManager.conversionSettings)
                conversionManager.savePreset(preset)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
