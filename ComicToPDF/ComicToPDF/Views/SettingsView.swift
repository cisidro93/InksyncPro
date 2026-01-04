import SwiftUI

// ============================================================================
// MARK: - SETTINGS VIEW
// ============================================================================

struct SettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showingAddDevice = false
    @State private var deviceToEdit: KindleDevice?
    @State private var showingDeleteAlert = false
    @State private var deviceToDelete: KindleDevice?
    @State private var showingCloudImport = false
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(conversionManager.kindleDevices) { device in
                        KindleDeviceRow(device: device, isDefault: device.isDefault, onSetDefault: { conversionManager.setDefaultKindleDevice(device) }, onEdit: { deviceToEdit = device })
                        .swipeActions(edge: .trailing) { Button(role: .destructive) { deviceToDelete = device; showingDeleteAlert = true } label: { Label("Delete", systemImage: "trash") } }
                    }
                    Button(action: { showingAddDevice = true }) { HStack { Image(systemName: "plus.circle.fill").foregroundColor(.green); Text("Add Kindle Device") } }
                } header: { Text("Kindle Devices") } footer: { Text("Add multiple Kindle devices and select which one to send to.") }
                
                Section(header: Text("Appearance")) {
                    Picker("Theme", selection: $themeManager.selectedTheme) {
                        ForEach(AppearanceTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    HStack {
                        Image(systemName: "sun.max.fill")
                            .foregroundColor(.orange)
                        Spacer()
                        Text("Choose your preferred theme")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "moon.fill")
                            .foregroundColor(.blue)
                    }
                    .padding(.vertical, 4)
                }
                
                Section {
                    Button(action: { showingCloudImport = true }) { HStack { Image(systemName: "icloud.and.arrow.down").foregroundColor(.blue).frame(width: 28); Text("Import from Cloud"); Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary) } }.foregroundColor(.primary)
                    HStack { Image(systemName: "icloud.fill").foregroundColor(.blue).frame(width: 28); Text("iCloud Status"); Spacer(); Text(CloudManager.shared.isICloudAvailable ? "Connected" : "Not Available").foregroundColor(CloudManager.shared.isICloudAvailable ? .green : .orange) }
                    if CloudManager.shared.isICloudAvailable { NavigationLink { ICloudManagementView() } label: { HStack { Image(systemName: "externaldrive.fill.badge.icloud").foregroundColor(.blue).frame(width: 28); Text("Manage iCloud Files") } } }
                } header: { Text("Cloud Storage") } footer: { Text("Import CBZ/CBR files from iCloud Drive, Dropbox, Google Drive, or any cloud service.") }
                
                Section {
                    NavigationLink(destination: DefaultConversionSettingsView()) { HStack { Image(systemName: "slider.horizontal.3").foregroundColor(.orange).frame(width: 28); Text("Conversion Defaults") } }
                    NavigationLink(destination: DefaultEnhancementSettingsView()) { HStack { Image(systemName: "wand.and.stars").foregroundColor(.blue).frame(width: 28); Text("Enhancement Defaults") } }
                    NavigationLink(destination: ConversionPresetsView()) { HStack { Image(systemName: "list.dash.header.rectangle").foregroundColor(.purple).frame(width: 28); Text("Conversion Presets") } }
                    NavigationLink(destination: AdvancedOptionsView()) { HStack { Image(systemName: "gearshape.2.fill").foregroundColor(.gray).frame(width: 28); Text("Advanced Options") } }
                } header: { Text("Default Settings") }
                
                Section {
                    NavigationLink(destination: StorageManagerView()) { HStack { Image(systemName: "internaldrive.fill").foregroundColor(.gray).frame(width: 28); Text("Storage Manager") } }
                    NavigationLink(destination: DuplicateDetectionView()) { HStack { Image(systemName: "doc.on.doc.fill").foregroundColor(.red).frame(width: 28); Text("Duplicate Finder") } }
                    NavigationLink(destination: AutoOrganizeView()) { HStack { Image(systemName: "tray.full.fill").foregroundColor(.green).frame(width: 28); Text("Auto-Organize") } }
                    NavigationLink(destination: SendHistoryView()) { HStack { Image(systemName: "clock.fill").foregroundColor(.blue).frame(width: 28); Text("Send History") } }
                    NavigationLink(destination: BackupRestoreView()) { HStack { Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundColor(.orange).frame(width: 28); Text("Backup & Restore") } }
                } header: { Text("Tools") }
                
                Section {
                    HStack { Image(systemName: "internaldrive.fill").foregroundColor(.gray).frame(width: 28); Text("Library Size"); Spacer(); Text(calculateLibrarySize()).foregroundColor(.secondary) }
                    HStack { Image(systemName: "doc.fill").foregroundColor(.gray).frame(width: 28); Text("Total PDFs"); Spacer(); Text("\(conversionManager.convertedPDFs.count)").foregroundColor(.secondary) }
                } header: { Text("Storage") }
                
                Section {
                    HStack { Image(systemName: "info.circle.fill").foregroundColor(.blue).frame(width: 28); Text("Version"); Spacer(); Text(appVersion).foregroundColor(.secondary) }
                    Link(destination: URL(string: "https://www.amazon.com/sendtokindle")!) { HStack { Image(systemName: "globe").foregroundColor(.orange).frame(width: 28); Text("Send to Kindle Website"); Spacer(); Image(systemName: "arrow.up.right.square").foregroundColor(.secondary) } }
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingAddDevice) { AddEditKindleDeviceView(mode: .add) }
            .sheet(item: $deviceToEdit) { device in AddEditKindleDeviceView(mode: .edit(device)) }
            .sheet(isPresented: $showingCloudImport) { CloudImportView() }
            .alert("Delete Device?", isPresented: $showingDeleteAlert) { Button("Cancel", role: .cancel) { }; Button("Delete", role: .destructive) { if let device = deviceToDelete { conversionManager.removeKindleDevice(device) } } } message: { if let device = deviceToDelete { Text("Are you sure you want to delete \"\(device.name)\"?") } }
        }.navigationViewStyle(.stack)
    }
    
    private func calculateLibrarySize() -> String { let totalBytes = conversionManager.convertedPDFs.reduce(0) { $0 + $1.fileSize }; let formatter = ByteCountFormatter(); formatter.countStyle = .file; return formatter.string(fromByteCount: totalBytes) }
    
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }
}

struct KindleDeviceRow: View {
    let device: KindleDevice
    let isDefault: Bool
    let onSetDefault: () -> Void
    let onEdit: () -> Void
    
    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                ZStack { Circle().fill(isDefault ? Color.orange.opacity(0.2) : Color.gray.opacity(0.1)).frame(width: 44, height: 44); Image(systemName: device.deviceType.icon).font(.title3).foregroundColor(isDefault ? .orange : .gray) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(device.name).font(.headline).foregroundColor(.primary); if isDefault { Text("DEFAULT").font(.caption2).fontWeight(.bold).foregroundColor(.orange).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.2).cornerRadius(4)) } }
                    Text(device.email).font(.caption).foregroundColor(.secondary)
                    Text(device.deviceType.rawValue).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if !isDefault { Button(action: onSetDefault) { Text("Set Default").font(.caption).foregroundColor(.orange) }.buttonStyle(BorderlessButtonStyle()) }
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }.buttonStyle(PlainButtonStyle())
    }
}

enum AddEditMode { case add; case edit(KindleDevice) }

struct AddEditKindleDeviceView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let mode: AddEditMode
    @State private var name = ""
    @State private var email = ""
    @State private var deviceType: KindleDeviceType = .paperwhite
    @State private var isDefault = false
    @State private var showingValidationAlert = false
    var isEditing: Bool { if case .edit = mode { return true }; return false }
    
    var body: some View {
        NavigationView {
            Form {
                Section { TextField("Device Name", text: $name).textContentType(.name); TextField("Kindle Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).autocapitalization(.none); Picker("Device Type", selection: $deviceType) { ForEach(KindleDeviceType.allCases, id: \.self) { type in HStack { Image(systemName: type.icon); Text(type.rawValue) }.tag(type) } } } header: { Text("Device Information") } footer: { Text("Enter your Send-to-Kindle email address (e.g., yourname@kindle.com)") }
                Section { Toggle("Set as Default Device", isOn: $isDefault) } footer: { Text("The default device will be automatically selected when sending PDFs") }
                if isEditing { Section { HStack { Text("Resolution"); Spacer(); Text("\(Int(deviceType.resolution.width)) × \(Int(deviceType.resolution.height))").foregroundColor(.secondary) } } header: { Text("Device Specs") } }
            }
            .navigationTitle(isEditing ? "Edit Device" : "Add Device").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { saveDevice() }.fontWeight(.semibold) } }
            .alert("Invalid Email", isPresented: $showingValidationAlert) { Button("OK", role: .cancel) { } } message: { Text("Please enter a valid Kindle email address") }
            .onAppear { if case .edit(let device) = mode { name = device.name; email = device.email; deviceType = device.deviceType; isDefault = device.isDefault } }
        }
    }
    
    private func saveDevice() {
        guard !name.isEmpty else { showingValidationAlert = true; return }
        guard email.contains("@") && email.contains(".") else { showingValidationAlert = true; return }
        switch mode {
        case .add: let device = KindleDevice(name: name, email: email, deviceType: deviceType, isDefault: isDefault || conversionManager.kindleDevices.isEmpty); conversionManager.addKindleDevice(device); if isDefault { conversionManager.setDefaultKindleDevice(device) }
        case .edit(let existingDevice): var updatedDevice = existingDevice; updatedDevice.name = name; updatedDevice.email = email; updatedDevice.deviceType = deviceType; updatedDevice.isDefault = isDefault; conversionManager.updateKindleDevice(updatedDevice); if isDefault { conversionManager.setDefaultKindleDevice(updatedDevice) }
        }
        dismiss()
    }
}

struct DefaultConversionSettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    var body: some View {
        Form {
            Section { Toggle("Manga Mode (RTL)", isOn: $conversionManager.conversionSettings.mangaMode) } header: { Text("Reading Direction") } footer: { Text("Enable for Japanese manga to reverse page order") }
            
            // Panel View Section Moved to ConvertView

            
            
            Section {
                Picker("Default Quality", selection: $conversionManager.conversionSettings.compressionQuality) { ForEach(CompressionPreset.allCases, id: \.self) { preset in Text(preset.rawValue).tag(preset) } }
                if conversionManager.conversionSettings.compressionQuality == .custom {
                    VStack(alignment: .leading) { Text("Resolution Scale: \(Int(conversionManager.conversionSettings.customScale * 100))%"); Slider(value: $conversionManager.conversionSettings.customScale, in: 0.3...1.0, step: 0.05) }
                    VStack(alignment: .leading) { Text("Image Quality: \(Int(conversionManager.conversionSettings.customJpegQuality * 100))%"); Slider(value: $conversionManager.conversionSettings.customJpegQuality, in: 0.5...1.0, step: 0.05) }
                }
            } header: { Text("Compression") }
            Section {
                Toggle("Optimize for Device", isOn: $conversionManager.conversionSettings.optimizeForDevice)
                if conversionManager.conversionSettings.optimizeForDevice { Picker("Target Device", selection: $conversionManager.conversionSettings.targetDevice) { ForEach(KindleDeviceType.allCases, id: \.self) { device in HStack { Image(systemName: device.icon); Text(device.rawValue) }.tag(device) } } }
            } header: { Text("Device Optimization") }
        }.navigationTitle("Conversion Defaults").onChange(of: conversionManager.conversionSettings) { _ in conversionManager.saveSettings() }
    }
}

struct DefaultEnhancementSettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingResetAlert = false
    
    var body: some View {
        Form {
            Section { Toggle("Enable Enhancement", isOn: $conversionManager.conversionSettings.imageEnhancement.enabled) }
            if conversionManager.conversionSettings.imageEnhancement.enabled {
                Section { Toggle("Auto Contrast", isOn: $conversionManager.conversionSettings.imageEnhancement.autoContrast); Toggle("Grayscale", isOn: $conversionManager.conversionSettings.imageEnhancement.grayscale); Toggle("Dark Mode (Invert)", isOn: $conversionManager.conversionSettings.imageEnhancement.invertColors) } header: { Text("Quick Options") }
                Section {
                    VStack(alignment: .leading) { Text("Brightness: \(Int(conversionManager.conversionSettings.imageEnhancement.brightness * 100))%"); Slider(value: $conversionManager.conversionSettings.imageEnhancement.brightness, in: -0.5...0.5) }
                    VStack(alignment: .leading) { Text("Contrast: \(Int(conversionManager.conversionSettings.imageEnhancement.contrast * 100))%"); Slider(value: $conversionManager.conversionSettings.imageEnhancement.contrast, in: 0.5...1.5) }
                    VStack(alignment: .leading) { Text("Sharpness: \(Int(conversionManager.conversionSettings.imageEnhancement.sharpness * 100))%"); Slider(value: $conversionManager.conversionSettings.imageEnhancement.sharpness, in: 0...1.0) }
                } header: { Text("Adjustments") }
                Section { 
                    Button("Reset to Defaults") { 
                        showingResetAlert = true 
                        HapticManager.shared.impact(.medium)
                    }
                    .foregroundColor(.red) 
                }
            }
        }
        .navigationTitle("Enhancement Defaults")
        .onChange(of: conversionManager.conversionSettings) { _ in conversionManager.saveSettings() }
        .alert("Reset Settings?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                HapticManager.shared.notification(.success)
                withAnimation {
                    conversionManager.conversionSettings.imageEnhancement = ImageEnhancementSettings(enabled: true)
                }
            }
        }
    }
}

struct ICloudManagementView: View {
    @StateObject private var cloudManager = CloudManager.shared
    @State private var iCloudFiles: [URL] = []
    @State private var isLoading = true
    
    var body: some View {
        List {
            if isLoading { HStack { Spacer(); ProgressView(); Spacer() } }
            else if iCloudFiles.isEmpty { Text("No files in iCloud Drive").foregroundColor(.secondary) }
            else { ForEach(iCloudFiles, id: \.absoluteString) { url in HStack { Image(systemName: "doc.fill").foregroundColor(.red); VStack(alignment: .leading) { Text(url.lastPathComponent); if let size = fileSize(url) { Text(size).font(.caption).foregroundColor(.secondary) } } } }.onDelete(perform: deleteFiles) }
        }.navigationTitle("iCloud Files").onAppear(perform: loadICloudFiles).refreshable { loadICloudFiles() }
    }
    
    private func loadICloudFiles() {
        guard let containerURL = cloudManager.iCloudContainerURL else { isLoading = false; return }
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [URL] = []
            if let enumerator = FileManager.default.enumerator(at: containerURL, includingPropertiesForKeys: [.isRegularFileKey]) { while let fileURL = enumerator.nextObject() as? URL { if fileURL.pathExtension.lowercased() == "pdf" { files.append(fileURL) } } }
            DispatchQueue.main.async { iCloudFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent }; isLoading = false }
        }
    }
    private func fileSize(_ url: URL) -> String? { guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int64 else { return nil }; let formatter = ByteCountFormatter(); formatter.countStyle = .file; return formatter.string(fromByteCount: size) }
    private func deleteFiles(at offsets: IndexSet) { for index in offsets { let url = iCloudFiles[index]; try? FileManager.default.removeItem(at: url) }; iCloudFiles.remove(atOffsets: offsets) }
}
