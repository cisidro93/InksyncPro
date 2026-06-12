import SwiftUI

// MARK: - ReadingRoomOverlay
//
// Transparent overlay sitting at zIndex 15 inside ComicReaderEngine's ZStack.
// Contains three distinct sub-surfaces:
//
//  1. Peer scrubber avatars  — floating colour bubbles positioned along the
//                              progress fraction of each peer's current page.
//  2. Reaction bursts        — emoji particles that animate up from the
//                              bottom-centre of the screen using CAEmitterLayer.
//  3. Session HUD pill       — top-right frosted capsule (peer count).
//                              Tap → sheet (iPhone) / inline drawer (iPad).
//
// Design inspiration: Spotify's "Friends listening" bar + Apple SharePlay UI.

struct ReadingRoomOverlay: View {
    @ObservedObject var session: ReadingRoomSession

    /// Current reader's page — used to position the "you" indicator on the scrubber.
    let currentPage: Int
    let totalPages: Int

    /// Controls whether the full session drawer is open.
    @State private var showDrawer = false
    @State private var joinCodeEntry = ""
    @State private var showJoinSheet = false

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // ── 1. Peer avatars along scrubber bottom edge ────────────
                scrubberAvatars(geo: geo)

                // ── 2. Emoji reaction bursts ──────────────────────────────
                reactionBurstLayer(geo: geo)

                // ── 3. Session HUD pill (top-right) ──────────────────────
                hudPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 56)
                    .padding(.trailing, 14)
            }
        }
        // iPhone: drawer as bottom sheet
        .sheet(isPresented: $showDrawer) {
            drawerContent
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Peer Scrubber Avatars

    @ViewBuilder
    private func scrubberAvatars(geo: GeometryProxy) -> some View {
        // Avatars float 100pt above the bottom safe edge
        let baseline = geo.size.height - 100
        let scrubberStart: CGFloat = 16
        let scrubberEnd = geo.size.width - 16
        let scrubberWidth = scrubberEnd - scrubberStart

        ZStack {
            ForEach(session.peers) { peer in
                let x = scrubberStart + CGFloat(peer.progressFraction) * scrubberWidth
                PeerAvatarBubble(peer: peer)
                    .position(x: x, y: baseline)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: peer.progressFraction)
            }
        }
    }

    // MARK: - Emoji Reaction Bursts

    @ViewBuilder
    private func reactionBurstLayer(geo: GeometryProxy) -> some View {
        if !session.reactions.isEmpty {
            ZStack {
                ForEach(session.reactions) { reaction in
                    ReactionBurstView(reaction: reaction, geo: geo)
                }
            }
        }
    }

    // MARK: - Session HUD Pill

    private var hudPill: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showDrawer = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .symbolEffect(.pulse, isActive: session.isConnected)

                if !session.peers.isEmpty {
                    Text("\(session.peers.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(session.isConnected
                          ? LinearGradient(colors: [Color(hex: "#4ECDC4"), Color(hex: "#45B7D1")],
                                           startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [Color.white.opacity(0.25), Color.white.opacity(0.15)],
                                           startPoint: .leading, endPoint: .trailing))
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Session Drawer (iPhone sheet / iPad panel)

    private var drawerContent: some View {
        NavigationStack {
            List {
                roomCodeSection
                peerListSection
                reactionSection
                joinCodeSection
                // Leave room
                Section {
                    Button(role: .destructive) {
                        session.stop()
                        showDrawer = false
                    } label: {
                        Label("Leave Room", systemImage: "xmark.circle.fill")
                    }
                }
            }
            .navigationTitle("Reading Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showDrawer = false }
                }
            }
        }
    }

    @ViewBuilder
    private var roomCodeSection: some View {
        Section {
            VStack(spacing: 8) {
                Text("Room Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.roomCode)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(hex: "#4ECDC4"), Color(hex: "#45B7D1")],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .onTapGesture { UIPasteboard.general.string = session.roomCode; HapticEngine.light() }
                Text("Tap to copy • Share with friends")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var peerListSection: some View {
        Section("Readers in Room (\(session.peers.count))") {
            if session.peers.isEmpty {
                Label("Waiting for readers…", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(session.peers) { peer in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(peer.avatarColor)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(peer.initials)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                                .font(.subheadline.bold())
                            Text("Page \(peer.currentPage + 1) of \(peer.totalPages)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        CircularProgressArc(fraction: peer.progressFraction, color: peer.avatarColor)
                            .frame(width: 28, height: 28)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reactionSection: some View {
        Section("Send Reaction") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(["🔥", "❤️", "😮", "😂", "👏", "💯", "⚡️", "🎉"], id: \.self) { emoji in
                        Button {
                            session.sendReaction(emoji)
                            HapticEngine.light()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private var joinCodeSection: some View {
        Section("Join by Code") {
            HStack {
                TextField("6-char code", text: $joinCodeEntry)
                    .textCase(.uppercase)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button("Join") {
                    let code = joinCodeEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard code.count == 6 else { return }
                    session.joinWithCode(code)
                    joinCodeEntry = ""
                }
                .disabled(joinCodeEntry.count != 6)
            }
        }
    }
}

// MARK: - Peer Avatar Bubble

private struct PeerAvatarBubble: View {
    let peer: RoomPeer
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(peer.avatarColor)
                .frame(width: 32, height: 32)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                )
                .shadow(color: peer.avatarColor.opacity(0.5), radius: pulsing ? 8 : 4)
                .scaleEffect(pulsing ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulsing)

            Text(peer.initials)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
        }
        .onAppear { pulsing = true }
        // Tooltip on long-press
        .contextMenu {
            Label("\(peer.displayName) — p.\(peer.currentPage + 1)", systemImage: "person.fill")
        }
    }
}

// MARK: - Circular Progress Arc (mini ring for peer progress)

private struct CircularProgressArc: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: fraction)
        }
    }
}

// MARK: - Reaction Burst View

/// A single emoji that floats upward and fades out.
private struct ReactionBurstView: View {
    let reaction: RoomReaction
    let geo: GeometryProxy

    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 1
    @State private var scale: CGFloat = 0.5
    @State private var randomX: CGFloat = 0

    var body: some View {
        Text(reaction.emoji)
            .font(.system(size: 36))
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: randomX, y: offset)
            .position(x: geo.size.width / 2, y: geo.size.height - 120)
            .onAppear {
                randomX = CGFloat.random(in: -60...60)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    scale = 1.2
                }
                withAnimation(.easeOut(duration: 0.15).delay(0.15)) {
                    scale = 1.0
                }
                withAnimation(.easeOut(duration: 1.8).delay(0.2)) {
                    offset = -180
                }
                withAnimation(.easeIn(duration: 0.6).delay(1.4)) {
                    opacity = 0
                }
            }
    }
}
