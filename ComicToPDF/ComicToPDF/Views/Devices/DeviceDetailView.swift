import SwiftUI

struct DeviceDetailView: View {
    let device: SDRegisteredDevice
    @EnvironmentObject var manager: ConversionManager
    @EnvironmentObject var peerManager: PeerManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss

    @State private var animateGlow = false
    
    var body: some View {
        VStack(spacing: 28) {
            // Premium Glowing Device Icon Header
            ZStack {
                // Outer breathing neural glow ring
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.inkBlue.opacity(0.3), Color.inkViolet.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
                    .blur(radius: animateGlow ? 15 : 25)
                    .scaleEffect(animateGlow ? 1.05 : 0.95)
                
                // Inner frosted circle
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 120, height: 120)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.3), Color.white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.inkBlue.opacity(0.15), radius: 15, y: 5)
                
                Image(systemName: device.deviceType.sfSymbol)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.inkBlue, Color.inkViolet],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 40)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    animateGlow = true
                }
            }
            
            VStack(spacing: 8) {
                Text(device.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.inkTextPrimary)
                
                let isOnline = peerManager.isReachable(deviceName: device.name)
                HStack(spacing: 6) {
                    Circle()
                        .fill(isOnline ? Color.inkGreen : Color.inkTextTertiary)
                        .frame(width: 8, height: 8)
                        .shadow(color: isOnline ? Color.inkGreen.opacity(0.6) : .clear, radius: 4)
                    Text(isOnline ? "Online" : "Offline")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(isOnline ? Color.inkGreen : Color.inkTextSecondary)
                }
            }

            // Specs Card List
            VStack(spacing: 12) {
                specificationRow(title: "Device Type", value: device.deviceType.rawValue)
                
                Divider()
                    .background(Color.inkBorderSubtle.opacity(0.5))
                
                specificationRow(title: "Transfer Mode", value: device.transferMethod.rawValue)
                
                if let email = device.kindleEmail, !email.isEmpty {
                    Divider()
                        .background(Color.inkBorderSubtle.opacity(0.5))
                    specificationRow(title: "Kindle Email", value: email)
                }
            }
            .padding(18)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.top, 12)
            
            Spacer()
            
            // Re-engineered Remove Device button
            Button {
                withAnimation {
                    modelContext.delete(device)
                    try? modelContext.save()
                }
            } label: {
                HStack {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Remove Device")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(Color.inkRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.inkRed.opacity(0.08))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.inkRed.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    @ViewBuilder
    private func specificationRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.inkTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.inkTextPrimary)
        }
        .padding(.vertical, 4)
    }
}
