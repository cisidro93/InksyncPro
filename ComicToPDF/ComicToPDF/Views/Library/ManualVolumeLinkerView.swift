import SwiftUI

struct ManualVolumeLinkerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let seriesID: String
    let seriesTitle: String
    
    @State private var showingAddVolume = false
    @State private var editingVolumeName: String? = nil
    
    // Editor state
    @State private var volumeName = ""
    @State private var rangeText = ""
    @State private var selectedIssueIDs: Set<UUID> = []
    
    @State private var showSuccessBanner = false
    @State private var bannerMessage = ""
    @State private var showingAutoChunkSheet = false
    @State private var autoChunkSize = 6
    
    var freshIssues: [ConvertedPDF] {
        conversionManager.convertedPDFs.filter { pdf in
            // 1. If explicit collection UUID is set (custom folder)
            if let folderUUID = UUID(uuidString: seriesID) {
                return pdf.collectionId == folderUUID
            }
            
            // 2. Otherwise match by series name (case-insensitive metadata series)
            if let seriesName = pdf.metadata.series,
               seriesName.localizedCaseInsensitiveCompare(seriesTitle) == .orderedSame {
                return true
            }
            
            // 3. Fallback: filename contains series title
            let filename = pdf.name.lowercased()
            let title = seriesTitle.lowercased()
            return filename.contains(title)
        }
    }
    
    // Volume buckets compiled from fresh issues
    var volumeGroups: [(name: String, issues: [ConvertedPDF])] {
        var groups: [String: [ConvertedPDF]] = [:]
        var ungrouped: [ConvertedPDF] = []
        
        for pdf in freshIssues {
            if let vol = pdf.metadata.volume, !vol.trimmingCharacters(in: .whitespaces).isEmpty {
                groups[vol, default: []].append(pdf)
            } else {
                ungrouped.append(pdf)
            }
        }
        
        let sortedGroups = groups.keys.sorted { a, b in
            if let ia = Int(a.filter { $0.isNumber }), let ib = Int(b.filter { $0.isNumber }) {
                return ia < ib
            }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { (name: $0, issues: groups[$0] ?? []) }
        
        var result = sortedGroups
        if !ungrouped.isEmpty {
            result.append((name: "Ungrouped", issues: ungrouped))
        }
        return result
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header Description Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Digital Atelier Binder: \(seriesTitle)")
                            .font(.title2.bold())
                            .foregroundColor(Theme.text)
                        
                        Text("Curate and bind issues into virtual volumes with zero disk duplication. Changes sync automatically to file metadata and library shelves.")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(3)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                Button {
                                    autoAssignNextVolume()
                                } label: {
                                    Label("Auto-Assign Next Vol", systemImage: "sparkles")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Theme.orange.gradient)
                                        .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                                
                                Button {
                                    showingAutoChunkSheet = true
                                } label: {
                                    Label("Auto-Group All", systemImage: "square.grid.3x3.fill")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Theme.purple.gradient)
                                        .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                                
                                Button {
                                    autoLinkFromFilenames()
                                } label: {
                                    Label("Auto-Link Filenames", systemImage: "text.magnifyingglass")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.inkSurfaceRaised)
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                
                                Button {
                                    volumeName = ""
                                    rangeText = ""
                                    selectedIssueIDs = []
                                    editingVolumeName = nil
                                    showingAddVolume = true
                                } label: {
                                    Label("Link New Volume", systemImage: "plus.circle")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Theme.blue.gradient)
                                        .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(Color.inkBorderSubtle),
                        alignment: .bottom
                    )
                    
                    if freshIssues.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray.fill")
                                .font(.system(size: 48))
                                .foregroundColor(Theme.textTertiary)
                            Text("No issues found in this series.")
                                .font(.headline)
                                .foregroundColor(Theme.textSecondary)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(volumeGroups, id: \.name) { group in
                                let completedCount = group.issues.filter { (ReaderProgressTracker.shared.progress(for: $0.id)?.completionFraction ?? 0) >= 0.95 }.count
                                let isCompletedRun = !group.issues.isEmpty && completedCount == group.issues.count
                                Section(header: HStack(spacing: 6) {
                                    Text(group.name == "Ungrouped" ? "Ungrouped Issues" : "Volume: \(group.name)")
                                        .font(.headline)
                                        .foregroundColor(group.name == "Ungrouped" ? Theme.textSecondary : Theme.orange)

                                    if isCompletedRun && group.name != "Ungrouped" {
                                        HStack(spacing: 3) {
                                            Image(systemName: "checkmark.seal.fill")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(Theme.orange)
                                            Text("Completed Run")
                                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                                .foregroundColor(Theme.orange)
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(Theme.orange.opacity(0.12))
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().strokeBorder(Theme.orange.opacity(0.3), lineWidth: 0.8)
                                        )
                                    }

                                    Spacer()

                                    if group.name != "Ungrouped" {
                                        Button {
                                            prepareEditVolume(name: group.name, issues: group.issues)
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                                .font(.caption)
                                                .foregroundColor(Theme.blue)
                                        }
                                        .buttonStyle(.borderless)

                                        Button {
                                            unlinkVolume(group.name)
                                        } label: {
                                            Label("Unlink", systemImage: "link.badge.plus")
                                                .font(.caption)
                                                .foregroundColor(Theme.red)
                                        }
                                        .buttonStyle(.borderless)
                                        .padding(.leading, 8)
                                    }
                                }) {
                                    ForEach(group.issues) { pdf in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(pdf.name)
                                                    .font(.subheadline)
                                                    .foregroundColor(Theme.text)

                                                HStack(spacing: 8) {
                                                    if let issue = pdf.metadata.issueNumber {
                                                        Text("Issue #\(issue)")
                                                            .font(.caption2)
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 1)
                                                            .background(Theme.blue.opacity(0.1))
                                                            .foregroundColor(Theme.blue)
                                                            .cornerRadius(3)
                                                    }

                                                    if let vol = pdf.metadata.volume {
                                                        Text("Volume \(vol)")
                                                            .font(.caption2)
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 1)
                                                            .background(Theme.orange.opacity(0.1))
                                                            .foregroundColor(Theme.orange)
                                                            .cornerRadius(3)
                                                    }

                                                    let progress = ReaderProgressTracker.shared.progress(for: pdf.id)?.completionFraction ?? 0
                                                    if progress >= 0.95 {
                                                        HStack(spacing: 2) {
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .font(.system(size: 9.5, weight: .bold))
                                                            Text("Read")
                                                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                                        }
                                                        .foregroundColor(Theme.green)
                                                    } else if progress > 0.02 {
                                                        Text("\(Int(progress * 100))%")
                                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                            .foregroundColor(Theme.textSecondary)
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
                
                // Success Banner Overlay
                if showSuccessBanner {
                    VStack {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Theme.green)
                                .font(.title3)
                            Text(bannerMessage)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.9))
                                .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
                        )
                        .padding(.top, 24)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .navigationTitle("Link Volumes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(Theme.textSecondary)
                }
            }
            .sheet(isPresented: $showingAddVolume) {
                volumeEditorSheet
                    .forceProMotion()
            }
            .sheet(isPresented: $showingAutoChunkSheet) {
                manualAutoChunkSheet
            }
        }
    }
    
    // MARK: - Volume Editor Sheet UI
    
    private var volumeEditorSheet: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    // Form fields
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Volume Name / Number")
                                .font(.caption.bold())
                                .foregroundColor(Theme.textSecondary)
                            TextField("e.g. Volume 1, Vol 2, Special", text: $volumeName)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Quick Select by Issue Range")
                                .font(.caption.bold())
                                .foregroundColor(Theme.textSecondary)
                            TextField("e.g. 1-10, 12, 15-20", text: $rangeText)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .onChange(of: rangeText) { _, newValue in
                                    applyRangeSelection(newValue)
                                }
                        }
                    }
                    .padding()
                    .background(Theme.surface)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .padding(.top)
                    
                    // Checklist of files
                    List {
                        Section(header: HStack {
                            Text("Select Issues to Link (\(selectedIssueIDs.count)/\(freshIssues.count))")
                            Spacer()
                            if !freshIssues.isEmpty {
                                Button(selectedIssueIDs.count == freshIssues.count ? "Deselect All" : "Select All") {
                                    HapticEngine.selection()
                                    if selectedIssueIDs.count == freshIssues.count {
                                        selectedIssueIDs.removeAll()
                                    } else {
                                        selectedIssueIDs = Set(freshIssues.map(\.id))
                                    }
                                }
                                .font(.caption.bold())
                                .foregroundColor(Theme.blue)
                            }
                        }) {
                            ForEach(freshIssues) { pdf in
                                Button {
                                    if selectedIssueIDs.contains(pdf.id) {
                                        selectedIssueIDs.remove(pdf.id)
                                    } else {
                                        selectedIssueIDs.insert(pdf.id)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: selectedIssueIDs.contains(pdf.id) ? "checkmark.square.fill" : "square")
                                            .foregroundColor(selectedIssueIDs.contains(pdf.id) ? Theme.blue : Theme.textTertiary)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(pdf.name)
                                                .font(.subheadline)
                                                .foregroundColor(Theme.text)
                                                .lineLimit(1)
                                            
                                            HStack(spacing: 6) {
                                                if let issue = pdf.metadata.issueNumber {
                                                    Text("Issue #\(issue)")
                                                        .font(.caption2)
                                                        .foregroundColor(Theme.textSecondary)
                                                }
                                                if let currentVol = pdf.metadata.volume {
                                                    Text("(Currently in: \(currentVol))")
                                                        .font(.caption2)
                                                        .foregroundColor(Theme.orange)
                                                }
                                            }
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(editingVolumeName == nil ? "Link Volume" : "Edit Volume Mappings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAddVolume = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveVolumeMapping()
                    }
                    .disabled(volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    // MARK: - Actions & Logic
    
    private func applyRangeSelection(_ rawText: String) {
        let clean = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        
        let parsed = parseIssues(from: clean)
        var newSelection = Set<UUID>()
        
        for pdf in freshIssues {
            if let issueNum = pdf.metadata.issueNumber {
                if parsed.contains(issueNum) {
                    newSelection.insert(pdf.id)
                }
            }
        }
        
        selectedIssueIDs = newSelection
    }
    
    private func parseIssues(from rangeText: String) -> Set<String> {
        var selectedIssues = Set<String>()
        let parts = rangeText.components(separatedBy: ",")
        for part in parts {
            let cleanPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanPart.contains("-") {
                let rangeParts = cleanPart.components(separatedBy: "-")
                if rangeParts.count == 2,
                   let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                   let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) {
                    for i in min(start, end)...max(start, end) {
                        selectedIssues.insert("\(i)")
                    }
                }
            } else if cleanPart.contains("–") { // supports en-dash
                let rangeParts = cleanPart.components(separatedBy: "–")
                if rangeParts.count == 2,
                   let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                   let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) {
                    for i in min(start, end)...max(start, end) {
                        selectedIssues.insert("\(i)")
                    }
                }
            } else if let val = Int(cleanPart) {
                selectedIssues.insert("\(val)")
            } else if !cleanPart.isEmpty {
                selectedIssues.insert(cleanPart)
            }
        }
        return selectedIssues
    }
    
    private func saveVolumeMapping() {
        let targetVolumeName = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetVolumeName.isEmpty else { return }
        
        // 1. If we are editing, first clear the old volume tag from all issues of this series
        if let oldName = editingVolumeName {
            for idx in conversionManager.convertedPDFs.indices {
                let pdf = conversionManager.convertedPDFs[idx]
                if freshIssues.contains(where: { $0.id == pdf.id }) && pdf.metadata.volume == oldName {
                    conversionManager.convertedPDFs[idx].metadata.volume = nil
                }
            }
        }
        
        // 2. Set the volume tags on selected items
        for id in selectedIssueIDs {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == id }) {
                conversionManager.convertedPDFs[idx].metadata.volume = targetVolumeName
            }
        }
        
        conversionManager.saveLibrary()
        NotificationCenter.default.post(name: .libraryUpdated, object: nil)
        showingAddVolume = false
        triggerBanner(message: "Volume \(targetVolumeName) linked successfully!")
    }
    
    private func prepareEditVolume(name: String, issues: [ConvertedPDF]) {
        editingVolumeName = name
        volumeName = name
        rangeText = ""
        selectedIssueIDs = Set(issues.map { $0.id })
        showingAddVolume = true
    }
    
    private func unlinkVolume(_ name: String) {
        for idx in conversionManager.convertedPDFs.indices {
            let pdf = conversionManager.convertedPDFs[idx]
            if freshIssues.contains(where: { $0.id == pdf.id }) && pdf.metadata.volume == name {
                conversionManager.convertedPDFs[idx].metadata.volume = nil
            }
        }
        conversionManager.saveLibrary()
        NotificationCenter.default.post(name: .libraryUpdated, object: nil)
        triggerBanner(message: "Volume \(name) unlinked.")
    }
    
    private func autoLinkFromFilenames() {
        let count = conversionManager.autoDetectVolumesFromFilenames(for: freshIssues)
        if count > 0 {
            triggerBanner(message: "Auto-linked \(count) issues from filenames!")
        } else {
            triggerBanner(message: "No volume patterns found in filenames.")
        }
    }
    
    private func triggerBanner(message: String) {
        bannerMessage = message
        withAnimation {
            showSuccessBanner = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                showSuccessBanner = false
            }
        }
    }
    
    private func autoAssignNextVolume() {
        if let result = conversionManager.autoAssignNextVolume(for: freshIssues) {
            triggerBanner(message: "Auto-assigned \(result.assignedCount) issues to Volume \(result.volumeNumber)!")
        } else {
            triggerBanner(message: "All issues already assigned to volumes.")
        }
    }
    
    private func autoChunkSeries(chunkSize: Int) {
        let count = conversionManager.autoChunkSeries(issues: freshIssues, chunkSize: chunkSize)
        if count > 0 {
            triggerBanner(message: "Auto-grouped \(freshIssues.count) issues into \(count) volumes!")
        }
    }
    
    private var manualAutoChunkSheet: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.orange)
                            .padding(.top, 16)
                        
                        Text("Auto-Group Series into Volumes")
                            .font(.title3.bold())
                            .foregroundColor(Theme.text)
                        
                        Text("Automatically divide all \(freshIssues.count) issues of \(seriesTitle) into sequential volumes based on your preferred volume size.")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ISSUES PER VOLUME")
                            .font(.caption.bold())
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal)
                        
                        HStack(spacing: 10) {
                            ForEach([4, 5, 6, 8, 10, 12], id: \.self) { size in
                                Button {
                                    HapticEngine.selection()
                                    autoChunkSize = size
                                } label: {
                                    Text("\(size)")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(
                                            autoChunkSize == size
                                                ? AnyShapeStyle(Theme.orange.gradient)
                                                : AnyShapeStyle(Theme.surface)
                                        )
                                        .foregroundColor(autoChunkSize == size ? .white : Theme.text)
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(autoChunkSize == size ? Color.white.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        
                        let totalVols = max(1, Int(ceil(Double(freshIssues.count) / Double(autoChunkSize))))
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(Theme.orange)
                            Text("Will create \(totalVols) volume\(totalVols == 1 ? "" : "s") (Vol 1 to Vol \(totalVols)).")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 16)
                    .background(Theme.surface.opacity(0.5))
                    .cornerRadius(16)
                    .padding(.horizontal)
                    
                    Spacer()
                    
                    Button {
                        showingAutoChunkSheet = false
                        autoChunkSeries(chunkSize: autoChunkSize)
                    } label: {
                        Text("Apply Volume Grouping")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.orange.gradient)
                            .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Auto-Group Volumes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAutoChunkSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
