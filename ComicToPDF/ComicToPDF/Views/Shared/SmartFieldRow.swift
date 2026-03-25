import SwiftUI

struct SmartFieldRow: View {
    let label: String
    let value: String
    let confirmed: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
                Text(value)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.inkTextPrimary)
            }
            Spacer()
            if confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.inkGreen)
                    .font(.system(size: 14))
            }
        }
        .padding(12)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
