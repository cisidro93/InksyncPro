import SwiftUI
import PDFKit

// MARK: - Inksync Secure Export Sheet

/// Next-Generation secure PDF export interface.
/// Provides dual export personas ("Flattened Tamper-Proof" vs "Editable ISO 32000 Annotations"),
/// air-gapped on-device processing, AES-256 password encryption, metadata sanitization,
/// and proactive defense against visual fake-redaction vulnerabilities.
public struct InksyncSecureExportSheet: View {

    let pdf: PDF
    let document: PDFDocument
    let currentPageIndex: Int
    var onDismiss: () -> Void

    @State private var exportConfig = PDFExportConfiguration()
    @State private var confirmPassword: String = ""
    @State private var isExporting: Bool = false
    @State private var exportedFileURL: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showErrorAlert: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public init(
        pdf: PDF,
        document: PDFDocument,
        currentPageIndex: Int,
        onDismiss: @escaping () -> Void
    ) {
        self.pdf = pdf
        self.document = document
        self.currentPageIndex = currentPageIndex
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    personaSelectorSection
                    privacySentinelBanner
                    layersSection
                    securitySection
                    metadataSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Secure PDF Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(isExporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        startExportPipeline()
                    } label: {
                        if isExporting {
                            ProgressView()
                                .tint(Color.inkGreen)
                        } else {
                            Text("Export & Share")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.inkGreen)
                        }
                    }
                    .disabled(isExporting || (exportConfig.isPasswordProtected && !isPasswordValid))
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .alert("Export Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An unexpected error occurred during PDF generation.")
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.inkGreen)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pdf.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(document.pageCount) Pages")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("•")
                            .foregroundStyle(.secondary)

                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.inkGreen)
                                .frame(width: 6, height: 6)
                            Text("100% On-Device • Air-Gapped")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.inkGreen)
                        }
                    }
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
            )
        }
    }

    // MARK: - Persona Selector Section

    private var personaSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EXPORT PERSONA")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 10) {
                ForEach(PDFExportFormat.allCases) { format in
                    let isSelected = exportConfig.format == format

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            exportConfig.format = format
                        }
                        HapticEngine.selection()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: format.iconName)
                                .font(.system(size: 20, weight: isSelected ? .bold : .semibold))
                                .foregroundStyle(isSelected ? Color.inkGreen : .secondary)
                                .frame(width: 28, height: 28)
                                .padding(4)
                                .background(
                                    Circle()
                                        .fill(isSelected ? Color.inkGreen.opacity(0.12) : Color.primary.opacity(0.04))
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(format.title)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.primary)

                                    if format == .flattened {
                                        Text("RECOMMENDED")
                                            .font(.system(size: 9, weight: .heavy))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.inkGreen.opacity(0.15), in: Capsule())
                                            .foregroundStyle(Color.inkGreen)
                                    }

                                    Spacer()

                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(isSelected ? Color.inkGreen : Color.secondary.opacity(0.4))
                                }

                                Text(format.subtitle)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(isSelected ? Color.inkGreen : Color.clear, lineWidth: 1.5)
                                )
                                .shadow(color: Color.black.opacity(isSelected ? 0.08 : 0.02), radius: 6, y: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Privacy Sentinel Callout

    @ViewBuilder
    private var privacySentinelBanner: some View {
        if exportConfig.format == .editableAnnotations {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Redaction Vulnerability Notice")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.orange)

                    Text("In Editable Annotations mode, ink strokes float above document text. Anyone in Adobe Acrobat or Apple Preview can click and delete the ink or select underlying text. For permanent redaction of confidential data, select 'Flattened'.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 0.8))
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.inkGreen)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Tamper-Proof Protection Active")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkGreen)

                    Text("All handwritten notes, highlights, and annotations will be burned directly into the page bitmap stream. They cannot be unstacked, selected, or recovered by recipients.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.inkGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.inkGreen.opacity(0.25), lineWidth: 0.8))
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    // MARK: - Layer Inclusions Section

    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LAYERS TO INCLUDE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Toggle(isOn: $exportConfig.includeHandwrittenInk) {
                    HStack(spacing: 10) {
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.inkBlue)
                            .frame(width: 24)

                        Text("Handwritten Ink & Pencil Notes")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .padding(14)

                Divider()
                    .padding(.leading, 48)

                Toggle(isOn: $exportConfig.includeTextHighlights) {
                    HStack(spacing: 10) {
                        Image(systemName: "highlighter")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.inkAmber)
                            .frame(width: 24)

                        Text("Text Highlights & Underlines")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
    }

    // MARK: - Security & Password Section (Tier 2)

    private var isPasswordValid: Bool {
        let trimmed = exportConfig.userPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SECURITY & ENCRYPTION (AES-256)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Toggle(isOn: $exportConfig.isPasswordProtected) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(exportConfig.isPasswordProtected ? Color.inkRed : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Password Protect Document")
                                .font(.system(size: 13, weight: .semibold))

                            Text("Requires password to view or print")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)

                if exportConfig.isPasswordProtected {
                    Divider()
                        .padding(.leading, 48)

                    VStack(spacing: 12) {
                        SecureField("Document Open Password", text: $exportConfig.userPassword)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                        SecureField("Confirm Password", text: $confirmPassword)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                        if !exportConfig.userPassword.isEmpty && !confirmPassword.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: isPasswordValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(isPasswordValid ? Color.inkGreen : Color.inkRed)
                                    .font(.system(size: 12))

                                Text(isPasswordValid ? "Passwords match" : "Passwords do not match")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isPasswordValid ? Color.inkGreen : Color.inkRed)

                                Spacer()
                            }
                        }

                        // Permissions
                        VStack(spacing: 8) {
                            Toggle("Allow Printing", isOn: $exportConfig.allowPrinting)
                                .font(.system(size: 12, weight: .medium))

                            Toggle("Allow Copying Content", isOn: $exportConfig.allowCopying)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.top, 4)
                    }
                    .padding(14)
                    .transition(.opacity)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
    }

    // MARK: - Metadata Sanitization Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DATA PRIVACY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Toggle(isOn: $exportConfig.stripInternalMetadata) {
                    HStack(spacing: 10) {
                        Image(systemName: "shield.checkerboard")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.inkGreen)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sanitize Metadata & File Paths")
                                .font(.system(size: 13, weight: .semibold))

                            Text("Removes internal database IDs, device identifiers, and local file paths from PDF dictionary")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
    }

    // MARK: - Export Action

    private func startExportPipeline() {
        guard !isExporting else { return }

        if exportConfig.isPasswordProtected && !isPasswordValid {
            errorMessage = "Please enter and confirm matching passwords before exporting."
            showErrorAlert = true
            HapticEngine.error()
            return
        }

        isExporting = true
        HapticEngine.medium()

        Task {
            do {
                let url = try await PDFSecureExportService.shared.exportPDF(
                    for: pdf.id,
                    document: document,
                    title: pdf.name,
                    config: exportConfig
                )

                await MainActor.run {
                    self.exportedFileURL = url
                    self.isExporting = false
                    self.showShareSheet = true
                    HapticEngine.success()
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = error.localizedDescription
                    self.showErrorAlert = true
                    HapticEngine.error()
                }
            }
        }
    }
}
