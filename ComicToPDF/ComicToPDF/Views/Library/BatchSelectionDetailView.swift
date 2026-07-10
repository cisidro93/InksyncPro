import SwiftUI

struct BatchSelectionDetailView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    var selectionCount: Int
    var onBatchEdit: () -> Void
    var onFetchMetadata: () -> Void
    var onConvert: () -> Void
    var onMerge: () -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "checklist")
                .font(.system(size: 80))
                .foregroundColor(.blue.opacity(0.8))
            
            Text("\(selectionCount) Items Selected")
                .font(.largeTitle)
                .bold()
            
            Text("Choose an action for the selected files.")
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                // ✅ NEW: Expose Smart Cropping directly in the Batch UI
                Toggle(isOn: $settingsManager.conversionSettings.trimMargins) {
                    Label("Smart Border Trimming", systemImage: "crop")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                .padding()
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
                .frame(maxWidth: 300)
                
                Button {
                    onBatchEdit()
                } label: {
                    Label("Edit Metadata", systemImage: "pencil.and.list.clipboard")
                        .font(.headline)
                        .frame(maxWidth: 300)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(selectionCount == 0)
                
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    onFetchMetadata()
                } label: {
                    Label("Intelligent Metadata", systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: 300)
                        .padding()
                        .background(alignment: .center) {
                            if selectionCount == 0 {
                                Color.gray.opacity(0.3)
                            } else {
                                LinearGradient(colors: [Theme.blue, Theme.blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .shadow(color: selectionCount == 0 ? .clear : Theme.blue.opacity(0.4), radius: 5, y: 2)
                }
                .disabled(selectionCount == 0)
                
                Button {
                    onConvert()
                } label: {
                    Label("Convert Selected", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .frame(maxWidth: 300)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(selectionCount == 0)
                
                Button {
                    onMerge()
                } label: {
                    Label("Convert & Merge", systemImage: "arrow.triangle.2.circlepath.doc")
                        .font(.headline)
                        .frame(maxWidth: 300)
                        .padding()
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(selectionCount < 2)
                
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: 300)
                        .padding()
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(12)
                }
                .disabled(selectionCount == 0)
                
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel Selection")
                        .foregroundColor(.blue)
                }
                .padding(.top, 10)
            }
        }
        .padding()
    }
}
