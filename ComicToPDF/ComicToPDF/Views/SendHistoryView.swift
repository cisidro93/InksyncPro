import SwiftUI

struct SendHistoryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        List {
            if conversionManager.sendHistory.isEmpty {
                Text("No history yet.")
                    .foregroundColor(.secondary)
            } else {
                // ✅ Fix: Direct iteration, no binding needed for display
                ForEach(conversionManager.sendHistory) { pdf in
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
        .navigationTitle("Send History")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    conversionManager.clearSendHistory()
                }
                .disabled(conversionManager.sendHistory.isEmpty)
            }
        }
    }
}
