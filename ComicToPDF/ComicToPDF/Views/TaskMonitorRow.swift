import SwiftUI

struct TaskMonitorRow: View {
    // ✅ Updated type
    @ObservedObject var task: AppBackgroundTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.description)
                .font(.caption)
                .foregroundColor(.primary)
            
            ProgressView(value: task.progress)
        }
        .padding(.vertical, 4)
    }
}
