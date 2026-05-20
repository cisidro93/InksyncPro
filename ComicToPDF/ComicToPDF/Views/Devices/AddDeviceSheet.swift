import SwiftUI

struct AddDeviceSheet: View {
    @EnvironmentObject var manager: ConversionManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var deviceType: RegisteredDevice.DeviceType = .kindleColorsoft
    @State private var transferMethod: RegisteredDevice.TransferMethod = .airDrop
    @State private var kindleEmail: String = ""

    var isValid: Bool { !name.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.inkBackground.ignoresSafeArea()
                
                // Subtle ambient glow in the top-right
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color.inkBlue.opacity(0.12))
                            .frame(width: 250, height: 250)
                            .blur(radius: 50)
                            .offset(x: 100, y: -100)
                    }
                    Spacer()
                }
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        
                        // ── Device Name Field ──────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DEVICE NAME")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.inkTextSecondary)
                                .tracking(1.2)
                            
                            TextField("e.g. My Kindle Colorsoft", text: $name)
                                .font(.system(size: 16))
                                .foregroundColor(.inkTextPrimary)
                                .padding()
                                .background(Color.inkSurface.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                        
                        // ── Device Type Selection Grid ─────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DEVICE TYPE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.inkTextSecondary)
                                .tracking(1.2)
                            
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(RegisteredDevice.DeviceType.allCases, id: \.self) { type in
                                    let isSelected = deviceType == type
                                    Button {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                            deviceType = type
                                            // Auto-update transfer mode defaults for Kindle vs non-Kindle
                                            if !type.isKindle && transferMethod == .sendToKindle {
                                                transferMethod = .airDrop
                                            } else if type.isKindle && transferMethod == .airDrop {
                                                transferMethod = .sendToKindle
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: type.sfSymbol)
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundColor(isSelected ? .white : Color.inkBlue)
                                            Text(type.rawValue)
                                                .font(.system(size: 13, weight: .semibold))
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.vertical, 14)
                                        .padding(.horizontal, 14)
                                        .background(isSelected ? Color.inkBlue : Color.inkSurface.opacity(0.4))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(isSelected ? Color.inkBlue.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // ── Transfer Method Selection ──────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TRANSFER METHOD")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.inkTextSecondary)
                                .tracking(1.2)
                            
                            // Filter valid methods based on device type
                            let availableMethods = RegisteredDevice.TransferMethod.allCases.filter { m in
                                if !deviceType.isKindle && m == .sendToKindle { return false }
                                return true
                            }
                            
                            VStack(spacing: 8) {
                                ForEach(availableMethods, id: \.self) { method in
                                    let isSelected = transferMethod == method
                                    Button {
                                        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                                            transferMethod = method
                                        }
                                    } label: {
                                        HStack {
                                            Text(method.rawValue)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(isSelected ? .white : .inkTextPrimary)
                                            Spacer()
                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.white)
                                                    .font(.system(size: 16))
                                            }
                                        }
                                        .padding()
                                        .background(isSelected ? Color.inkBlue : Color.inkSurface.opacity(0.4))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(isSelected ? Color.inkBlue : Color.white.opacity(0.08), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // ── Kindle Specific Options ─────────────────────────
                        if deviceType.isKindle && transferMethod == .sendToKindle {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("KINDLE EMAIL")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.inkTextSecondary)
                                    .tracking(1.2)
                                
                                TextField("e.g. user@kindle.com", text: $kindleEmail)
                                    .keyboardType(.emailAddress)
                                    .autocapitalization(.none)
                                    .font(.system(size: 16))
                                    .foregroundColor(.inkTextPrimary)
                                    .padding()
                                    .background(Color.inkSurface.opacity(0.4))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                
                                Text("Tip: You must authorize your primary email inside Amazon's Content & Devices settings to send files directly over the air.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.inkTextSecondary)
                                    .lineSpacing(2)
                                    .padding(.top, 4)
                            }
                        }

                        // ── Desktop Setup Help Card ─────────────────────────
                        if transferMethod == .kfxHandoff {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundColor(Color.inkAmber)
                                        .font(.system(size: 18))
                                    Text("Desktop Setup Required")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.inkTextPrimary)
                                }
                                
                                Text("KFX layout conversion requires a desktop assistant to render advanced Kindle typography.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.inkTextSecondary)
                                    .lineSpacing(3)
                                
                                Text("Prerequisites: Kindle Previewer 3, Calibre, and the KFX Output plugin installed on your PC or Mac.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.inkTextTertiary)
                                    .lineSpacing(2)
                            }
                            .padding()
                            .background(Color.inkAmber.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.inkAmber.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                    .padding(24)
                }
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
                        let device = SDRegisteredDevice(
                            name: name,
                            deviceType: deviceType,
                            transferMethod: transferMethod,
                            kindleEmail: kindleEmail.isEmpty ? nil : kindleEmail
                        )
                        modelContext.insert(device)
                        if DeviceRegistry.shared.primaryDeviceID == nil {
                            DeviceRegistry.shared.primaryDeviceID = device.id
                            manager.saveLibrary()
                        }
                        try? modelContext.save()
                        UserDefaults.standard.set(true, forKey: "hasCompletedDeviceSetup")
                        dismiss()
                    }
                    .disabled(!isValid)
                    .foregroundColor(isValid ? .inkBlue : .inkTextTertiary)
                    .font(.system(size: 16, weight: .bold))
                }
            }
        }
    }
}
