import SwiftUI
import Combine

struct ImportTrackerView: View {
    @StateObject private var monitor = ImportMonitorManager.shared
    
    var body: some View {
        VStack {
            Spacer()
            
            if monitor.isImporting {
                HStack(spacing: 16) {
                    // Spinner / Icon
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 3)
                            .frame(width: 24, height: 24)
                        
                        Circle()
                            .trim(from: 0, to: monitor.progress)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 24, height: 24)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: monitor.progress)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Importing Files")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("\(monitor.filesProcessed) of \(monitor.totalFilesToProcess) complete")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 28/255, green: 28/255, blue: 30/255))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
                .padding(.horizontal, 20)
                .padding(.bottom, 80) // Above safely areas and toolbars
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: monitor.isImporting)
            }
        }
        .alert("Import Complete", isPresented: $monitor.showCompletionReport) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(monitor.finalReportMessage)
        }
    }
}
