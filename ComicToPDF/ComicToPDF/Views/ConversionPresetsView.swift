import SwiftUI

struct ConversionPresetsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingAddPreset = false
    
    var body: some View {
        List {
            // ✅ Fix: Use indices to create bindings safely
            ForEach($conversionManager.conversionPresets) { $preset in
                NavigationLink(destination: Text("Edit Preset: \(preset.name)")) {
                    Text(preset.name)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let preset = conversionManager.conversionPresets[index]
                    conversionManager.deletePreset(preset)
                }
            }
        }
        .navigationTitle("Presets")
        .toolbar {
            Button { showingAddPreset = true } label: { Image(systemName: "plus") }
        }
    }
}
