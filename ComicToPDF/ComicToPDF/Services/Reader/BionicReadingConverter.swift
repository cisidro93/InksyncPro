import Foundation

public final class BionicReadingConverter: @unchecked Sendable {
    public static let shared = BionicReadingConverter()
    private init() {}

    /// Bionifies a text string by wrapping the leading fixation characters of each word in <b>...</b>
    public func bionifyHTML(_ html: String) -> String {
        guard !html.isEmpty else { return html }

        let pattern = "\\b([a-zA-Z0-9'\u{00C0}-\u{024F}]+)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return html }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        var result = ""
        var lastLocation = 0

        for match in matches {
            let range = match.range
            if range.location > lastLocation {
                result += nsString.substring(with: NSRange(location: lastLocation, length: range.location - lastLocation))
            }

            let word = nsString.substring(with: range)
            let length = word.count

            let fixLen: Int
            if length <= 3 {
                fixLen = 1
            } else if length <= 6 {
                fixLen = 2
            } else if length <= 9 {
                fixLen = 3
            } else {
                fixLen = Int(ceil(Double(length) * 0.4))
            }

            let prefix = String(word.prefix(fixLen))
            let suffix = String(word.dropFirst(fixLen))
            result += "<b>\(prefix)</b>\(suffix)"

            lastLocation = range.location + range.length
        }

        if lastLocation < nsString.length {
            result += nsString.substring(from: lastLocation)
        }

        return result
    }
}
