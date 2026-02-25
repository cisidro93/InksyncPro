import Foundation

let jsonString = """
{
  "0": [
    {
      "boundingBox": [0.1, 0.2, 0.3, 0.4]
    }
  ]
}
"""

struct Panel: Codable {
    let boundingBox: [Double]
}

do {
    let data = jsonString.data(using: .utf8)!
    let decoded = try JSONDecoder().decode([Int: [Panel]].self, from: data)
    print("Decoded Panels: \(decoded)")
} catch {
    print("Decoding Error: \(error)")
}
