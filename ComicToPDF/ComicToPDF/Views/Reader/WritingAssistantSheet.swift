import SwiftUI
import UIKit

@MainActor
struct WritingAssistantSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    
    @State private var correctedText: String = ""
    @State private var issues: [AssistantIssue] = []
    @State private var currentIssueIndex = 0
    @State private var ignoredWords: Set<String> = []
    
    struct AssistantIssue: Identifiable, Equatable {
        let id = UUID()
        let type: IssueType
        let originalText: String
        let suggestions: [String]
        let description: String
        var range: NSRange
        
        enum IssueType {
            case spelling, grammar
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header progress or completion seal
                if issues.isEmpty {
                    completionView
                } else {
                    progressHeader
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Context Preview")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                                .padding(.top, 16)
                            
                            // AttributedString context text display with highlighted errors
                            Text(highlightedText)
                                .font(.system(size: 15))
                                .lineSpacing(6)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                                .padding(.horizontal)
                        }
                    }
                    
                    Spacer()
                    
                    // Card View for the current issue
                    if issues.indices.contains(currentIssueIndex) {
                        issueCard(issues[currentIssueIndex])
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
            }
            .navigationTitle("Writing Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(UIColor.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if !issues.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Apply Corrections") {
                            text = correctedText
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            dismiss()
                        }
                        .fontWeight(.bold)
                    }
                }
            }
            .onAppear {
                correctedText = text
                analyzeText()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var progressHeader: some View {
        HStack {
            Text("Reviewing Spelling & Grammar")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)
            Spacer()
            Text("\(currentIssueIndex + 1) of \(issues.count)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue, in: Capsule())
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }
    
    private var completionView: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green)
            }
            
            Text("Spellcheck Complete")
                .font(.title2.bold())
            
            Text("The spelling and grammar checker has finished scanning your note. No issues found.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
            
            Button {
                text = correctedText
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue, in: Capsule())
            }
            .padding()
        }
        .frame(maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func issueCard(_ issue: AssistantIssue) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(issue.description)
                    .font(.caption.bold())
                    .foregroundColor(issue.type == .spelling ? .red : .blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (issue.type == .spelling ? Color.red : Color.blue).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                
                Spacer()
                
                Button {
                    ignoreIssue(issue)
                } label: {
                    Text("Ignore")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                if issue.type == .spelling {
                    Button {
                        addToDictionary(issue.originalText)
                    } label: {
                        Text("Add to Dict")
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Original Word:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(issue.originalText)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            
            // Suggestion pills
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestions:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if issue.suggestions.isEmpty {
                    Text("No suggestions available")
                        .font(.subheadline)
                        .italic()
                        .foregroundColor(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(errorSuggestions(for: issue), id: \.self) { suggestion in
                                Button {
                                    applySuggestion(issue, replacement: suggestion)
                                } label: {
                                    Text(suggestion)
                                        .font(.subheadline.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.blue, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16, corners: [.topLeft, .topRight])
        .shadow(color: .black.opacity(0.08), radius: 10, y: -5)
    }
    
    private func errorSuggestions(for issue: AssistantIssue) -> [String] {
        return issue.suggestions
    }
    
    // MARK: - AttributedString Highlight Engine
    
    private var highlightedText: AttributedString {
        var attrStr = AttributedString(correctedText)
        
        for (index, issue) in issues.enumerated() {
            guard let range = Range(issue.range, in: correctedText) else { continue }
            if let attributedRange = attrStr.range(of: correctedText[range]) {
                if index == currentIssueIndex {
                    attrStr[attributedRange].backgroundColor = Color.yellow.opacity(0.3)
                    attrStr[attributedRange].underlineStyle = .single
                    attrStr[attributedRange].underlineColor = .red
                } else {
                    attrStr[attributedRange].underlineStyle = .single
                    attrStr[attributedRange].underlineColor = issue.type == .spelling ? .red : .blue
                }
            }
        }
        return attrStr
    }
    
    // MARK: - Core Checks Logic
    
    private func analyzeText() {
        var newIssues: [AssistantIssue] = []
        var textState = correctedText
        
        // 1. Spell Check using UITextChecker
        let checker = UITextChecker()
        let nsStringText = textState as NSString
        var searchLocation = 0
        
        while searchLocation < nsStringText.length {
            let limitRange = NSRange(location: searchLocation, length: nsStringText.length - searchLocation)
            let misspellingRange = checker.rangeOfMisspelledWord(
                in: textState,
                range: limitRange,
                startingAt: searchLocation,
                wrap: false,
                language: "en"
            )
            
            guard misspellingRange.location != NSNotFound else { break }
            
            let misspelledWord = nsStringText.substring(with: misspellingRange)
            searchLocation = misspellingRange.location + misspellingRange.length
            
            // Skip ignored words
            if ignoredWords.contains(misspelledWord.lowercased()) { continue }
            
            let rawGuesses = checker.guesses(forWordRange: misspellingRange, in: textState, language: "en") ?? []
            let topGuesses = Array(rawGuesses.prefix(5))
            
            newIssues.append(AssistantIssue(
                type: .spelling,
                originalText: misspelledWord,
                suggestions: topGuesses,
                description: "Spelling Error",
                range: misspellingRange
            ))
        }
        
        // 2. Grammar Pattern Heuristics
        let contractionsMap = [
            "dont": "don't", "cant": "can't", "im": "I'm", "youre": "you're",
            "didnt": "didn't", "its": "it's", "couldnt": "couldn't", "shouldnt": "shouldn't",
            "wouldnt": "wouldn't", "wasnt": "wasn't", "werent": "weren't", "hasnt": "hasn't",
            "havent": "haven't", "hadnt": "hadn't", "whats": "what's", "thats": "that's",
            "theyre": "they're", "weve": "we've", "ive": "I've"
        ]
        
        for (wrong, right) in contractionsMap {
            let regexStr = "\\b\(wrong)\\b"
            if let regex = try? NSRegularExpression(pattern: regexStr, options: [.caseInsensitive]) {
                let nsText = textState as NSString
                let range = NSRange(location: 0, length: nsText.length)
                let matches = regex.matches(in: textState, options: [], range: range)
                for match in matches {
                    let matchedWord = nsText.substring(with: match.range)
                    if !newIssues.contains(where: { $0.range.intersection(match.range) != nil }) {
                        newIssues.append(AssistantIssue(
                            type: .grammar,
                            originalText: matchedWord,
                            suggestions: [right],
                            description: "Contraction punctuation missing",
                            range: match.range
                        ))
                    }
                }
            }
        }
        
        // 3. Punctuation spacing (comma/period followed directly by letter)
        let spacingPattern = "([,\\.!?])([a-zA-Z])"
        if let spacingRegex = try? NSRegularExpression(pattern: spacingPattern, options: []) {
            let nsText = textState as NSString
            let range = NSRange(location: 0, length: nsText.length)
            let matches = spacingRegex.matches(in: textState, options: [], range: range)
            for match in matches {
                if match.numberOfRanges == 3 {
                    let matchedSegment = nsText.substring(with: match.range)
                    let punctuation = nsText.substring(with: match.range(at: 1))
                    let letter = nsText.substring(with: match.range(at: 2))
                    let suggestion = "\(punctuation) \(letter)"
                    if !newIssues.contains(where: { $0.range.intersection(match.range) != nil }) {
                        newIssues.append(AssistantIssue(
                            type: .grammar,
                            originalText: matchedSegment,
                            suggestions: [suggestion],
                            description: "Punctuation spacing missing",
                            range: match.range
                        ))
                    }
                }
            }
        }
        
        // Sort issues by document range order
        self.issues = newIssues.sorted { $0.range.location < $1.range.location }
        
        // Cap index
        if currentIssueIndex >= issues.count {
            currentIssueIndex = max(0, issues.count - 1)
        }
    }
    
    // MARK: - Actions
    
    private func applySuggestion(_ issue: AssistantIssue, replacement: String) {
        let nsString = correctedText as NSString
        guard issue.range.location + issue.range.length <= nsString.length else { return }
        
        let newText = nsString.replacingCharacters(in: issue.range, with: replacement)
        correctedText = newText
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Re-analyze document to recalibrate all ranges and errors
        analyzeText()
    }
    
    private func ignoreIssue(_ issue: AssistantIssue) {
        withAnimation {
            if currentIssueIndex < issues.count - 1 {
                currentIssueIndex += 1
            } else {
                if let idx = issues.firstIndex(of: issue) {
                    issues.remove(at: idx)
                }
            }
        }
    }
    
    private func addToDictionary(_ word: String) {
        ignoredWords.insert(word.lowercased())
        withAnimation {
            analyzeText()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
