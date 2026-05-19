import SwiftUI
import SwiftData

struct DevicesView: View {
    @EnvironmentObject var manager: ConversionManager
    @EnvironmentObject var peerManager: PeerManager
    @ObservedObject var registry = DeviceRegistry.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showAddDevice = false
    @State private var selectedDeviceID: UUID?
    
    @Query(sort: \SDRegisteredDevice.name) private var savedDevices: [SDRegisteredDevice]

    var body: some View {
        if hSizeClass == .regular {
            iPadDevicesLayout
        } else {
            iPhoneDevicesLayout
        }
    }

    private var iPhoneDevicesLayout: some View {
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
                .sheet(isPresented: $showAddDevice) {
                    AddDeviceSheet()
                        .environmentObject(manager)
                }
                .onAppear(perform: handleAppear)
        }
    }

    private var iPadDevicesLayout: some View {
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
                .sheet(isPresented: $showAddDevice) {
                    AddDeviceSheet()
                        .environmentObject(manager)
                }
                .onAppear(perform: handleAppear)
        } detail: {
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
                .background(Color.inkBackground)
            }
        }
    }

    @ViewBuilder
    private var deviceContent: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()

            List(selection: $selectedDeviceID) {
                Section {
                    if savedDevices.isEmpty {
                        VStack(spacing: 0) {
                            // Glowing Orb Empty State
                            ZStack {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            gradient: Gradient(colors: [Color.inkBlue.opacity(0.35), Color.inkViolet.opacity(0.15), .clear]),
                                            center: .center,
                                            startRadius: 20,
                                            endRadius: 72
                                        )
                                    )
                                    .frame(width: 144, height: 144)
                                    .blur(radius: 24)

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
                        .listRowBackground(Color.inkSurface)
                    } else {
                        ForEach(savedDevices) { device in
                            if hSizeClass == .regular {
                                NavigationLink(value: device.id) {
                                    DeviceRow(
                                        device: device,
                                        isPrimary: device.id == registry.primaryDeviceID,
                                        isOnline: peerManager.isReachable(deviceName: device.name)
                                    ) {
                                        registry.primaryDeviceID = device.id
                                        manager.saveLibrary()
                                    }
                                }
                                .listRowBackground(selectedDeviceID == device.id ? Color.inkBlue.opacity(0.15) : Color.inkSurface)
                            } else {
                                DeviceRow(
                                    device: device,
                                    isPrimary: device.id == registry.primaryDeviceID,
                                    isOnline: peerManager.isReachable(deviceName: device.name)
                                ) {
                                    registry.primaryDeviceID = device.id
                                    manager.saveLibrary()
                                }
                                .listRowBackground(Color.inkSurface)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                modelContext.delete(savedDevices[index])
                            }
                            try? modelContext.save()
                        }
                    }
                } header: {
                    Text("MY DEVICES")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.inkTextSecondary)
                        .tracking(1.2)
                }
                .listRowBackground(Color.inkSurface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
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
    let onSetPrimary: () -> Void

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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.inkBlue.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: device.deviceType.sfSymbol)
                    .foregroundColor(.inkBlue)
                    .font(.system(size: 19))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.inkTextPrimary)
                    if isPrimary {
                        Text("PRIMARY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.inkBlue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.inkBlue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOnline ? Color.inkGreen : Color.inkTextTertiary)
                        .frame(width: 6, height: 6)
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
                Button("Set primary") { onSetPrimary() }
                    .font(.system(size: 12))
                    .foregroundColor(.inkTextSecondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}
