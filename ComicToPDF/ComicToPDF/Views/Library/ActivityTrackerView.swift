import SwiftUI

struct ActivityTrackerButton: View {
    @EnvironmentObject var manager: ConversionManager
    @ObservedObject private var importMonitor = ImportMonitorManager.shared
    @State private var showQueue = false
    
    var body: some View {
        Button(action: { showQueue = true }) {
            ZStack {
                let isActive = !manager.activeTasks.isEmpty || importMonitor.isImporting
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 20))
                    .foregroundColor(isActive ? .purple : .secondary)
                
                if isActive {
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
    @ObservedObject private var importMonitor = ImportMonitorManager.shared
    
    var body: some View {
        NavigationStack {
            List {
                if tasks.isEmpty && !importMonitor.isImporting {
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
                    if importMonitor.isImporting {
                        Section("Importing Files") {
                            HStack(spacing: 16) {
                                ProgressView()
                                    .controlSize(.regular)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Extracting Archives")
                                        .font(.headline)
                                    
                                    Text("\(importMonitor.filesProcessed) of \(importMonitor.totalFilesToProcess) complete")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Text("\(Int(importMonitor.progress * 100))%")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.purple)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    if !tasks.isEmpty {
                        Section("Active Tasks") {
                            ForEach(tasks) { task in
                                TaskMonitorRow(task: task)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity Tracker")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
