import SwiftUI

struct BatchSelectionDetailView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    var selectionCount: Int
    var onConvert: () -> Void
    var onMerge: () -> Void
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
                    Label("Convert & Merge", systemImage: "doc.on.doc.fill")
                        .font(.headline)
                        .frame(maxWidth: 300)
                        .padding()
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(selectionCount < 2)
                
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
