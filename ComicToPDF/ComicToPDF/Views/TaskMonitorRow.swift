import SwiftUI

struct TaskMonitorRow: View {
    @ObservedObject var task: AppBackgroundTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title) // ✅ Fix: Use title instead of description
                    .font(.headline)
                Spacer()
                Text("\(Int(task.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: task.progress)
                .progressViewStyle(LinearProgressViewStyle())
        }
        .padding(.vertical, 8)
    }
}
