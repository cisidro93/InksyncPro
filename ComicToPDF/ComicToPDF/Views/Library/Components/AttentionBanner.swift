import SwiftUI

struct AttentionBanner: View {
    let pdf: ConvertedPDF
    let onAction: (LibrarySheetDestination) -> Void

    var message: String {
        if pdf.lastTransferFailed { return "Transfer failed — tap to retry" }
        if (pdf.panelConfidenceScore ?? 1.0) < 0.75 { return "Panel review suggested" }
        return "Needs attention"
    }

    var action: LibrarySheetDestination {
        if pdf.lastTransferFailed { return .completionSend(pdf) }
        return .details(pdf)
    }

    var body: some View {
        Button(action: { onAction(action) }) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.inkAmber)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text(pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.inkTextPrimary)
                        .lineLimit(1)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.inkAmber)
                }

                Spacer()

                Text("Fix →")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.inkAmber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.inkAmber.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.inkAmber.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.inkAmber.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
