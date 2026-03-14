import SwiftUI

struct TemplateLibraryView: View {
    // In a real implementation this would fetch from disk or CoreData
    @State private var projects: [PlannerProject] = []
    @State private var showingFavoritesOnly = false
    
    // Navigation State
    @State private var showingGoModeGallery = false
    @State private var showingProModeEditor = false
    @State private var newProjectToEdit: PlannerProject? = nil
    
    var filteredProjects: [PlannerProject] {
        if showingFavoritesOnly {
            return projects.filter { $0.isFavorite }
        }
        return projects
    }
    
    let columns = [
        GridItem(.adaptive(minimum: 150))
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // Quick Actions
                    HStack(spacing: 15) {
                        Button(action: { showingGoModeGallery = true }) {
                            VStack {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 30))
                                    .padding(.bottom, 5)
                                Text("Go Mode")
                                    .font(.headline)
                                Text("AI & Templates")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(12)
                        }
                        
                        Button(action: createBlankProject) {
                            VStack {
                                Image(systemName: "pencil.and.outline")
                                    .font(.system(size: 30))
                                    .padding(.bottom, 5)
                                Text("Pro Mode")
                                    .font(.headline)
                                Text("Canvas Editor")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .foregroundColor(.orange)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Filters
                    Picker("Filter", selection: $showingFavoritesOnly) {
                        Text("All Templates").tag(false)
                        Text("Favorites").tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    
                    // Library Grid
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredProjects) { project in
                            TemplateCardView(project: project, toggleFavorite: {
                                toggleFavorite(for: project)
                            })
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Template Vault")
            .sheet(isPresented: $showingGoModeGallery) {
                PlannerGalleryView()
            }
            // Simple NavigationLink trigger for new Pro Mode editor
            .background(
                NavigationLink(
                    destination: {
                        if let proj = newProjectToEdit {
                            PlannerEditorView(project: .constant(proj))
                        } else {
                            EmptyView()
                        }
                    }(),
                    isActive: $showingProModeEditor,
                    label: { EmptyView() }
                )
            )
        }
    }
    
    private func createBlankProject() {
        let newProject = PlannerProject(title: "Untitled Planner", pages: [PlannerPage()])
        // In real app: save to disk, then append to state
        projects.insert(newProject, at: 0)
        newProjectToEdit = newProject
        showingProModeEditor = true
    }
    
    private func toggleFavorite(for project: PlannerProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].isFavorite.toggle()
        }
    }
}

// Subview for individual cards
struct TemplateCardView: View {
    let project: PlannerProject
    let toggleFavorite: () -> Void
    
    var body: some View {
        VStack(alignment: .leading) {
            ZStack(alignment: .topTrailing) {
                if let thumbData = project.coverThumbnailData, let uiImage = UIImage(data: thumbData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(3/4, contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .cornerRadius(10)
                        .shadow(radius: 2)
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemBackground))
                        .aspectRatio(3/4, contentMode: .fit)
                        .cornerRadius(10)
                        .shadow(radius: 2)
                        .overlay(
                            VStack {
                                Image(systemName: "doc.richtext")
                                    .font(.largeTitle)
                                    .foregroundColor(.gray)
                                Text("\(project.pages.count) Pages")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.top, 5)
                            }
                        )
                }
                
                Button(action: toggleFavorite) {
                    Image(systemName: project.isFavorite ? "heart.fill" : "heart")
                        .foregroundColor(project.isFavorite ? .red : .gray)
                        .padding(8)
                        .background(Color.white.opacity(0.8))
                        .clipShape(Circle())
                }
                .padding(8)
            }
            
            Text(project.title)
                .font(.subheadline)
                .bold()
                .lineLimit(1)
            
            Text(project.targetDevice.brand)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
