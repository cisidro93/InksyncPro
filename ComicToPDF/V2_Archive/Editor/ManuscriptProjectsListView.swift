import SwiftUI
import SwiftData

struct ManuscriptProjectsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDManuscriptProject.modifiedAt, order: .reverse) private var projects: [SDManuscriptProject]

    @State private var showingNewProjectDialog = false
    @State private var newProjectTitle = ""
    @State private var newProjectGoal = ""
    @State private var glowPulse = false
    @State private var projectToDelete: SDManuscriptProject? = nil
    // Phase 4E-3: Template gallery
    @State private var showingTemplateGallery = false

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

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
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    projectToDelete = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(InkSpacing.pagePadding)
                }
            }
        }
        .navigationTitle("Writer's Studio")
        .toolbar {
            // Phase 4E-3: Template gallery button
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingTemplateGallery = true
                } label: {
                    Label("Templates", systemImage: "books.vertical.fill")
                        .foregroundStyle(Color.inkAccentKnowledge)
                }
            }
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
        // Phase 4E-3: Template gallery sheet
        .sheet(isPresented: $showingTemplateGallery) {
            TemplateGallerySheet { template in
                createFromTemplate(template)
            }
        }
        .alert("Delete Project?", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let project = projectToDelete {
                    modelContext.delete(project)
                    try? modelContext.save()
                }
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            if let project = projectToDelete {
                Text("\"\(project.title)\" and all its chapters will be permanently deleted. This cannot be undone.")
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

    // Phase 4E-3: Create a project from a template
    private func createFromTemplate(_ template: WritingTemplate) {
        let project = SDManuscriptProject(
            title: template.defaultTitle,
            targetWordCount: template.targetWordCount
        )
        modelContext.insert(project)
        // Seed the first chapter with a scaffold outline
        let chapter = SDManuscriptDocument(
            title: template.firstChapterTitle,
            contentMarkdown: template.scaffoldMarkdown,
            orderIndex: 0
        )
        chapter.project = project
        modelContext.insert(chapter)
        try? modelContext.save()
        showingTemplateGallery = false
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

// MARK: - Phase 4E-3: Writing Templates

struct WritingTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let accent: Color
    let description: String
    let defaultTitle: String
    let targetWordCount: Int
    let firstChapterTitle: String
    let scaffoldMarkdown: String

    static let all: [WritingTemplate] = [
        WritingTemplate(
            id: "novel",
            name: "Novel",
            icon: "book.closed.fill",
            accent: Color(hex: "#F5A623"),
            description: "Long-form fiction with chapters, character arcs, and world-building.",
            defaultTitle: "My Novel",
            targetWordCount: 80000,
            firstChapterTitle: "Chapter 1 — The Beginning",
            scaffoldMarkdown: """
# Chapter 1 — The Beginning

## Scene Setup
_Where are we? Establish time, place, and mood._

## Protagonist Introduction
_Who do we meet first? What do they want?_

## Inciting Incident
_What disrupts the ordinary world?_

---
> **Note:** Keep your first chapter under 4,000 words. Hook the reader in the first paragraph.
"""
        ),
        WritingTemplate(
            id: "screenplay",
            name: "Screenplay",
            icon: "film.fill",
            accent: Color(hex: "#30D5C8"),
            description: "Feature-length or short-film script in standard industry format.",
            defaultTitle: "My Screenplay",
            targetWordCount: 25000,
            firstChapterTitle: "ACT ONE",
            scaffoldMarkdown: """
# ACT ONE

## FADE IN:

**EXT. LOCATION — DAY**

_Description of the opening image. Set the tone._

**CHARACTER NAME**
Dialogue goes here.

---

## STORY BEAT: The Ordinary World

_Establish protagonist's life before everything changes._

## STORY BEAT: The Inciting Incident (p. 10–12)

_Something happens that sets the story in motion._

## STORY BEAT: Plot Point I (p. 25–30)

_The protagonist crosses the threshold. No going back._

## FADE OUT.
"""
        ),
        WritingTemplate(
            id: "comic_script",
            name: "Comic Script",
            icon: "character.bubble.fill",
            accent: Color(hex: "#BF5AF2"),
            description: "Panel-by-panel script for sequential art with dialogue and action lines.",
            defaultTitle: "My Comic Script",
            targetWordCount: 8000,
            firstChapterTitle: "Issue #1",
            scaffoldMarkdown: """
# Issue #1 — Title Here

**PAGES: 22  |  PANELS PER PAGE: 3–6**

---

## PAGE 1

**PANEL 1**
_Wide establishing shot. Describe setting and mood._
*(No dialogue — let the art breathe.)*

**PANEL 2**
_Medium shot. Introduce protagonist._

**CHARACTER:** Dialogue here.

**PANEL 3**
_Close-up. React to something off-panel._

---

## PAGE 2

**PANEL 1**
_Action beat. Describe movement clearly._

**CAPTION:** Narration or inner monologue.

---

> **Script tip:** One page of script ≈ one page of art. Keep panel descriptions concise — artists need creative room.
"""
        ),
        WritingTemplate(
            id: "essay",
            name: "Essay",
            icon: "doc.text.fill",
            accent: Color(hex: "#34C759"),
            description: "Argumentative or analytical essay with thesis, evidence, and conclusion.",
            defaultTitle: "My Essay",
            targetWordCount: 3000,
            firstChapterTitle: "Draft",
            scaffoldMarkdown: """
# Essay Title

## Introduction
_Hook the reader. State your thesis clearly in the final sentence._

**Thesis:** _Your central argument goes here._

---

## Body — Point 1
_State the point. Provide evidence. Explain relevance._

### Evidence
> "Quote or data source here." — Author, Year

### Analysis
_How does this support your thesis?_

---

## Body — Point 2
_State the point. Provide evidence. Explain relevance._

---

## Body — Point 3 (Counter-argument)
_Acknowledge opposing view. Rebut it._

---

## Conclusion
_Restate thesis in light of evidence. Broader implications._
"""
        ),
        WritingTemplate(
            id: "research_notes",
            name: "Research Notes",
            icon: "magnifyingglass",
            accent: Color(hex: "#FF9F0A"),
            description: "Structured research document with source tracking and key findings.",
            defaultTitle: "Research: [Topic]",
            targetWordCount: 5000,
            firstChapterTitle: "Key Findings",
            scaffoldMarkdown: """
# Research: [Topic]

**Date started:** [Date]
**Status:** In progress

---

## Research Question
_What are you trying to find out?_

---

## Key Sources

| # | Source | Type | Relevance |
|---|--------|------|-----------|
| 1 |        | Book |           |
| 2 |        | Paper|           |

---

## Key Findings

### Finding 1
_Summary of what you found._
- Evidence:
- Implication:

### Finding 2
_Summary of what you found._

---

## Synthesis
_How do the findings connect? What patterns emerge?_

---

## Open Questions
- [ ] Question 1
- [ ] Question 2

---

## Bibliography
_Full citations in your preferred format._
"""
        ),
    ]
}

// MARK: - Template Gallery Sheet UI

struct TemplateGallerySheet: View {
    let onSelect: (WritingTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hovered: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(WritingTemplate.all) { template in
                        TemplateCard(template: template, isHovered: hovered == template.id)
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onSelect(template)
                            }
                            .onHover { over in hovered = over ? template.id : nil }
                    }
                }
                .padding(20)
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Choose a Template")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct TemplateCard: View {
    let template: WritingTemplate
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(template.accent.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: template.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(template.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.inkTextPrimary)
                Text(template.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkTextSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Text("\(template.targetWordCount / 1000)k words")
                    .font(.caption2.bold())
                    .foregroundStyle(template.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(template.accent.opacity(0.12), in: Capsule())
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption.bold())
                    .foregroundStyle(template.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.inkSurfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isHovered ? template.accent.opacity(0.5) : Color.inkBorderSubtle,
                    lineWidth: isHovered ? 1.5 : 0.5
                )
        )
        .shadow(color: isHovered ? template.accent.opacity(0.15) : .black.opacity(0.04),
                radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
    }
}
