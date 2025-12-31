import SwiftUI

struct SendHistoryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingClearAlert = false
    
    var body: some View {
        List {
            if !conversionManager.sendHistory.isEmpty {
                Section {
                    Button(action: {
                        HapticManager.shared.impact(.medium)
                        showingClearAlert = true
                    }) {
                        Text("Clear History")
                            .foregroundColor(.red)
                    }
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
                    
                    Text(record.sentDate, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Send History")
        .overlay(Group {
            if conversionManager.sendHistory.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 60)).foregroundColor(.secondary.opacity(0.5))
                    Text("No History").font(.title2).fontWeight(.semibold)
                    Text("Files you send to Kindle will appear here").font(.subheadline).foregroundColor(.secondary)
                }
            }
        })
        .alert("Clear History?", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                HapticManager.shared.notification(.success)
                withAnimation {
                    conversionManager.clearSendHistory()
                }
            }
        } message: {
            Text("This will remove all records of sent files from your history.")
        }
    }
}
