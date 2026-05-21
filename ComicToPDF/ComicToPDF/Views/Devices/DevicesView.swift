import SwiftUI
import SwiftData

enum DevicesMode: String, CaseIterable {
    case sync    = "Devices"
    case servers = "Servers"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .sync:     return "ipad.and.iphone"
        case .servers:  return "server.rack"
        case .settings: return "gearshape"
        }
    }
    var activeIcon: String {
        switch self {
        case .sync:     return "ipad.and.iphone.fill"
        case .servers:  return "server.rack"
        case .settings: return "gearshape.fill"
        }
    }
    var tint: Color {
        switch self {
        case .sync:     return Color.inkBlue
        case .servers:  return Color(hex: "#2dd4a0")   // inkGreen
        case .settings: return Color(hex: "#7B5EA7")
        }
    }
}

struct DevicesView: View {
    @EnvironmentObject var manager: ConversionManager
    @EnvironmentObject var peerManager: PeerManager
    @ObservedObject var registry = DeviceRegistry.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showAddDevice = false
    @State private var selectedDeviceID: UUID?
    
    @Query(sort: \SDRegisteredDevice.name) private var savedDevices: [SDRegisteredDevice]
    
    @State private var mode: DevicesMode = .sync

    var body: some View {
        VStack(spacing: 0) {
            // ── Segmented Control ──────────────────────────────
            devicesSegmentPicker
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            
            Divider()
                .background(Color.inkBorderVisible)
            
            ZStack {
                if mode == .sync {
                    if hSizeClass == .regular {
                        NavigationSplitView {
                            deviceContent
                                .navigationTitle("Devices")
                                .toolbar {
                                    ToolbarItem(placement: .navigationBarTrailing) {
                                        Button {
                                            showAddDevice = true
                                        } label: {
                                            Image(systemName: "plus")
                                        }
                                        .foregroundColor(.inkBlue)
                                    }
                                }
                        } detail: {
                            deviceDetailPanel
                        }
                    } else {
                        NavigationStack {
                            deviceContent
                                .navigationTitle("Devices")
                                .toolbar {
                                    ToolbarItem(placement: .navigationBarTrailing) {
                                        Button {
                                            showAddDevice = true
                                        } label: {
                                            Image(systemName: "plus")
                                        }
                                        .foregroundColor(.inkBlue)
                                    }
                                }
                        }
                    }
                } else if mode == .servers {
                    NavigationStack {
                        OPDSServersView()
                    }
                } else {
                    NavigationStack {
                        SettingsView()
                    }
                }
            }
        }
        .background(Color.clear)
        .sheet(isPresented: $showAddDevice) {
            AddDeviceSheet()
                .environmentObject(manager)
        }
        .onAppear(perform: handleAppear)
    }

    private var devicesSegmentPicker: some View {
        HStack(spacing: 6) {
            ForEach(DevicesMode.allCases, id: \.self) { segment in
                segmentPill(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentPill(_ segment: DevicesMode) -> some View {
        let isActive = mode == segment

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                mode = segment
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isActive ? segment.activeIcon : segment.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(segment.rawValue)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isActive ? .white : Color.inkTextSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isActive
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [segment.tint, segment.tint.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                      )
                    : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    isActive
                        ? Color.clear
                        : Color.inkBorderVisible.opacity(0.5),
                    lineWidth: 0.75
                )
            )
            .shadow(
                color: isActive ? segment.tint.opacity(0.35) : .clear,
                radius: 8, y: 3
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: mode)
    }

    @ViewBuilder
    private var deviceDetailPanel: some View {
        if let selectedDeviceID, let device = savedDevices.first(where: { $0.id == selectedDeviceID }) {
            DeviceDetailView(device: device)
        } else {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.inkBlue.opacity(0.08))
                        .frame(width: 64, height: 64)
                    Image(systemName: "ipad.and.iphone")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.inkBlue.opacity(0.5))
                }
                Text("Select a Device")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.inkTextSecondary)
                Text("Choose a device from the list to view its details and send files.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private var deviceContent: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    devicesHeader
                    
                    if savedDevices.isEmpty {
                        emptyDevicesView
                            .padding(.top, 40)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(savedDevices) { device in
                                deviceRowContainer(for: device)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var devicesHeader: some View {
        Text("MY DEVICES")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.inkTextSecondary)
            .tracking(1.2)
            .padding(.leading, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func deviceRowContainer(for device: SDRegisteredDevice) -> some View {
        let isPrimary = device.id == registry.primaryDeviceID
        let isOnline = peerManager.isReachable(deviceName: device.name)
        let isSelected = selectedDeviceID == device.id
        
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedDeviceID = device.id
            }
        } label: {
            DeviceRow(
                device: device,
                isPrimary: isPrimary,
                isOnline: isOnline,
                isSelected: isSelected
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    registry.primaryDeviceID = device.id
                    manager.saveLibrary()
                }
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    registry.primaryDeviceID = device.id
                    manager.saveLibrary()
                }
            }) {
                Label("Set as Primary", systemImage: "star.fill")
            }
            
            Button(role: .destructive, action: {
                withAnimation(.spring) {
                    deleteDevice(device)
                }
            }) {
                Label("Delete Device", systemImage: "trash")
            }
        }
    }

    private func deleteDevice(_ device: SDRegisteredDevice) {
        if selectedDeviceID == device.id {
            selectedDeviceID = nil
        }
        modelContext.delete(device)
        try? modelContext.save()
    }

    private var emptyDevicesView: some View {
        VStack(spacing: 0) {
            // Glowing Orb Empty State
            ZStack {
                // Ambient neural glow blob
                NeuralExpressiveBackground()
                    .frame(width: 144, height: 144)
                    .clipShape(Circle())

                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.inkBlue.opacity(0.2), radius: 20, y: 8)

                Image(systemName: "ipad.and.iphone")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.inkBlue, Color.inkViolet],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.bottom, 24)
            
            VStack(spacing: 8) {
                Text("No Reading Devices")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.inkTextPrimary)
                Text("Add your Kindle, Kobo, or iPad to send converted files directly over the air.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.inkTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 40)
            }
            .padding(.bottom, 28)
            
            Button {
                showAddDevice = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Add Device")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: 240)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color.inkBlue, Color.inkViolet.opacity(0.8)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .shadow(color: Color.inkBlue.opacity(0.4), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func handleAppear() {
        // Guard 1: Never auto-prompt before the user has finished onboarding.
        // NOTE: The app uses 'hasCompletedOnboarding', NOT 'hasSeenOnboarding'.
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        // Guard 2: Only prompt on the Devices tab itself — DevicesView stays alive
        // in the background on other tabs, so onAppear fires spuriously.
        // We use a debounce flag so it only triggers on a deliberate navigation to this tab.
        guard UserDefaults.standard.bool(forKey: "hasVisitedDevicesTab") else {
            // First time visiting the tab — mark it, but don't auto-show the sheet.
            UserDefaults.standard.set(true, forKey: "hasVisitedDevicesTab")
            if hSizeClass == .regular { selectedDeviceID = savedDevices.first?.id }
            return
        }
        
        if hSizeClass == .regular && selectedDeviceID == nil {
            selectedDeviceID = savedDevices.first?.id
        }
    }
}

struct DeviceRow: View {
    let device: SDRegisteredDevice
    let isPrimary: Bool
    let isOnline: Bool
    let isSelected: Bool
    let onSetPrimary: () -> Void

    @State private var isPulsing = false

    private var transferIcon: String {
        switch device.transferMethod {
        case .airDrop:        return "airplayvideo"
        case .webDAV:         return "server.rack"
        case .kfxHandoff:     return "desktopcomputer"
        case .sendToKindle:   return "envelope.fill"
        case .saveToFiles:    return "folder.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.inkBlue.opacity(0.2) : Color.inkBlue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: device.deviceType.sfSymbol)
                    .foregroundColor(isSelected ? Color.white : Color.inkBlue)
                    .font(.system(size: 20))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.inkTextPrimary)
                    if isPrimary {
                        Text("PRIMARY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.inkBlue)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOnline ? Color.inkGreen : Color.inkTextTertiary)
                        .frame(width: 6, height: 6)
                        .shadow(color: isOnline ? Color.inkGreen.opacity(0.6) : .clear, radius: 4)
                        .scaleEffect(isOnline && isPulsing ? 1.25 : 1.0)
                    
                    Image(systemName: transferIcon)
                        .font(.system(size: 10))
                        .foregroundColor(.inkTextTertiary)
                    
                    Text(isOnline ? "Online" : device.transferMethod.rawValue)
                        .font(.system(size: 12))
                        .foregroundColor(.inkTextSecondary)
                }
            }

            Spacer()

            if !isPrimary {
                Button(action: onSetPrimary) {
                    Text("Set Primary")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .white : .inkBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.inkBlue.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(isSelected ? Color.inkBlue.opacity(0.18) : Color.inkSurface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isPrimary ? Color.inkBlue.opacity(0.7) : (isSelected ? Color.inkBlue.opacity(0.4) : Color.inkBorderSubtle.opacity(0.6)), lineWidth: isPrimary ? 1.5 : 1)
        )
        .onAppear {
            if isOnline {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }
}
