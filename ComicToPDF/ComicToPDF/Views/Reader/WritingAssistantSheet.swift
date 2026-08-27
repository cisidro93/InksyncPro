import SwiftUI
import UIKit
import NaturalLanguage

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
        let explanation: String
        var range: NSRange
        
        enum IssueType {
            case spelling, grammar
        }
    }
    
    private struct WritingStats {
        var wordCount: Int = 0
        var sentenceCount: Int = 0
        var syllableCount: Int = 0
        var passiveVoiceCount: Int = 0
        
        var readingEase: Double {
            guard wordCount > 0, sentenceCount > 0 else { return 100.0 }
            let score = 206.835 - 1.015 * (Double(wordCount) / Double(sentenceCount)) - 84.6 * (Double(syllableCount) / Double(wordCount))
            return max(0, min(100, score))
        }
        
        var readingEaseLabel: String {
            let score = readingEase
            if score >= 90 { return "Very Easy (5th Grade)" }
            else if score >= 80 { return "Easy (6th Grade)" }
            else if score >= 70 { return "Fairly Easy (7th Grade)" }
            else if score >= 60 { return "Standard (8th-9th Grade)" }
            else if score >= 50 { return "Fairly Difficult (High School)" }
            else if score >= 30 { return "Difficult (College)" }
            else { return "Very Difficult (Academic/Graduate)" }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.08))
                            .frame(width: 80, height: 80)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                    }
                    .padding(.top, 24)
                    
                    Text("Spelling & Grammar Clear!")
                        .font(.title3.bold())
                    
                    // Stats Dashboard Card
                    let stats = computedStats
                    VStack(spacing: 16) {
                        Text("Writing Insights")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.secondary)
                            
                        Divider()
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Readability Level")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(stats.readingEaseLabel)
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                            }
                            Spacer()
                            CircularMetricView(value: stats.readingEase, label: String(format: "%.0f", stats.readingEase))
                        }
                        
                        Divider()
                        
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Words")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(stats.wordCount)")
                                    .font(.body.bold())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sentences")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(stats.sentenceCount)")
                                    .font(.body.bold())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Passive Voice")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(stats.passiveVoiceCount)")
                                    .font(.body.bold())
                                    .foregroundColor(stats.passiveVoiceCount > 0 ? .orange : .secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 4)
                    .padding(.horizontal)
                }
            }
            
            Button {
                text = correctedText
                dismiss()
            } label: {
                Text("Apply & Save Note")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue, in: Capsule())
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground))
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
                Text("Original Text:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(issue.originalText)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(issue.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            
            // Suggestion pills
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestions:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if issue.suggestions.isEmpty {
                    Text("Review this section manually")
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
            if let start = AttributedString.Index(range.lowerBound, within: attrStr),
               let end = AttributedString.Index(range.upperBound, within: attrStr) {
                let attributedRange = start..<end
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
        let textState = correctedText
        
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
            
            if ignoredWords.contains(misspelledWord.lowercased()) { continue }
            
            let rawGuesses = checker.guesses(forWordRange: misspellingRange, in: textState, language: "en") ?? []
            let topGuesses = Array(rawGuesses.prefix(5))
            
            newIssues.append(AssistantIssue(
                type: .spelling,
                originalText: misspelledWord,
                suggestions: topGuesses,
                description: "Spelling Error",
                explanation: "Verify spelling or add this word to your personal dictionary.",
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
                            description: "Contraction Error",
                            explanation: "Missing apostrophe. Contractions require punctuation to link root words.",
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
                            description: "Spacing Issue",
                            explanation: "Add a space after punctuation marks to follow standard English readability formats.",
                            range: match.range
                        ))
                    }
                }
            }
        }
        
        // 4. NLP Proper Noun Capitalization Check
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = textState
        let tagOptions: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        
        tagger.enumerateTags(in: textState.startIndex..<textState.endIndex, unit: .word, scheme: .nameType, options: tagOptions) { tag, tokenRange in
            if tag != nil {
                let matchedWord = String(textState[tokenRange])
                if let firstChar = matchedWord.first, firstChar.isLowercase {
                    let capitalized = matchedWord.prefix(1).uppercased() + matchedWord.dropFirst()
                    let nsRange = NSRange(tokenRange, in: textState)
                    
                    if !newIssues.contains(where: { $0.range.intersection(nsRange) != nil }) {
                        newIssues.append(AssistantIssue(
                            type: .grammar,
                            originalText: matchedWord,
                            suggestions: [capitalized],
                            description: "Capitalization Error",
                            explanation: "Proper nouns (geographical sites, names, and organizations) must start with a capital letter.",
                            range: nsRange
                        ))
                    }
                }
            }
            return true
        }
        
        // 5. Duplicate adjacent word finder (e.g., "the the")
        let duplicateWordPattern = "\\b([a-zA-Z]+)\\s+\\1\\b"
        if let dupRegex = try? NSRegularExpression(pattern: duplicateWordPattern, options: [.caseInsensitive]) {
            let nsText = textState as NSString
            let range = NSRange(location: 0, length: nsText.length)
            let matches = dupRegex.matches(in: textState, options: [], range: range)
            for match in matches {
                let matchedSegment = nsText.substring(with: match.range)
                let singleWord = matchedSegment.components(separatedBy: .whitespacesAndNewlines).first ?? ""
                if !newIssues.contains(where: { $0.range.intersection(match.range) != nil }) {
                    newIssues.append(AssistantIssue(
                        type: .grammar,
                        originalText: matchedSegment,
                        suggestions: [singleWord],
                        description: "Duplicate Word",
                        explanation: "Duplicate adjacent words detected. Remove one word to resolve redundancy.",
                        range: match.range
                    ))
                }
            }
        }
        
        // 6. Common phrasing & grammatical errors
        let phrasingMap = [
            "could of": "could have",
            "should of": "should have",
            "would of": "would have",
            "alot": "a lot",
            "everyday": "every day",
            "their is": "there is",
            "their are": "there are",
            "point of view": "perspective"
        ]
        
        for (wrong, right) in phrasingMap {
            let regexStr = "\\b\(wrong)\\b"
            if let regex = try? NSRegularExpression(pattern: regexStr, options: [.caseInsensitive]) {
                let nsText = textState as NSString
                let range = NSRange(location: 0, length: nsText.length)
                let matches = regex.matches(in: textState, options: [], range: range)
                for match in matches {
                    let matchedPhrase = nsText.substring(with: match.range)
                    if !newIssues.contains(where: { $0.range.intersection(match.range) != nil }) {
                        newIssues.append(AssistantIssue(
                            type: .grammar,
                            originalText: matchedPhrase,
                            suggestions: [right],
                            description: "Grammar / Phrasing",
                            explanation: "Avoid acoustic homophone errors. Use correct helper verbs or spacing.",
                            range: match.range
                        ))
                    }
                }
            }
        }
        
        // 7. Passive Voice Informational Warning
        let passivePattern = "\\b(am|is|are|was|were|be|been|being)\\s+([a-zA-Z]+(ed|en|t))\\b"
        if let passiveRegex = try? NSRegularExpression(pattern: passivePattern, options: [.caseInsensitive]) {
            let nsText = textState as NSString
            let range = NSRange(location: 0, length: nsText.length)
            let matches = passiveRegex.matches(in: textState, options: [], range: range)
            for match in matches {
                let matchedPhrase = nsText.substring(with: match.range)
                if !newIssues.contains(where: { $0.range.intersection(match.range) != nil }) {
                    newIssues.append(AssistantIssue(
                        type: .grammar,
                        originalText: matchedPhrase,
                        suggestions: [], // Informational warning, no direct replacements
                        description: "Passive Voice",
                        explanation: "Passive voice detected. Consider rewriting in active voice to make your writing more direct.",
                        range: match.range
                    ))
                }
            }
        }
        
        self.issues = newIssues.sorted { $0.range.location < $1.range.location }
        
        if currentIssueIndex >= issues.count {
            currentIssueIndex = max(0, issues.count - 1)
        }
    }
    
    // MARK: - Actions & Stats Helpers
    
    private func applySuggestion(_ issue: AssistantIssue, replacement: String) {
        let nsString = correctedText as NSString
        guard issue.range.location + issue.range.length <= nsString.length else { return }
        
        let newText = nsString.replacingCharacters(in: issue.range, with: replacement)
        correctedText = newText
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
    
    private func countSyllables(in word: String) -> Int {
        let lowercaseWord = word.lowercased()
        let vowels = CharacterSet(charactersIn: "aeiouy")
        var count = 0
        var lastWasVowel = false
        
        for char in lowercaseWord {
            let isVowel = char.unicodeScalars.first.map { vowels.contains($0) } ?? false
            if isVowel {
                if !lastWasVowel { count += 1 }
                lastWasVowel = true
            } else {
                lastWasVowel = false
            }
        }
        
        if lowercaseWord.hasSuffix("e") { count -= 1 }
        if lowercaseWord.hasSuffix("es") || lowercaseWord.hasSuffix("ed") { count -= 1 }
        return max(1, count)
    }
    
    private var computedStats: WritingStats {
        let textState = correctedText
        let sentences = textState.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let words = textState.split { $0.isWhitespace || $0.isNewline || $0.isPunctuation }.map(String.init)
        
        var totalSyllables = 0
        for word in words {
            totalSyllables += countSyllables(in: word)
        }
        
        let passivePattern = "\\b(am|is|are|was|were|be|been|being)\\s+([a-zA-Z]+(ed|en|t))\\b"
        var passiveCount = 0
        if let regex = try? NSRegularExpression(pattern: passivePattern, options: [.caseInsensitive]) {
            let nsText = textState as NSString
            let range = NSRange(location: 0, length: nsText.length)
            passiveCount = regex.numberOfMatches(in: textState, options: [], range: range)
        }
        
        return WritingStats(
            wordCount: max(1, words.count),
            sentenceCount: max(1, sentences.count),
            syllableCount: totalSyllables,
            passiveVoiceCount: passiveCount
        )
    }
}

// MARK: - Circular Metric View Helper
struct CircularMetricView: View {
    let value: Double
    let label: String
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 4)
                .frame(width: 44, height: 44)
            Circle()
                .trim(from: 0.0, to: CGFloat(value / 100.0))
                .stroke(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 44, height: 44)
                .rotationEffect(Angle(degrees: -90))
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
    }
}
