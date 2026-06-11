import SwiftUI
import SwiftData
import Foundation

struct CompletionSendView: View {
    @EnvironmentObject var manager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    let pdf: ConvertedPDF
    @Environment(\.dismiss) var dismiss
    @Query private var savedDevices: [SDRegisteredDevice]

    @State private var selectedDeviceID: UUID?
    @State private var isSending = false
    @State private var sendSuccess = false
    @State private var errorMessage: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // MARK: - Device → Conversion Profile Auto-Map
    /// Maps a registered device type to the best-matching TargetDeviceProfile
    /// so the user never has to manually keep these two pickers in sync.
    private func inferProfile(for deviceType: RegisteredDevice.DeviceType) -> TargetDeviceProfile {
        switch deviceType {
        case .kindleScribe:     return .scribeColorsoft  // Scribe Colorsoft 11" is the current default Scribe
        case .kindleColorsoft:  return .colorsoft7        // 7" Colorsoft
        case .kindlePaperwhite: return .paperwhite2024
        case .iPad, .other:     return settingsManager.conversionSettings.targetDeviceProfile
        }
    }

    var targetDevice: SDRegisteredDevice? {
        if let id = selectedDeviceID {
            return savedDevices.first { $0.id == id }
        }
        return savedDevices.first { $0.id == DeviceRegistry.shared.primaryDeviceID } ?? savedDevices.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.ignoresSafeArea()

                if hSizeClass == .regular {
                    iPadCompletionLayout
                } else {
                    iPhoneCompletionLayout
                }
            }
            .navigationBarHidden(true)
        }
    }

    private var iPhoneCompletionLayout: some View {
        VStack(spacing: 24) {
            Spacer()
            statusHeader
            if !sendSuccess {
                deviceSelectionArea
                sendActions
            } else {
                doneButton
            }
            Spacer()
        }
    }

    private var iPadCompletionLayout: some View {
        HStack(spacing: 60) {
            // Left: Status
            VStack(spacing: 24) {
                statusHeader
                if sendSuccess {
                    doneButton
                        .frame(maxWidth: 300)
                }
            }
            .frame(maxWidth: .infinity)

            // Right: Actions
            if !sendSuccess {
                VStack(spacing: 24) {
                    deviceSelectionArea
                    sendActions
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(40)
    }

    @ViewBuilder
    private var statusHeader: some View {
        ZStack {
            Circle()
                .fill(sendSuccess ? Color.inkGreen.opacity(0.15) : Color.inkBlue.opacity(0.15))
                .frame(width: 80, height: 80)
            Image(systemName: sendSuccess ? "checkmark" : (isSending ? "paperplane.fill" : "wand.and.stars"))
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(sendSuccess ? .inkGreen : .inkBlue)
                .scaleEffect(isSending ? 1.2 : 1.0)
                .offset(x: isSending ? 5 : 0, y: isSending ? -5 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.6).repeatForever(autoreverses: true), value: isSending)
        }

        VStack(spacing: 8) {
            Text(sendSuccess ? "Sent Successfully" : "Conversion Complete")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.inkTextPrimary)

            if !sendSuccess {
                Text(pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title)
                    .font(.system(size: 15))
                    .foregroundColor(.inkTextSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var deviceSelectionArea: some View {
        // Pre-compute the selected ID once so Swift's type-checker doesn't
        // need to solve the compound optional expression inside ForEach.
        let activeID: UUID? = selectedDeviceID ?? DeviceRegistry.shared.primaryDeviceID

        VStack(alignment: .leading, spacing: 12) {
            Text("Send to Device")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.inkTextSecondary)
                .padding(.horizontal, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(savedDevices) { device in
                        DeviceSelectCard(
                            device: device,
                            isSelected: activeID == device.id
                        ) {
                            selectedDeviceID = device.id
                            // Auto-sync conversion profile to the chosen device
                            let profile = inferProfile(for: device.deviceType)
                            if settingsManager.conversionSettings.targetDeviceProfile != profile {
                                settingsManager.conversionSettings.targetDeviceProfile = profile
                                settingsManager.save()
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var sendActions: some View {
        VStack(spacing: 16) {
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundColor(.inkRed)
                    .padding()
                    .background(Color.inkRed.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Send Action
            Button {
                Task { await performSend() }
            } label: {
                HStack {
                    if isSending {
                        ProgressView().tint(.white).padding(.trailing, 8)
                    }
                    Text(isSending ? "Sending..." : "Send to \(targetDevice?.name ?? "Device")")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(targetDevice == nil ? Color.inkTextTertiary : Color.inkBlue)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(targetDevice == nil || isSending)
            .padding(.horizontal, 24)

            Button("Skip for now") {
                dismiss()
            }
            .font(.system(size: 15))
            .foregroundColor(.inkTextSecondary)
        }
    }

    @ViewBuilder
    private var doneButton: some View {
        Button("Done") {
            dismiss()
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.inkGreen)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }

    @MainActor private func performSend() async {
        guard let device = targetDevice else { return }
        isSending = true
        errorMessage = nil

        do {
            switch device.transferMethod {
            case .sendToKindle:
                guard let email = device.kindleEmail, !email.isEmpty else {
                    throw NSError(domain: "Inksync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kindle device missing email address"])
                }
                // Stub for actual send logic
                try await Task.sleep(nanoseconds: 2_000_000_000)
            case .airDrop, .webDAV, .saveToFiles:
                // Stub for actual network logic
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }

            // Update success state on PDF model
            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                manager.convertedPDFs[idx].isOnDevice = true
                manager.convertedPDFs[idx].lastTransferFailed = false
                manager.saveLibrary()
            }

            withAnimation {
                sendSuccess = true
                isSending = false
            }

            // Auto dismiss after success
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { dismiss() }

        } catch {
            isSending = false
            errorMessage = error.localizedDescription

            if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                manager.convertedPDFs[idx].lastTransferFailed = true
                manager.saveLibrary()
            }
        }
    }
}

struct DeviceSelectCard: View {
    let device: SDRegisteredDevice
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: device.deviceType.sfSymbol)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .inkBlue : .inkTextSecondary)

                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .inkTextPrimary : .inkTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: 100, height: 80)
            .background(isSelected ? Color.inkBlue.opacity(0.12) : Color.inkSurface.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.inkBlue : Color.inkBorderSubtle, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
