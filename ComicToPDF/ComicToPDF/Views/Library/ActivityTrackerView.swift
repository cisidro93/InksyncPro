import SwiftUI

struct ActivityTrackerButton: View {
    @EnvironmentObject var manager: ConversionManager
    @State private var showQueue = false
    
    var body: some View {
        Button(action: { showQueue = true }) {
            ZStack {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 20))
                    .foregroundColor(manager.activeTasks.isEmpty ? .secondary : .purple)
                
                if !manager.activeTasks.isEmpty {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 10, y: -10)
                }
            }
        }
        .popover(isPresented: $showQueue) {
            ActivityQueueView(tasks: manager.activeTasks)
                .frame(minWidth: 300, minHeight: 400)
        }
    }
}

struct ActivityQueueView: View {
    let tasks: [AppBackgroundTask]
    
    var body: some View {
        NavigationStack {
            List {
                if tasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                        Text("All Background Tasks Complete")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    Section("Active Tasks") {
                        ForEach(tasks) { task in
                            TaskMonitorRow(task: task)
                        }
                    }
                }
            }
            .navigationTitle("Activity Tracker")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
