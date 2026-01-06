import SwiftUI

struct SendHistoryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        NavigationView {
            Group {
                if conversionManager.sendHistory.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text("No History")
                            .foregroundColor(.secondary)
                    }
                } else {
                    historyList
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
    
    // ✅ Fix: Extracted logic to separate property
    private var historyList: some View {
        List {
            ForEach(conversionManager.sendHistory) { pdf in
                HStack {
                    VStack(alignment: .leading) {
                        Text(pdf.name)
                            .font(.headline)
                        Text("Sent: \(pdf.dateAdded.formatted())")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        }
    }
}
