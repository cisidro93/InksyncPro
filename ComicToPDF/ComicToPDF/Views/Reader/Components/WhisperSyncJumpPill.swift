//
//  WhisperSyncJumpPill.swift
//  InksyncPro
//
//  Non-disruptive floating WhisperSync continuity indicator (Pillar 1).
//  Appears gracefully when another Apple device has read ahead in iCloud.
//  Respects reader autonomy: offers [Jump] and [Stay] without jarring auto-scrolls.
//

import SwiftUI

public struct WhisperSyncJumpPill: View {
    let proposal: WhisperSyncProposal
    let onJump: (Int) -> Void
    let onDismiss: () -> Void

    public init(
        proposal: WhisperSyncProposal,
        onJump: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.proposal = proposal
        self.onJump = onJump
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.cyan)
                .symbolEffect(.pulse, options: .repeating.speed(0.8))

            VStack(alignment: .leading, spacing: 2) {
                Text("Further along on other device")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkTextSecondary)
                Text("Page \(proposal.remotePageIndex + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkTextPrimary)
            }

            Spacer(minLength: 6)

            Button(action: {
                HapticEngine.medium()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    onJump(proposal.remotePageIndex)
                }
            }) {
                Text("Jump")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Color.blue.opacity(0.35), radius: 4, y: 2)
            }

            Button(action: {
                HapticEngine.light()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    onDismiss()
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkTextTertiary)
                    .padding(6)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 20)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        ))
        .onAppear {
            // Auto-dismiss after 14 seconds of inactivity if the user chooses to ignore
            Task {
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                await MainActor.run {
                    withAnimation {
                        onDismiss()
                    }
                }
            }
        }
    }
}
