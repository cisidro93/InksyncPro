import SwiftUI
import SwiftData

struct ManuscriptProjectsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDManuscriptProject.modifiedAt, order: .reverse) private var projects: [SDManuscriptProject]

    @State private var showingNewProjectDialog = false
    @State private var newProjectTitle = ""
    @State private var newProjectGoal = ""
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()

            if projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: InkSpacing.rowGap) {
                        ForEach(projects) { project in
                            NavigationLink(destination: ManuscriptEditorWorkspace(project: project)) {
                                ProjectRowView(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(InkSpacing.pagePadding)
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
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.inkAccentKnowledge)
                }
            }
        }
        .alert("New Manuscript", isPresented: $showingNewProjectDialog) {
            TextField("Project Title", text: $newProjectTitle)
            TextField("Word Count Goal (e.g. 50000)", text: $newProjectGoal)
                .keyboardType(.numberPad)
            Button("Create") { createProject() }
            Button("Cancel", role: .cancel) {
                newProjectTitle = ""
                newProjectGoal = ""
            }
        } message: {
            Text("Enter a title and an optional word count goal for your new writing project.")
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                // Outer pulse ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.inkAccentKnowledge.opacity(0.3), Color.inkBlue.opacity(0.15)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 140, height: 140)
                    .scaleEffect(glowPulse ? 1.15 : 1.0)
                    .opacity(glowPulse ? 0.0 : 1.0)
                    .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false), value: glowPulse)

                // Ambient glow
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(colors: [Color.inkAccentKnowledge.opacity(0.3), Color.inkBlue.opacity(0.12), .clear]),
                        center: .center, startRadius: 20, endRadius: 72
                    ))
                    .frame(width: 144, height: 144)
                    .blur(radius: 24)

                // Icon card
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.inkAccentKnowledge.opacity(0.25), radius: 20, y: 8)

                Image(systemName: "note.text")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.inkAccentKnowledge, Color.inkBlue],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }
            .onAppear { glowPulse = true }

            VStack(spacing: 8) {
                Text("No Writing Projects")
                    .font(.title2.bold())
                    .foregroundStyle(Color.inkTextPrimary)

                Text("Turn your Zettelkasten research into a manuscript, essay, or novel.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                showingNewProjectDialog = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("Start Writing")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(
                        colors: [Color.inkAccentKnowledge, Color.inkBlue],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: Color.inkAccentKnowledge.opacity(0.4), radius: 10, y: 4)
            }

            Spacer()
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

// MARK: - Project Row
struct ProjectRowView: View {
    let project: SDManuscriptProject

    var body: some View {
        HStack(spacing: 16) {
            // Ulysses-style progress ring — violet = writing/knowledge accent
            ZStack {
                Circle()
                    .stroke(Color.inkBorderVisible, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: project.progressPercentage)
                    .stroke(
                        LinearGradient(
                            colors: [Color.inkAccentKnowledge, Color.inkBlue],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: project.progressPercentage)

                if project.progressPercentage >= 1.0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.inkAccentKnowledge)
                } else {
                    Text("\(Int(project.progressPercentage * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkTextSecondary)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(project.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.inkTextPrimary)

                HStack(spacing: 6) {
                    Text("\(project.currentWordCount) words")
                    if project.targetWordCount > 0 {
                        Text("of \(project.targetWordCount)")
                    }
                    Text("·")
                    Text("\(project.documents.count) chapters")
                }
                .font(.caption)
                .foregroundStyle(Color.inkTextSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(Color.inkTextTertiary)
        }
        .padding(InkSpacing.cardPadding)
        .inkCard()
    }
}
