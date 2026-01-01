import SwiftUI

struct TaskMonitorRow: View {
    @ObservedObject var task: BackgroundTask
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.2), lineWidth: 3)
                    .frame(width: 32, height: 32)
                
                Circle()
                    .trim(from: 0, to: task.progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear, value: task.progress)
                
                if task.progress >= 1.0 {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(task.description)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack(spacing: 8) {
                    // GeometricReader for custom progress bar if preferred over linear
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange.opacity(0.2))
                                .frame(height: 4)
                            
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange)
                                .frame(width: geometry.size.width * task.progress, height: 4)
                                .animation(.linear, value: task.progress)
                        }
                    }
                    .frame(height: 4)
                    
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                        .frame(width: 35, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
