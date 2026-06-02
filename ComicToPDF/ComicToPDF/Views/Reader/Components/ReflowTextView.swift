import SwiftUI
import UIKit

struct ReflowTextView: UIViewRepresentable {
    let text: String
    @ObservedObject var prefs = EBookPreferences.shared
    
    var onCenterTap: () -> Void
    var onPrevPage: () -> Void
    var onNextPage: () -> Void
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = true
        
        // Add single tap gesture for page turn and chrome toggling
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        textView.addGestureRecognizer(tapGesture)
        
        // Add horizontal swipe gestures for page turns
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeLeft(_:)))
        swipeLeft.direction = .left
        textView.addGestureRecognizer(swipeLeft)
        
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeRight(_:)))
        swipeRight.direction = .right
        textView.addGestureRecognizer(swipeRight)
        
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        
        let theme = prefs.activeTheme
        uiView.backgroundColor = UIColor(theme.background)
        uiView.textColor = UIColor(theme.text)
        
        // Resolve custom fonts from EBookFontFamily
        let fontSize = CGFloat(prefs.fontSize)
        var uiFont: UIFont = .systemFont(ofSize: fontSize)
        if let family = EBookFontFamily(rawValue: prefs.fontFamily) {
            switch family {
            case .newYork:
                uiFont = UIFont(name: "NewYorkSmall-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
            case .georgia:
                uiFont = UIFont(name: "Georgia", size: fontSize) ?? .systemFont(ofSize: fontSize)
            case .athelas:
                uiFont = UIFont(name: "Athelas-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
            case .literata:
                uiFont = UIFont(name: "Literata-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
            case .merriweather:
                uiFont = UIFont(name: "Merriweather-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
            case .sourceSerif:
                uiFont = UIFont(name: "SourceSerif4-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
            case .helvetica:
                uiFont = UIFont.systemFont(ofSize: fontSize)
            case .openDyslexic:
                uiFont = UIFont(name: "OpenDyslexic-Regular", size: fontSize - 1) ?? .systemFont(ofSize: fontSize - 1)
            case .atkinson:
                uiFont = UIFont(name: "AtkinsonHyperlegible-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
            }
        }
        
        let paragraphStyle = NSMutableParagraphStyle()
        // Line spacing is the extra distance between line heights
        paragraphStyle.lineSpacing = CGFloat((prefs.lineHeight - 1.0) * prefs.fontSize)
        paragraphStyle.alignment = prefs.textAlign == "justify" ? .justified : .left
        paragraphStyle.paragraphSpacing = CGFloat(prefs.paragraphSpacing * prefs.fontSize)
        paragraphStyle.firstLineHeadIndent = CGFloat(prefs.paragraphIndent * prefs.fontSize)
        
        var attributes: [NSAttributedString.Key: Any] = [
            .font: uiFont,
            .foregroundColor: UIColor(theme.text),
            .paragraphStyle: paragraphStyle
        ]
        
        // Letter spacing (tracking) in UIKit is represented by kern (points)
        if prefs.letterSpacing != 0.0 {
            attributes[.kern] = CGFloat(prefs.letterSpacing * prefs.fontSize)
        }
        
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        uiView.attributedText = attributedString
        
        // Apply text margins. Add extra top/bottom buffer so header/footer bars don't overlap text.
        let margin = CGFloat(prefs.textMargin)
        uiView.textContainerInset = UIEdgeInsets(top: margin + 40, left: margin, bottom: margin + 80, right: margin)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: ReflowTextView
        
        init(_ parent: ReflowTextView) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            
            // Do not trigger page turn or chrome if the user is actively selecting text
            if textView.selectedRange.length > 0 {
                return
            }
            
            let point = gesture.location(in: textView)
            let width = textView.bounds.width
            
            // Left 20% of the screen turns to the previous page
            if point.x < width * 0.20 {
                parent.onPrevPage()
            }
            // Right 20% of the screen turns to the next page
            else if point.x > width * 0.80 {
                parent.onNextPage()
            }
            // Center 60% of the screen toggles the reader chrome
            else {
                parent.onCenterTap()
            }
        }
        
        @objc func handleSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
            parent.onNextPage()
        }
        
        @objc func handleSwipeRight(_ gesture: UISwipeGestureRecognizer) {
            parent.onPrevPage()
        }
    }
}
