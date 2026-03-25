import SwiftUI

struct AddDeviceSheet: View {
    @EnvironmentObject var manager: ConversionManager
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var deviceType: RegisteredDevice.DeviceType = .kindleColorsoft
    @State private var transferMethod: RegisteredDevice.TransferMethod = .airDrop
    @State private var kindleEmail: String = ""

    var isValid: Bool { !name.isEmpty }

    var body: some View {
        NavigationView {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                Form {
                    Section("Device") {
                        TextField("e.g. My Kindle Colorsoft", text: $name)
                            .foregroundColor(.inkTextPrimary)
                        Picker("Type", selection: $deviceType) {
                            ForEach(RegisteredDevice.DeviceType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .foregroundColor(.inkTextPrimary)
                    }
                    .listRowBackground(Color.inkSurface)

                    Section("Transfer") {
                        Picker("Method", selection: $transferMethod) {
                            ForEach(RegisteredDevice.TransferMethod.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .foregroundColor(.inkTextPrimary)

                        if deviceType.isKindle {
                            TextField("Kindle email (user@kindle.com)", text: $kindleEmail)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .foregroundColor(.inkTextPrimary)
                        }
                    }
                    .listRowBackground(Color.inkSurface)

                    if transferMethod == .kfxHandoff {
                        Section("Desktop Setup Required") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("KFX format requires a one-time desktop conversion step.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.inkTextSecondary)
                                Text("You'll need: Kindle Previewer 3 + Calibre + KFX Output plugin")
                                    .font(.system(size: 12))
                                    .foregroundColor(.inkTextTertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.inkSurface)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.inkTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        var device = RegisteredDevice(
                            name: name,
                            deviceType: deviceType,
                            transferMethod: transferMethod
                        )
                        if !kindleEmail.isEmpty { device.kindleEmail = kindleEmail }
                        manager.registeredDevices.append(device)
                        if manager.primaryDeviceID == nil {
                            manager.primaryDeviceID = device.id
                        }
                        manager.saveLibrary()
                        UserDefaults.standard.set(true, forKey: "hasCompletedDeviceSetup")
                        dismiss()
                    }
                    .disabled(!isValid)
                    .foregroundColor(isValid ? .inkBlue : .inkTextTertiary)
                }
            }
        }
    }
}
