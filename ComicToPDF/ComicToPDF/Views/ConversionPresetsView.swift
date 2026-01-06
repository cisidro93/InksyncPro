import SwiftUI

struct ConversionPresetsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingAddPreset = false
    @State private var newPresetName = ""
    
    var body: some View {
        Form {
            Section(header: Text("Saved Presets")) {
                // ✅ Fix: iterators must be Identifiable, pass Binding via $
                ForEach($conversionManager.conversionPresets) { $preset in
                    HStack {
                        Image(systemName: preset.icon)
                            .foregroundColor(.blue)
                        Text(preset.name)
                        Spacer()
                        if preset.isDefault {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            conversionManager.deletePreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            
            Section {
                HStack {
                    TextField("New Preset Name", text: $newPresetName)
                    Button("Save Current Settings") {
                        let preset = ConversionPreset(name: newPresetName, settings: conversionManager.conversionSettings)
                        conversionManager.savePreset(preset)
                        newPresetName = ""
                    }
                    .disabled(newPresetName.isEmpty)
                }
            }
        }
        .navigationTitle("Presets")
    }
}
