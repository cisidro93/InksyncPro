import SwiftUI

struct AutoOrganizeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
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
