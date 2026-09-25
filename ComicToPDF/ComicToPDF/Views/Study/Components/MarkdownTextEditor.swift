import SwiftUI
import UIKit

// MARK: - Dedicated UITextView subclass supporting native long-press paste and action validation
final class InksyncMarkdownTextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }
    
    override func paste(_ sender: Any?) {
        if let string = UIPasteboard.general.string {
            insertText(string)
            NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: self)
            delegate?.textViewDidChange?(self)
        } else {
            super.paste(sender)
        }
    }
}

// MARK: - Phase 2: Modern Markdown Engine WYSIWYG
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let paperStyle: PaperStyle
    var onLinkTapped: ((URL) -> Void)? = nil
    
    init(
        text: Binding<String>,
        isFocused: Binding<Bool>,
        paperStyle: PaperStyle,
        onLinkTapped: ((URL) -> Void)? = nil
    ) {
        self._text = text
        self._isFocused = isFocused
        self.paperStyle = paperStyle
        self.onLinkTapped = onLinkTapped
    }
    
    func makeUIView(context: Context) -> UITextView {
        let textView = InksyncMarkdownTextView()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = UIColor.label
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.linkTextAttributes = [:] // Style links completely via MarkdownHighlighter attributes
        
        // Dynamically set container inset based on active paper style
        updateTextViewPadding(textView, style: paperStyle)

        // Add Tap Gesture Recognizer to intercept page link clicks without disrupting text insertion cursor focus or native edit menu
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        tapGesture.cancelsTouchesInView = false
        textView.addGestureRecognizer(tapGesture)

        // MARK: Formatting Shortcut Bar — Phase 4E-2 expanded (Bear/Notability pattern)
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48),
                              inputViewStyle: .keyboard)
        let blurEffect = UIBlurEffect(style: .systemChromeMaterial)
        let blurView  = UIVisualEffectView(effect: blurEffect)
        blurView.frame = bar.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.addSubview(blurView)

        let items: [(title: String, insert: String, after: String?)] = [
            ("B",       "**",     "**"),
            ("I",       "_",      "_"),
            ("H1",      "# ",     nil),
            ("H2",      "## ",    nil),
            ("≡ List",  "- ",     nil),
            ("☑ Todo",  "- [ ] ", nil),
            ("`Code`",  "`",      "`"),
            ("📍 Stamp", " [📍 Page] ", nil),
            ("—— Rule", "---\n",  nil),
            ("[[",      "[[",     "]]"),
            ("#",       "#",      nil),
            ("> Quote", "> ",     nil),
        ]

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 📋 1-Tap Paste Button directly on keyboard accessory bar
        let pasteBtn = UIButton(type: .system)
        pasteBtn.backgroundColor = UIColor.secondarySystemFill
        pasteBtn.layer.cornerRadius = 6
        var pasteConfig = UIButton.Configuration.plain()
        pasteConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        pasteConfig.baseForegroundColor = .label
        pasteConfig.attributedTitle = AttributedString("📋 Paste", attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
        ]))
        pasteBtn.configuration = pasteConfig
        pasteBtn.addTarget(context.coordinator, action: #selector(Coordinator.pasteButtonTapped), for: .touchUpInside)
        stack.addArrangedSubview(pasteBtn)

        for item in items {
            let btn = FormatButton(title: item.title, insertBefore: item.insert, insertAfter: item.after, textView: textView)
            stack.addArrangedSubview(btn)
        }

        let micBtn = UIButton(type: .system)
        micBtn.tag = 999
        let isRecording = SpeechRecognitionManager.shared.isRecording
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let micImage = UIImage(systemName: isRecording ? "mic.fill" : "mic", withConfiguration: config)
        micBtn.setImage(micImage, for: .normal)
        micBtn.tintColor = isRecording ? .systemRed : .label
        micBtn.backgroundColor = UIColor.secondarySystemFill
        micBtn.layer.cornerRadius = 6
        micBtn.addTarget(context.coordinator, action: #selector(Coordinator.micButtonTapped), for: .touchUpInside)
        stack.addArrangedSubview(micBtn)
        micBtn.widthAnchor.constraint(equalToConstant: 36).isActive = true
        micBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("Done", for: .normal)
        doneBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        doneBtn.addTarget(context.coordinator, action: #selector(Coordinator.doneButtonTapped), for: .touchUpInside)
        stack.addArrangedSubview(doneBtn)

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
        textView.inputAccessoryView = bar

        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        updateTextViewPadding(uiView, style: paperStyle)
        
        if uiView.text != text {
            let selectedRange = uiView.selectedRange
            uiView.attributedText = MarkdownHighlighter.highlight(text, style: paperStyle)
            uiView.selectedRange = selectedRange
        }
        
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        
        if let bar = uiView.inputAccessoryView {
            if let micBtn = bar.viewWithTag(999) as? UIButton {
                let isRecording = SpeechRecognitionManager.shared.isRecording
                let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                let micImage = UIImage(systemName: isRecording ? "mic.fill" : "mic", withConfiguration: config)
                micBtn.setImage(micImage, for: .normal)
                micBtn.tintColor = isRecording ? .systemRed : .label
            }
        }
        
        context.coordinator.updatePageBreaks(for: uiView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func updateTextViewPadding(_ textView: UITextView, style: PaperStyle) {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let topInset: CGFloat
        let leftInset: CGFloat
        let rightInset: CGFloat = isPhone ? 12 : 20
        let bottomInset: CGFloat = 20
        
        switch style {
        case .legal:
            topInset = isPhone ? 32 : 56
            leftInset = isPhone ? 48 : 100
        case .collegeRuled:
            topInset = isPhone ? 36 : 63
            leftInset = isPhone ? 42 : 84
        case .ruled:
            topInset = isPhone ? 28 : 48
            leftInset = isPhone ? 42 : 84
        default:
            topInset = 16
            leftInset = isPhone ? 12 : 20
        }
        
        textView.textContainerInset = UIEdgeInsets(top: topInset, left: leftInset, bottom: bottomInset, right: rightInset)
    }

    @MainActor
    class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: MarkdownTextEditor
        weak var textView: UITextView?
        nonisolated(unsafe) private var dictationObserver: NSObjectProtocol?
        
        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
            super.init()
            
            dictationObserver = NotificationCenter.default.addObserver(
                forName: .insertDictatedText,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let textToInsert = notification.userInfo?["text"] as? String
                Task { @MainActor in
                    guard let self = self,
                          self.textView != nil,
                          let textToInsert = textToInsert else { return }
                    
                    self.insertText(textToInsert)
                }
            }
        }
        
        deinit {
            if let observer = dictationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        @objc func micButtonTapped() {
            let manager = SpeechRecognitionManager.shared
            if manager.isRecording {
                manager.stopDictation(commit: true)
            } else {
                Task {
                    let granted = await manager.requestPermissions()
                    if granted {
                        do {
                            try manager.startDictation()
                        } catch {
                            Logger.shared.log("Failed to start dictation: \(error.localizedDescription)", category: "STT", type: .error)
                        }
                    }
                }
            }
        }
        
        private func insertText(_ newText: String) {
            guard let tv = textView else { return }
            let selectedRange = tv.selectedRange
            let originalText = tv.text ?? ""
            
            let insertionText: String
            if selectedRange.location > 0 {
                let prevIndex = originalText.index(originalText.startIndex, offsetBy: selectedRange.location - 1)
                let prevChar = originalText[prevIndex]
                if !prevChar.isWhitespace && !prevChar.isNewline {
                    insertionText = " " + newText
                } else {
                    insertionText = newText
                }
            } else {
                insertionText = newText
            }
            
            tv.insertText(insertionText)
            parent.text = tv.text
            
            let newSelectedRange = tv.selectedRange
            tv.attributedText = MarkdownHighlighter.highlight(tv.text, style: parent.paperStyle)
            tv.selectedRange = newSelectedRange
        }
        
        func updatePageBreaks(for textView: UITextView) {
            // Remove existing page breaks
            textView.subviews.filter { $0.tag == 999 }.forEach { $0.removeFromSuperview() }
            
            let pageHeight: CGFloat = 1100
            let padding: CGFloat = 16
            let width = textView.bounds.width > 0 ? textView.bounds.width : UIScreen.main.bounds.width
            let contentHeight = textView.contentSize.height
            
            var y: CGFloat = pageHeight
            var pageIndex = 1
            while y < contentHeight - 100 {
                let container = UIView(frame: CGRect(x: 0, y: y, width: width, height: 20))
                container.tag = 999
                container.isUserInteractionEnabled = false
                container.backgroundColor = .clear
                
                // Horizontal dashed line
                let lineWidth = max(50, width - 96 - (padding * 2))
                let line = UIView(frame: CGRect(x: padding, y: 10, width: lineWidth, height: 1))
                line.backgroundColor = .clear
                
                // Add a CAShapeLayer for a clean dashed stroke style matching theme
                let shapeLayer = CAShapeLayer()
                shapeLayer.strokeColor = UIColor.separator.withAlphaComponent(0.2).cgColor
                shapeLayer.lineWidth = 1.0
                shapeLayer.lineDashPattern = [6, 4]
                
                let path = CGMutablePath()
                path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: lineWidth, y: 0)])
                shapeLayer.path = path
                line.layer.addSublayer(shapeLayer)
                container.addSubview(line)
                
                // Page Label
                let label = UILabel(frame: CGRect(x: width - 80 - padding, y: 0, width: 80, height: 20))
                label.text = "Page \(pageIndex)"
                label.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
                label.textColor = UIColor.secondaryLabel.withAlphaComponent(0.4)
                label.textAlignment = .right
                container.addSubview(label)
                
                textView.addSubview(container)
                
                y += pageHeight
                pageIndex += 1
            }
        }
        
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            let selectedRange = textView.selectedRange
            textView.attributedText = MarkdownHighlighter.highlight(textView.text, style: parent.paperStyle)
            textView.selectedRange = selectedRange
            updatePageBreaks(for: textView)
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
        
        @objc func doneButtonTapped() {
            parent.isFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        @objc func pasteButtonTapped() {
            guard let tv = textView, let string = UIPasteboard.general.string, !string.isEmpty else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            tv.insertText(string)
            parent.text = tv.text
            let newSelectedRange = tv.selectedRange
            tv.attributedText = MarkdownHighlighter.highlight(tv.text, style: parent.paperStyle)
            tv.selectedRange = newSelectedRange
            updatePageBreaks(for: tv)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView = textView else { return false }
            let point = touch.location(in: textView)
            
            var location = point
            location.x -= textView.textContainerInset.left
            location.y -= textView.textContainerInset.top
            
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            
            var fraction: CGFloat = 0.0
            let charIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
            
            guard charIndex < textView.textStorage.length else { return false }
            
            if let url = textView.textStorage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL {
                if url.scheme == "inksync" {
                    let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                    let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
                    let touchTargetRect = glyphRect.insetBy(dx: -5, dy: -5)
                    if touchTargetRect.contains(location) {
                        return true
                    }
                }
            }
            return false
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = textView, gesture.state == .ended else { return }
            let point = gesture.location(in: textView)
            
            var location = point
            location.x -= textView.textContainerInset.left
            location.y -= textView.textContainerInset.top
            
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            
            var fraction: CGFloat = 0.0
            let charIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
            
            if charIndex < textView.textStorage.length {
                if let url = textView.textStorage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL {
                    if url.scheme == "inksync" || url.scheme == "page" {
                        parent.onLinkTapped?(url)
                    }
                }
            }
        }

        #if compiler(>=5.9)
        @available(iOS 17.0, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                if url.scheme == "inksync" || url.scheme == "page" {
                    return UIAction { [weak self] _ in
                        self?.parent.onLinkTapped?(url)
                    }
                }
            }
            return defaultAction
        }
        #endif

        @available(iOS, deprecated: 17.0)
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if URL.scheme == "inksync" || URL.scheme == "page" {
                parent.onLinkTapped?(URL)
                return false
            }
            return true
        }
    }
}

// MARK: - Formatting Button (Bear-style — inserts markdown syntax at cursor)
final class FormatButton: UIButton {
    let insertBefore: String
    let insertAfter: String?
    weak var textView: UITextView?

    init(title: String, insertBefore: String, insertAfter: String?, textView: UITextView) {
        self.insertBefore = insertBefore
        self.insertAfter  = insertAfter
        self.textView = textView
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.baseForegroundColor = .label
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
        ]))
        self.configuration = config
        self.backgroundColor = UIColor.secondarySystemFill
        self.layer.cornerRadius = 6
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        guard let tv = textView,
              let selectedRange = tv.selectedTextRange else { return }

        let selectedText = tv.text(in: selectedRange) ?? ""

        let replacement: String
        if let after = insertAfter {
            replacement = insertBefore + selectedText + after
        } else {
            replacement = insertBefore + selectedText
        }
        tv.replace(selectedRange, withText: replacement)

        if selectedText.isEmpty, let after = insertAfter {
            let offset = insertBefore.count
            if let startPos = tv.position(from: selectedRange.start, offset: offset) {
                tv.selectedTextRange = tv.textRange(from: startPos, to: startPos)
            }
            _ = after
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Markdown Syntax Highlighter
struct MarkdownHighlighter {
    static func highlight(_ text: String, style: PaperStyle) -> NSAttributedString {
        let baseSize: CGFloat
        let lineSpacingVal: CGFloat
        let lineSpacingTarget: CGFloat
        
        switch style {
        case .legal:
            baseSize = 18
            lineSpacingTarget = 28
        case .collegeRuled:
            baseSize = 14
            lineSpacingTarget = 21
        case .ruled:
            baseSize = 16
            lineSpacingTarget = 24
        default:
            baseSize = 16
            lineSpacingTarget = 22
        }
        
        let defaultFont = UIFont.systemFont(ofSize: baseSize)
        let boldFont = UIFont.boldSystemFont(ofSize: baseSize)
        let italicFont = UIFont.italicSystemFont(ofSize: baseSize)
        let h1Font = UIFont.boldSystemFont(ofSize: baseSize + 8)
        let h2Font = UIFont.boldSystemFont(ofSize: baseSize + 4)
        let h3Font = UIFont.boldSystemFont(ofSize: baseSize + 2)
        let defaultColor = UIColor.label
        let markerColor = UIColor.secondaryLabel.withAlphaComponent(0.35)
        
        // Calculate dynamic lineSpacing to make lines align perfectly with the paper rule grid
        let fontLineHeight = defaultFont.lineHeight
        lineSpacingVal = max(0, lineSpacingTarget - fontLineHeight)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacingVal
        paragraphStyle.paragraphSpacing = style == .plain ? 12 : 0

        let attrString = NSMutableAttributedString(string: text, attributes: [
            .font: defaultFont,
            .foregroundColor: defaultColor,
            .paragraphStyle: paragraphStyle
        ])
        
        let fullRange = NSRange(text.startIndex..., in: text)
        
        // Blockquotes (> text)
        let quotePattern = "(?m)^(\\s*>\\s*)(.*)"
        if let regex = try? NSRegularExpression(pattern: quotePattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: UIColor.systemOrange.withAlphaComponent(0.6), range: markerRange)
                    attrString.addAttributes([
                        .foregroundColor: UIColor.systemGray,
                        .font: italicFont
                    ], range: textRange)
                }
            }
        }
        
        // Bold (**text**)
        let boldPattern = "(\\*\\*)(.*?)(\\*\\*)"
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                if match.numberOfRanges > 3 {
                    let startMarker = match.range(at: 1)
                    let innerText = match.range(at: 2)
                    let endMarker = match.range(at: 3)
                    
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: startMarker)
                    attrString.addAttribute(.font, value: boldFont, range: innerText)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: endMarker)
                }
            }
        }
        
        // Italic (_text_)
        let italicPattern = "(\\_)(.*?)(\\_)"
        if let regex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                if match.numberOfRanges > 3 {
                    let startMarker = match.range(at: 1)
                    let innerText = match.range(at: 2)
                    let endMarker = match.range(at: 3)
                    
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: startMarker)
                    attrString.addAttribute(.font, value: italicFont, range: innerText)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: endMarker)
                }
            }
        }
        
        // WikiLink ([[text]])
        let linkPattern = "\\[\\[(.*?)\\]\\]"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            let nsText = text as NSString
            for match in matches {
                attrString.addAttributes([
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: match.range)
                
                if match.numberOfRanges > 1 {
                    let innerRange = match.range(at: 1)
                    let innerText = nsText.substring(with: innerRange)
                    
                    let pageRegexPattern = "^(?:[Pp]age|[Pp]g|[Pp]\\.?)?\\s*(\\d+)$"
                    if let pageRegex = try? NSRegularExpression(pattern: pageRegexPattern, options: []),
                       let pageMatch = pageRegex.firstMatch(in: innerText, options: [], range: NSRange(innerText.startIndex..., in: innerText)) {
                        if pageMatch.numberOfRanges > 1 {
                            let pageNumRange = pageMatch.range(at: 1)
                            if let pageNumRangeInString = Range(pageNumRange, in: innerText),
                               let pageNum = Int(innerText[pageNumRangeInString]),
                               pageNum > 0 {
                                let pageIndex = pageNum - 1
                                if let url = URL(string: "inksync://page/\(pageIndex)") {
                                    attrString.addAttribute(.link, value: url, range: match.range)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Markdown Links ([label](url))
        let mdLinkPattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: mdLinkPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            let nsText = text as NSString
            for match in matches {
                if match.numberOfRanges > 2 {
                    let urlStr = nsText.substring(with: match.range(at: 2))
                    if let url = URL(string: urlStr) {
                        attrString.addAttributes([
                            .foregroundColor: UIColor.systemOrange,
                            .font: boldFont,
                            .link: url
                        ], range: match.range)
                    }
                }
            }
        }
        
        // Tags (#tag)
        let tagPattern = "(?<!\\w)#\\w+"
        if let regex = try? NSRegularExpression(pattern: tagPattern, options: []) {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                attrString.addAttributes([
                    .foregroundColor: UIColor.systemOrange,
                    .font: boldFont
                ], range: match.range)
            }
        }
        
        // Headers (# H1, ## H2, ### H3)
        let h1Pattern = "(?m)^(#\\s+)(.*)"
        let h2Pattern = "(?m)^(##\\s+)(.*)"
        let h3Pattern = "(?m)^(###\\s+)(.*)"
        
        if let r1 = try? NSRegularExpression(pattern: h1Pattern) {
            for match in r1.matches(in: text, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                    attrString.addAttribute(.font, value: h1Font, range: textRange)
                }
            }
        }
        if let r2 = try? NSRegularExpression(pattern: h2Pattern) {
            for match in r2.matches(in: text, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                    attrString.addAttribute(.font, value: h2Font, range: textRange)
                }
            }
        }
        if let r3 = try? NSRegularExpression(pattern: h3Pattern) {
            for match in r3.matches(in: text, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let markerRange = match.range(at: 1)
                    let textRange = match.range(at: 2)
                    attrString.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                    attrString.addAttribute(.font, value: h3Font, range: textRange)
                }
            }
        }
        
        return attrString
    }
}
