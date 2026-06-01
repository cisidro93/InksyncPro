import SwiftUI
import SwiftData

struct MetadataInboxView: View {
    @ObservedObject private var matchService = MetadataMatchService.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // Premium dark theme background
            Theme.bg.ignoresSafeArea()
            
            let unmatched = matchService.activeClusters.filter {
                if case .matched = $0.status { return false }
                return true
            }
            
            if unmatched.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.green)
                    Text("All Series Identified!")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Theme.text)
                    Text("Every folder in your library is matched to metadata. Character maps are ready to use in the reader.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    Button("Dismiss") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.inkBlue, in: Capsule())
                    .foregroundColor(.white)
                    .padding(.top, 10)
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Verify Metadata Matches")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                        
                        Text("Confirm the correct series below. This will automatically label all issues in the folder and download character relationship maps.")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                        
                        ForEach(unmatched) { cluster in
                            clusterCard(for: cluster)
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .navigationTitle("Metadata Inbox")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private func clusterCard(for cluster: MetadataMatchService.SeriesCluster) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Folder title and issue count
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cluster.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Theme.text)
                    Text("\(cluster.pdfs.count) Local Issues")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                
                statusActionButton(for: cluster)
            }
            
            // Candidate results list
            if case .ambiguous(let candidates) = cluster.status {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Select correct series:")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.purple)
                    
                    ForEach(candidates) { candidate in
                        Button {
                            Task {
                                await matchService.bindCandidateToCluster(clusterID: cluster.id, candidate: candidate)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Theme.text)
                                    HStack(spacing: 8) {
                                        if let publisher = candidate.publisher {
                                            Text(publisher)
                                        }
                                        if let year = candidate.startYear {
                                            Text("(\(year))")
                                        }
                                    }
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.purple)
                                    .font(.system(size: 18))
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Error banner
            if case .failed(let error) = cluster.status {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.red)
                    .padding(8)
                    .background(Theme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .padding(.horizontal, 16)
        )
    }
    
    @ViewBuilder
    private func statusActionButton(for cluster: MetadataMatchService.SeriesCluster) -> some View {
        switch cluster.status {
        case .idle:
            Button {
                Task {
                    await matchService.startMatching(clusterID: cluster.id)
                }
            } label: {
                Text("Match")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.inkBlue, in: Capsule())
                    .foregroundColor(.white)
            }
            
        case .searching:
            ProgressView()
                .controlSize(.small)
                .tint(.purple)
                
        case .matched:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 20))
                
        case .ambiguous:
            EmptyView()
            
        case .failed:
            Button {
                Task {
                    await matchService.startMatching(clusterID: cluster.id)
                }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}
