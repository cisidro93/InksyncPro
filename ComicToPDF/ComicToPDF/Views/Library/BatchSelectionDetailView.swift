import SwiftUI

struct BatchSelectionDetailView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    var selectionCount: Int
    var onBatchEdit: () -> Void
    var onFetchMetadata: () -> Void
    var onConvert: () -> Void
    var onMerge: () -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var buttonMaxWidth: CGFloat {
        isPad ? 420 : 320
    }

    var body: some View {
        VStack(spacing: 0) {
            InkSheetDragPill()
                .padding(.top, 8)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Image(systemName: "checklist")
                        .font(.system(size: isPad ? 72 : 56))
                        .foregroundColor(Color.inkBlue)
                        .shadow(color: Color.inkBlue.opacity(0.3), radius: 10, y: 4)
                    
                    VStack(spacing: 6) {
                        Text("\(selectionCount) Items Selected")
                            .font(.system(size: isPad ? 26 : 22, weight: .bold, design: .rounded))
                            .foregroundColor(Color.inkText)
                        
                        Text("Choose an action for the selected files.")
                            .font(.system(size: isPad ? 15 : 13.5))
                            .foregroundColor(Color.inkSecondary)
                    }
                    
                    VStack(spacing: 14) {
                        // Smart Cropping Toggle
                        Toggle(isOn: $settingsManager.conversionSettings.trimMargins) {
                            Label("Smart Border Trimming", systemImage: "crop")
                                .font(.system(size: isPad ? 16 : 14.5, weight: .medium))
                                .foregroundColor(Color.inkText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.inkSurfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .inkSpecularBorder(cornerRadius: 14)
                        .frame(maxWidth: buttonMaxWidth)
                        
                        Button {
                            HapticEngine.selection()
                            onBatchEdit()
                        } label: {
                            Label("Edit Metadata", systemImage: "pencil.and.list.clipboard")
                                .font(.system(size: isPad ? 16 : 14.5, weight: .semibold))
                                .frame(maxWidth: buttonMaxWidth)
                                .padding(.vertical, isPad ? 15 : 13)
                                .background(Color.inkOrange)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: Color.inkOrange.opacity(0.25), radius: 6, y: 3)
                        }
                        .disabled(selectionCount == 0)
                        
                        Button {
                            HapticEngine.selection()
                            onFetchMetadata()
                        } label: {
                            Label("Intelligent Metadata", systemImage: "sparkles")
                                .font(.system(size: isPad ? 16 : 14.5, weight: .semibold))
                                .frame(maxWidth: buttonMaxWidth)
                                .padding(.vertical, isPad ? 15 : 13)
                                .background(
                                    selectionCount == 0
                                        ? Color.inkSecondary.opacity(0.2)
                                        : Color.inkBlue
                                )
                                .foregroundColor(selectionCount == 0 ? Color.inkSecondary : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: selectionCount == 0 ? .clear : Color.inkBlue.opacity(0.3), radius: 6, y: 3)
                        }
                        .disabled(selectionCount == 0)
                        
                        Button {
                            HapticEngine.selection()
                            onConvert()
                        } label: {
                            Label("Convert Selected", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: isPad ? 16 : 14.5, weight: .semibold))
                                .frame(maxWidth: buttonMaxWidth)
                                .padding(.vertical, isPad ? 15 : 13)
                                .background(selectionCount == 0 ? Color.inkSecondary.opacity(0.2) : Color.inkBlue)
                                .foregroundColor(selectionCount == 0 ? Color.inkSecondary : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: selectionCount == 0 ? .clear : Color.inkBlue.opacity(0.3), radius: 6, y: 3)
                        }
                        .disabled(selectionCount == 0)
                        
                        Button {
                            HapticEngine.selection()
                            onMerge()
                        } label: {
                            Label("Convert & Merge", systemImage: "arrow.triangle.2.circlepath.doc")
                                .font(.system(size: isPad ? 16 : 14.5, weight: .semibold))
                                .frame(maxWidth: buttonMaxWidth)
                                .padding(.vertical, isPad ? 15 : 13)
                                .background(selectionCount < 2 ? Color.inkSecondary.opacity(0.2) : Color.inkViolet)
                                .foregroundColor(selectionCount < 2 ? Color.inkSecondary : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: selectionCount < 2 ? .clear : Color.inkViolet.opacity(0.3), radius: 6, y: 3)
                        }
                        .disabled(selectionCount < 2)
                        
                        Button(role: .destructive) {
                            HapticEngine.warning()
                            onDelete()
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                                .font(.system(size: isPad ? 16 : 14.5, weight: .semibold))
                                .frame(maxWidth: buttonMaxWidth)
                                .padding(.vertical, isPad ? 15 : 13)
                                .background(Color.inkRed.opacity(0.12))
                                .foregroundColor(Color.inkRed)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.inkRed.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .disabled(selectionCount == 0)
                        
                        Button(role: .cancel) {
                            onCancel()
                        } label: {
                            Text("Cancel Selection")
                                .font(.system(size: isPad ? 16 : 14.5, weight: .medium))
                                .foregroundColor(Color.inkSecondary)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Color.inkBackground.ignoresSafeArea())
    }
}
