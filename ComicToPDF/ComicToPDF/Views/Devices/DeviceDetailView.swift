import SwiftUI

struct DeviceDetailView: View {
    let device: RegisteredDevice
    @EnvironmentObject var manager: ConversionManager
    @EnvironmentObject var peerManager: PeerManager
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.inkBlue.opacity(0.1))
                    .frame(width: 120, height: 120)
                Image(systemName: device.deviceType.sfSymbol)
                    .font(.system(size: 52))
                    .foregroundColor(.inkBlue)
            }
            
            Text(device.name)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.inkTextPrimary)
            
            HStack(spacing: 6) {
                let isOnline = peerManager.isReachable(deviceName: device.name)
                Circle()
                    .fill(isOnline ? Color.inkGreen : Color.inkTextTertiary)
                    .frame(width: 8, height: 8)
                Text(isOnline ? "Online" : "Offline")
                    .font(.system(size: 14))
                    .foregroundColor(.inkTextSecondary)
            }

            VStack(spacing: 12) {
                HStack {
                    Text("Type")
                        .foregroundColor(.inkTextSecondary)
                    Spacer()
                    Text(device.deviceType.rawValue)
                        .foregroundColor(.inkTextPrimary)
                }
                Divider().background(Color.inkBorderSubtle)
                HStack {
                    Text("Transfer Mode")
                        .foregroundColor(.inkTextSecondary)
                    Spacer()
                    Text(device.transferMethod.rawValue)
                        .foregroundColor(.inkTextPrimary)
                }
            }
            .padding()
            .background(Color.inkSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 40)
            .padding(.top, 20)
            
            Spacer()
            
            Button {
                if let index = manager.registeredDevices.firstIndex(where: { $0.id == device.id }) {
                    manager.registeredDevices.remove(at: index)
                    manager.saveLibrary()
                }
            } label: {
                Text("Remove Device")
                    .foregroundColor(.inkRed)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.inkRed.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.inkBackground)
    }
}
