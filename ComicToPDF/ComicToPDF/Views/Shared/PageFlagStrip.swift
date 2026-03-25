import SwiftUI

struct PageFlagStrip: View {
    let flaggedIndices: [Int]
    let totalPages: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pages")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
                Spacer()
                if !flaggedIndices.isEmpty {
                    Text("\(flaggedIndices.count) flagged")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.inkAmber)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(0..<min(totalPages, 20), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(flaggedIndices.contains(i)
                                ? Color.inkAmber.opacity(0.25)
                                : Color.inkSurfaceRaised)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(flaggedIndices.contains(i)
                                        ? Color.inkAmber
                                        : Color.inkBorderSubtle,
                                        lineWidth: flaggedIndices.contains(i) ? 1.5 : 0.5)
                            )
                            .frame(width: 34, height: 48)
                    }
                    if totalPages > 20 {
                        Text("+\(totalPages - 20) more")
                            .font(.system(size: 10))
                            .foregroundColor(.inkTextTertiary)
                            .padding(.leading, 4)
                    }
                }
            }

            Text("Tap a highlighted page to review · or skip to use auto-detected panels")
                .font(.system(size: 10))
                .foregroundColor(.inkTextTertiary)
        }
    }
}
