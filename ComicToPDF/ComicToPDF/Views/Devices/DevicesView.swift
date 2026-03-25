import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var manager: ConversionManager
    @EnvironmentObject var peerManager: PeerManager
    @State private var showAddDevice = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                List {
                    Section {
                        if manager.registeredDevices.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "ipad.and.iphone")
                                    .font(.system(size: 40))
                                    .foregroundColor(.inkTextSecondary)
                                Text("No devices configured")
                                    .foregroundColor(.inkTextSecondary)
                                Button("Add your Kindle or iPad") {
                                    showAddDevice = true
                                }
                                .foregroundColor(.inkBlue)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .listRowBackground(Color.inkSurface)
                        } else {
                            ForEach(manager.registeredDevices) { device in
                                DeviceRow(
                                    device: device,
                                    isPrimary: device.id == manager.primaryDeviceID,
                                    isOnline: peerManager.isReachable(deviceName: device.name)
                                ) {
                                    manager.primaryDeviceID = device.id
                                    manager.saveLibrary()
                                }
                            }
                            .onDelete { indexSet in
                                manager.registeredDevices.remove(atOffsets: indexSet)
                                manager.saveLibrary()
                            }
                        }
                    } header: {
                        Text("My Devices")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.inkTextSecondary)
                    }
                    .listRowBackground(Color.inkSurface)

                    Section {
                        Button("How does the desktop KFX conversion work?") {
                            // Show KFX guide sheet
                        }
                        .foregroundColor(.inkBlue)
                    }
                    .listRowBackground(Color.inkSurface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
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
            .onAppear {
                // On first launch with no devices, auto-present AddDeviceSheet
                if manager.registeredDevices.isEmpty &&
                   !UserDefaults.standard.bool(forKey: "hasCompletedDeviceSetup") {
                    showAddDevice = true
                }
            }
        }
    }
}

struct DeviceRow: View {
    let device: RegisteredDevice
    let isPrimary: Bool
    let isOnline: Bool
    let onSetPrimary: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.inkBlue.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: device.deviceType.sfSymbol)
                    .foregroundColor(.inkBlue)
                    .font(.system(size: 18))
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
                HStack(spacing: 4) {
                    Circle()
                        .fill(isOnline ? Color.inkGreen : Color.inkTextTertiary)
                        .frame(width: 6, height: 6)
                    Text(isOnline ? "Online · \(device.transferMethod.rawValue)" : device.transferMethod.rawValue)
                        .font(.system(size: 12))
                        .foregroundColor(.inkTextSecondary)
                }
            }

            Spacer()

            if !isPrimary {
                Button("Set primary") { onSetPrimary() }
                    .font(.system(size: 12))
                    .foregroundColor(.inkTextSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}
