import SwiftUI

struct DuplicateResolutionView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @StateObject private var reviewManager = DuplicateReviewManager()
    
    var body: some View {
        NavigationStack {
            Group {
                if reviewManager.duplicateGroups.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("No Duplicates Found")
                            .font(.title2).bold()
                        
                        Text("Your library is meticulously optimized.\nFree of clutter and structural duplicate files.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(reviewManager.duplicateGroups, id: \.first?.id) { group in
                            Section {
                                ForEach(group) { pdf in
                                    HStack {
                                        if let img = conversionManager.getThumbnail(for: pdf) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 40, height: 55)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        } else {
                                            Rectangle()
                                                .fill(Color(.secondarySystemBackground))
                                                .frame(width: 40, height: 55)
                                                .cornerRadius(6)
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(pdf.name)
                                                .font(.subheadline)
                                                .fontWeight(.semibold)
                                                .lineLimit(1)
                                            
                                            HStack {
                                                Text(formatSize(pdf.fileSize)).font(.caption).foregroundColor(.secondary)
                                                Text("Ã¢â‚¬Â¢").font(.caption).foregroundColor(.secondary)
                                                Text(pdf.contentType.rawValue.capitalized).font(.caption).foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                        
                                        Menu {
                                            Button("Keep This, Discard Others", role: .destructive) {
                                                reviewManager.keepTargetDiscardOthers(target: pdf, group: group, manager: conversionManager)
                                            }
                                            
                                            Button("Delete This Copy", role: .destructive) {
                                                reviewManager.deleteItems([pdf], from: conversionManager)
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle.fill")
                                                .frame(width: 44, height: 44)
                                                .foregroundColor(Theme.orange)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            } header: {
                                let mb = Double(group.first?.fileSize ?? 0) / 1024 / 1024
                                Text("\(group.count) Identical Files Found (~\(String(format: "%.1f", mb)) MB each)")
                            }
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }
            }
            .navigationTitle("Optimize Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) { Text("Done").bold() }
                }
                
                if !reviewManager.duplicateGroups.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            // Keep the first file from every group, delete everything else across every group
                            for group in reviewManager.duplicateGroups {
                                guard let target = group.first else { continue }
                                reviewManager.keepTargetDiscardOthers(target: target, group: group, manager: conversionManager)
                            }
                        } label: {
                            Text("Merge All").bold()
                        }
                    }
                }
            }
        }
        .onAppear {
            reviewManager.assessDuplicates(in: conversionManager)
        }
        .tint(Theme.orange)
        .preferredColorScheme(.dark)
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
