import SwiftUI
import SwiftData

struct DevicesView: View {
    @EnvironmentObject var manager: ConversionManager
    @EnvironmentObject var peerManager: PeerManager
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
                    Image(systemName: "ipad.and.iphone")
                        .font(.system(size: 52))
                        .foregroundColor(.inkTextTertiary)
                    Text("Select a device")
                        .font(.system(size: 17))
                        .foregroundColor(.inkTextSecondary)
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
                        ForEach(savedDevices) { device in
                            if hSizeClass == .regular {
                                // iPad: use NavigationLink-style selection
                                NavigationLink(value: device.id) {
                                    DeviceRow(
                                        device: device,
                                        isPrimary: device.id == manager.primaryDeviceID,
                                        isOnline: peerManager.isReachable(deviceName: device.name)
                                    ) {
                                        manager.primaryDeviceID = device.id
                                        manager.saveLibrary()
                                    }
                                }
                                .listRowBackground(selectedDeviceID == device.id ? Color.inkBlue.opacity(0.15) : Color.inkSurface)
                            } else {
                                // iPhone: traditional action row
                                DeviceRow(
                                    device: device,
                                    isPrimary: device.id == manager.primaryDeviceID,
                                    isOnline: peerManager.isReachable(deviceName: device.name)
                                ) {
                                    manager.primaryDeviceID = device.id
                                    manager.saveLibrary()
                                }
                                .listRowBackground(Color.inkSurface)
                            }
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
    }

    private func handleAppear() {
        if savedDevices.isEmpty &&
           !UserDefaults.standard.bool(forKey: "hasCompletedDeviceSetup") {
            showAddDevice = true
        } else if hSizeClass == .regular && selectedDeviceID == nil {
            selectedDeviceID = savedDevices.first?.id
        }
    }
}

struct DeviceRow: View {
    let device: SDRegisteredDevice
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
                    // Added buttonStyle to prevent tapping row capturing button on iPhone
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
