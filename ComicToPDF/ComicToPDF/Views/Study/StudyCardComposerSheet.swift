import SwiftUI

// MARK: - Study Card Composer Sheet

/// Modal sheet for creating and editing Spaced Repetition Study Cards with live cloze deletion preview.
public struct StudyCardComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let existingCard: StudyCard?
    var initialCitation: PassageCitation? = nil
    var initialBody: String? = nil
    var onSave: (StudyCard) -> Void
    
    @State private var markdownBody: String = ""
    @State private var selectedMarker: AdlerMarker? = nil
    @State private var rawTags: String = ""
    
    // Citation State
    @State private var documentTitle: String = ""
    @State private var pageNumber: Int = 1
    @State private var highlightedQuote: String = ""
    @State private var anchorID: String = ""
    
    @FocusState private var isBodyFocused: Bool
    
    private let clozeParser = ClozeDeletionParser.shared
    
    public init(
        existingCard: StudyCard? = nil,
        initialCitation: PassageCitation? = nil,
        initialBody: String? = nil,
        onSave: @escaping (StudyCard) -> Void
    ) {
        self.existingCard = existingCard
        self.initialCitation = initialCitation
        self.initialBody = initialBody
        self.onSave = onSave
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                // MARK: - Section 1: Card Body & Cloze Preview
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $markdownBody)
                            .frame(minHeight: 120)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .focused($isBodyFocused)
                        
                        // Cloze Insertion Shortcut
                        HStack {
                            Button {
                                insertClozeSyntax()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "highlighter")
                                    Text("Wrap in Cloze ==")
                                }
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.inkViolet)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.inkViolet.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            if clozeParser.hasClozeDeletions(in: markdownBody) {
                                Text("\(clozeParser.extractClozeAnswers(from: markdownBody).count) Cloze Deletions")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.inkViolet)
                            }
                        }
                    }
                } header: {
                    Text("CARD PROMPT / CLOZE BODY")
                } footer: {
                    Text("Wrap masked answers in double equals, e.g. ==hippocampus== for active recall.")
                }
                
                // Live Cloze Preview Box
                if clozeParser.hasClozeDeletions(in: markdownBody) {
                    Section("ACTIVE RECALL PREVIEW") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Prompt:")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.inkTextTertiary)
                            
                            Text(clozeParser.generateMaskedPrompt(from: markdownBody))
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(.inkTextPrimary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - Section 2: Mortimer Adler Reading Marker
                Section("MORTIMER ADLER READING MARKER") {
                    Picker("Reading Marker", selection: $selectedMarker) {
                        Text("None").tag(AdlerMarker?.none)
                        ForEach(AdlerMarker.allCases) { marker in
                            Text("\(marker.symbol) \(marker.title)").tag(AdlerMarker?.some(marker))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    
                    if let marker = selectedMarker {
                        HStack(spacing: 8) {
                            Text(marker.symbol)
                                .font(.system(size: 14, weight: .black))
                                .foregroundColor(marker.accentColor)
                            Text(marker.meaning)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundColor(.inkTextSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                // MARK: - Section 3: Bear-Style Nested Tags
                Section("NESTED TAGS") {
                    TextField("e.g. #medicine/neurology #ch4", text: $rawTags)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .autocapitalization(.none)
                }
                
                // MARK: - Section 4: Document Passage Citation
                Section("SOURCE CITATION") {
                    TextField("Document Title", text: $documentTitle)
                    
                    Stepper("Page \(pageNumber)", value: $pageNumber, in: 1...9999)
                    
                    TextField("Highlighted Quote / Anchor", text: $highlightedQuote, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(existingCard == nil ? "New Study Card" : "Edit Study Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCard()
                    }
                    .disabled(markdownBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                populateInitialState()
            }
        }
    }
    
    // MARK: - Actions
    
    private func insertClozeSyntax() {
        HapticEngine.light()
        if markdownBody.isEmpty {
            markdownBody = "The answer is ==hidden term==."
        } else {
            markdownBody += " ==answer=="
        }
    }
    
    private func populateInitialState() {
        if let existing = existingCard {
            markdownBody = existing.markdownBody
            selectedMarker = existing.adlerTag
            rawTags = existing.tags.joined(separator: " ")
            documentTitle = existing.citation.documentTitle
            pageNumber = existing.citation.pageNumber
            highlightedQuote = existing.citation.highlightedText
            anchorID = existing.citation.anchorID ?? ""
        } else {
            if let initialBody = initialBody {
                markdownBody = initialBody
            }
            if let cit = initialCitation {
                documentTitle = cit.documentTitle
                pageNumber = cit.pageNumber
                highlightedQuote = cit.highlightedText
                anchorID = cit.anchorID ?? ""
            }
        }
    }
    
    private func saveCard() {
        let tagList = rawTags
            .split(separator: " ")
            .map { String($0) }
            .map { $0.hasPrefix("#") ? $0 : "#\($0)" }
        
        let citation = PassageCitation(
            documentID: existingCard?.citation.documentID ?? initialCitation?.documentID ?? UUID(),
            documentTitle: documentTitle.isEmpty ? "General Study" : documentTitle,
            pageNumber: pageNumber,
            anchorID: anchorID.isEmpty ? nil : anchorID,
            highlightedText: highlightedQuote.isEmpty ? markdownBody : highlightedQuote
        )
        
        let card = StudyCard(
            id: existingCard?.id ?? UUID(),
            citation: citation,
            markdownBody: markdownBody,
            adlerTag: selectedMarker,
            tags: tagList,
            dueDate: existingCard?.dueDate ?? Date(),
            intervalDays: existingCard?.intervalDays ?? 0.0,
            repetitionCount: existingCard?.repetitionCount ?? 0,
            easeFactor: existingCard?.easeFactor ?? 2.5,
            createdAt: existingCard?.createdAt ?? Date(),
            modifiedAt: Date()
        )
        
        HapticEngine.success()
        onSave(card)
        dismiss()
    }
}
