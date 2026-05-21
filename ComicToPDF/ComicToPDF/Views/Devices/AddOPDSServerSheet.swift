import SwiftUI
import SwiftData

// MARK: - Add OPDS Server Sheet

struct AddOPDSServerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Step state
    @State private var serverType: OPDSServerType = .kavita
    @State private var serverName: String = ""
    @State private var baseURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""   // Kavita: login password (exchanged for JWT); others: Basic Auth

    // Test connection
    @State private var testState: TestState = .idle
    @State private var testResultTitle: String = ""

    enum TestState {
        case idle, testing, success, failure(String)
        var isSuccess: Bool { if case .success = self { return true } else { return false } }
    }

    private var canTest: Bool {
        !baseURL.isEmpty &&
        !password.isEmpty &&
        (serverType.requiresUsername ? !username.isEmpty : true)
    }

    private var canSave: Bool { testState.isSuccess && !serverName.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                // Ambient glow
                Circle()
                    .fill(Color.inkBlue.opacity(0.1))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: 120, y: -120)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {

                        // ── 1. Server Type ───────────────────────────────
                        sectionLabel("SERVER TYPE")
                        serverTypePicker

                        // ── 2. Connection Details ────────────────────────
                        sectionLabel("SERVER URL")
                        urlField

                        if serverType.requiresUsername {
                            sectionLabel("USERNAME")
                            inputField("e.g. admin", text: $username, keyboard: .default, secure: false)
                        }

                        sectionLabel(serverType.credentialLabel)
                        credentialField

                        // ── 3. Server Name ───────────────────────────────
                        sectionLabel("DISPLAY NAME")
                        inputField("e.g. Home Kavita", text: $serverName, keyboard: .default, secure: false)

                        // ── 4. Test Connection ───────────────────────────
                        testConnectionSection

                    }
                    .padding(24)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.inkTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveServer() }
                        .disabled(!canSave)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSave ? Color.inkBlue : Color.inkTextSecondary)
                }
            }
        }
    }

    // MARK: - Server Type Picker

    private var serverTypePicker: some View {
        VStack(spacing: 10) {
            ForEach(OPDSServerType.allCases) { type in
                let isSelected = serverType == type
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        serverType = type
                        testState = .idle   // reset test when type changes
                    }
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(type.tint.opacity(isSelected ? 0.2 : 0.1))
                                .frame(width: 40, height: 40)
                            Image(systemName: type.sfSymbol)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(type.tint)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(type.rawValue)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.inkTextPrimary : Color.inkTextSecondary)
                            Text(type.description)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.inkTextSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(type.tint)
                                .font(.system(size: 18))
                        }
                    }
                    .padding(14)
                    .background(
                        isSelected ? type.tint.opacity(0.08) : Color.inkSurface.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? type.tint.opacity(0.35) : Color.inkTextPrimary.opacity(0.07), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: serverType)
            }
        }
    }

    // MARK: - Fields

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            inputField(serverType.exampleURL, text: $baseURL, keyboard: .URL, secure: false)
                .onChange(of: baseURL) { testState = .idle }

            Text("Include the port if it's not 80 or 443 (e.g. :8080)")
                .font(.system(size: 11))
                .foregroundStyle(Color.inkTextSecondary)
                .padding(.leading, 4)
        }
    }

    private var credentialField: some View {
        VStack(alignment: .leading, spacing: 6) {
            inputField(serverType == .kavita ? "••••••••••••" : "Password", text: $password, keyboard: .default, secure: true)
                .onChange(of: password) { testState = .idle }

            if serverType == .kavita {
                Text("Your Kavita account password. It is exchanged for a secure JWT token and never stored.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkTextSecondary)
                    .lineSpacing(2)
                    .padding(.leading, 4)
            }
        }
    }

    private func inputField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(Color.inkTextPrimary)
        .padding(14)
        .background(Color.inkSurface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.inkTextPrimary.opacity(0.1), lineWidth: 1)
        )
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.inkTextSecondary)
            .tracking(1.2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Test Connection Section

    private var testConnectionSection: some View {
        VStack(spacing: 14) {
            Button {
                Task { await runTest() }
            } label: {
                HStack(spacing: 10) {
                    if case .testing = testState {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: testState.isSuccess ? "checkmark.circle.fill" : "wifi")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(testState.isSuccess ? "Connected" : "Test Connection")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    testState.isSuccess
                        ? AnyShapeStyle(Color.inkGreen)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color.inkBlue, Color.inkViolet.opacity(0.8)],
                            startPoint: .leading, endPoint: .trailing
                        )),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .shadow(
                    color: testState.isSuccess ? Color.inkGreen.opacity(0.35) : Color.inkBlue.opacity(0.35),
                    radius: 10, y: 5
                )
                .opacity(canTest ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!canTest || (testState == .testing))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: testState.isSuccess)

            // Result message
            switch testState {
            case .success:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.inkGreen)
                    Text("Connected to "\(testResultTitle)"")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkGreen)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

            case .failure(let msg):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.inkAmber)
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkAmber)
                        .lineLimit(3)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

            default: EmptyView()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: testState.isSuccess)
    }

    // MARK: - Actions

    private func runTest() async {
        withAnimation { testState = .testing }

        // Normalize URL
        var cleaned = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }

        // Build a temporary server object for the test
        let tempServer = SDOPDSServer(
            name: serverName.isEmpty ? serverType.rawValue : serverName,
            serverType: serverType,
            baseURLString: cleaned
        )

        // Pre-save the basic credential so the client can find it during testConnection
        let tempCred = OPDSCredential(username: username, password: password)
        OPDSKeychainStore.save(tempCred, for: tempServer.id)

        do {
            let title = try await OPDSClient.shared.testConnection(
                server: tempServer,
                email: serverType == .kavita ? username.isEmpty ? cleaned : username : nil,
                password: serverType == .kavita ? password : nil
            )
            OPDSKeychainStore.delete(for: tempServer.id)   // cleanup temp entry

            withAnimation {
                testResultTitle = title
                testState = .success
                // Auto-fill display name from catalog title if blank
                if serverName.isEmpty { serverName = title }
                // Store normalized URL
                baseURL = cleaned
            }
            Logger.shared.log("AddOPDSServerSheet: test success — '\(title)'", category: "OPDS")
        } catch {
            OPDSKeychainStore.delete(for: tempServer.id)
            withAnimation { testState = .failure(error.localizedDescription) }
            Logger.shared.log("AddOPDSServerSheet: test failed — \(error)", category: "OPDS", type: .error)
        }
    }

    private func saveServer() {
        var cleaned = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }

        let server = SDOPDSServer(
            name: serverName,
            serverType: serverType,
            baseURLString: cleaned
        )

        // For Kavita: the JWT was already stored in Keychain by kavitaLogin during test.
        // For Komga/Calibre: store Basic Auth credential now.
        if serverType != .kavita {
            let cred = OPDSCredential(username: username, password: password)
            OPDSKeychainStore.save(cred, for: server.id)
        } else {
            // Re-run JWT login for the real server ID (test used a temp ID)
            Task {
                try? await OPDSClient.shared.kavitaLogin(server: server, email: username, password: password)
            }
        }

        modelContext.insert(server)
        try? modelContext.save()
        Logger.shared.log("AddOPDSServerSheet: saved server '\(server.name)' (\(serverType.rawValue))", category: "OPDS")
        dismiss()
    }
}

// MARK: - TestState Equatable (for disabled check)
extension AddOPDSServerSheet.TestState: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.testing, .testing), (.success, .success): return true
        case (.failure(let a), .failure(let b)): return a == b
        default: return false
        }
    }
}
