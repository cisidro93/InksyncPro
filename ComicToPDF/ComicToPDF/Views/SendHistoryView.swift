import SwiftUI

struct SendHistoryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        List {
            Section {
                Button(action: conversionManager.clearSendHistory) {
                    Text("Clear History")
                        .foregroundColor(.red)
                }
            }
            
            ForEach(conversionManager.sendHistory, id: \.id) { (record: SendHistoryRecord) in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.pdfName)
                        .font(.headline)
                    HStack {
                        Image(systemName: "ipad.and.arrow.forward")
                        Text("Sent to \(record.deviceName)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    Text(record.dateSent, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Send History")
    }
}
