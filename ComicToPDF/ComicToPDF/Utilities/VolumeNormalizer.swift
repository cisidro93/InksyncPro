import Foundation

/// Canonical volume normalization and natural numeric comparator to prevent duplicate
/// volume buckets (e.g. "Vol. 9" vs "Vol. 09") and resolve UI positioning jitter.
public enum VolumeNormalizer: Sendable {
    
    /// Normalizes a raw volume string into its canonical representation.
    /// - Pure integers (e.g. "09", "9", "007", "v08", "Vol. 09") normalize to unpadded integer strings ("9", "7", "8").
    /// - Decimal numbers (e.g. "9.5", "v09.5") normalize to canonical decimal ("9.5").
    /// - Special or alphanumeric volumes (e.g. "Special", "Bonus", "Side Story") retain their clean trimmed text.
    /// - "Ungrouped", empty, or whitespace strings are handled cleanly.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if trimmed.caseInsensitiveCompare("ungrouped") == .orderedSame {
            return "Ungrouped"
        }
        
        // Strip common volume prefixes: "volume", "vol.", "vol", "v.", "v", "#"
        var cleaned = trimmed
        if let prefixRange = cleaned.range(of: #"^(?i)(?:vol(?:ume)?\.?|v\.?|#)\s*"#, options: .regularExpression) {
            cleaned = String(cleaned[prefixRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        guard !cleaned.isEmpty else { return trimmed }
        
        // If it parses as a pure non-negative integer, strip leading zeroes (e.g., "09" -> "9", "08" -> "8")
        if let intVal = Int(cleaned), intVal >= 0 {
            return "\(intVal)"
        }
        
        // If it parses as a decimal number (e.g. "09.5" -> "9.5")
        if let dblVal = Double(cleaned), dblVal >= 0 {
            if floor(dblVal) == dblVal {
                return "\(Int(dblVal))"
            }
            return "\(dblVal)"
        }
        
        return cleaned
    }
    
    /// Returns a human-friendly display label (e.g., "Vol. 9" or "Ungrouped").
    public static func displayLabel(for volume: String) -> String {
        let norm = normalize(volume) ?? volume
        if norm.caseInsensitiveCompare("ungrouped") == .orderedSame {
            return "Ungrouped"
        }
        if norm.lowercased().hasPrefix("vol") {
            return norm
        }
        return "Vol. \(norm)"
    }
    
    /// Deterministic, stable natural sort comparator for volume keys.
    /// Guarantees strict ordering with a deterministic tie-breaker so items never swap places.
    public static func compare(_ a: String, _ b: String) -> Bool {
        if a.caseInsensitiveCompare("ungrouped") == .orderedSame { return false }
        if b.caseInsensitiveCompare("ungrouped") == .orderedSame { return true }
        
        let normA = normalize(a) ?? a
        let normB = normalize(b) ?? b
        
        let numA = Double(normA)
        let numB = Double(normB)
        
        if let na = numA, let nb = numB {
            if abs(na - nb) > 0.0001 {
                return na < nb
            }
        } else if numA != nil && numB == nil {
            return true
        } else if numA == nil && numB != nil {
            return false
        }
        
        // Strict, non-flapping tie-breaker
        return a.localizedStandardCompare(b) == .orderedAscending
    }
}
