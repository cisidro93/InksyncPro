import SwiftUI
import SwiftData

struct ManuscriptProjectsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDManuscriptProject.modifiedAt, order: .reverse) private var projects: [SDManuscriptProject]
    
    @State private var showingNewProjectDialog = false
    @State private var newProjectTitle = ""
    @State private var newProjectGoal = ""
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            
            if projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(projects) { project in
                            NavigationLink(destination: ManuscriptEditorWorkspace(project: project)) {
                                ProjectRowView(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Writer's Studio")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingNewProjectDialog = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New Manuscript", isPresented: $showingNewProjectDialog) {
            TextField("Project Title", text: $newProjectTitle)
            TextField("Word Count Goal (e.g. 50000)", text: $newProjectGoal)
                .keyboardType(.numberPad)
            Button("Create") {
                createProject()
            }
            Button("Cancel", role: .cancel) {
                newProjectTitle = ""
                newProjectGoal = ""
            }
        } message: {
            Text("Enter a title and an optional word count goal for your new writing project.")
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "note.text")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("No Writing Projects")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Turn your Zettelkasten notes into a long-form manuscript or essay.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                showingNewProjectDialog = true
            } label: {
                Text("Start Writing")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.orange)
                    .cornerRadius(8)
            }
            .padding(.top, 10)
        }
    }
    
    private func createProject() {
        guard !newProjectTitle.isEmpty else { return }
        let target = Int(newProjectGoal) ?? 0
        let newProject = SDManuscriptProject(title: newProjectTitle, targetWordCount: target)
        modelContext.insert(newProject)
        try? modelContext.save()
        newProjectTitle = ""
        newProjectGoal = ""
    }
}

struct ProjectRowView: View {
    let project: SDManuscriptProject
    
    var body: some View {
        HStack(spacing: 16) {
            // Ulysses-style circular progress ring
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: project.progressPercentage)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(), value: project.progressPercentage)
                
                if project.progressPercentage >= 1.0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.orange)
                } else {
                    Text("\(Int(project.progressPercentage * 100))%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack {
                    Text("\(project.currentWordCount) words")
                    if project.targetWordCount > 0 {
                        Text("of \(project.targetWordCount)")
                    }
                    Text("•")
                    Text("\(project.documents.count) chapters")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }
}
