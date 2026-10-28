import SwiftUI

/// Adds or edits an Xtream Codes line in the household account. The login is checked against the provider
/// before it's saved, and lives only in Firestore (never on the device).
struct LineFormView: View {
    @Environment(CloudAccount.self) var cloud
    @Environment(\.dismiss) private var dismiss

    /// The line being edited, or nil to add a new one.
    var editing: CloudLine? = nil
    /// Shown as a full screen when the account has no line yet (no Cancel button then).
    var isFirstLine = false
    var onSaved: (CloudLine) -> Void = { _ in }

    @State private var lineName: String = ""
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showPassword: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case profile, server, username, password
    }

    private var isFormValid: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ObsidianBackgroundView()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 26) {
                        headerSection

                        credentialsCard

                        if let error = cloud.authError {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.octagon.fill")
                                    .foregroundStyle(AppTheme.primaryRed)
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(14)
                            .obsidianGlassCard(cornerRadius: 14)
                        }

                        actionButtons
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 32)
                }
            }
            .toolbar {
                if !isFirstLine {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(.white)
                    }
                }
            }
            .onAppear {
                cloud.authError = nil
                if let line = editing {
                    lineName = line.name
                    serverURL = line.serverURL
                    username = line.username
                    password = line.password
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AppTheme.accentGradient)
                    .frame(width: 78, height: 78)
                    .shadow(color: AppTheme.primaryRed.opacity(0.45), radius: 20, y: 8)

                Image(systemName: "play.tv.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text(editing == nil ? "Add an IPTV Line" : "Edit IPTV Line")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text("Your Xtream Codes login is saved to your NucFlix account,\nshared by every profile and your TVs.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var credentialsCard: some View {
        VStack(spacing: 16) {
            inputField(
                title: "Line Name",
                icon: "sparkles.tv",
                placeholder: "My IPTV",
                text: $lineName
            )
            .focused($focusedField, equals: .profile)
            .submitLabel(.next)
            .onSubmit { focusedField = .server }

            inputField(
                title: "Server URL",
                icon: "server.rack",
                placeholder: "http://your-provider.com:8080",
                text: $serverURL,
                keyboardType: .URL
            )
            .focused($focusedField, equals: .server)
            .submitLabel(.next)
            .onSubmit { focusedField = .username }
            .onChange(of: serverURL) { _, newValue in
                autoParseM3UOrPlayerURLIfPasted(newValue)
            }

            inputField(
                title: "Username",
                icon: "person.fill",
                placeholder: "Username",
                text: $username
            )
            .focused($focusedField, equals: .username)
            .submitLabel(.next)
            .onSubmit { focusedField = .password }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))

                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(AppTheme.primaryRed)
                        .frame(width: 20)

                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // Not .password: that made iOS offer to save the Xtream login to iCloud Keychain, and
                    // lines are meant to live only in the NucFlix account.
                    .textContentType(.oneTimeCode)
                    .foregroundStyle(.white)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(14)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.8)
                )
            }
        }
        .padding(18)
        .obsidianGlassCard(cornerRadius: 22)
    }

    private func inputField(
        title: String,
        icon: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.75))

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(AppTheme.primaryRed)
                    .frame(width: 20)

                TextField(placeholder, text: text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
            }
            .padding(14)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.8)
            )
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                submit()
            } label: {
                HStack(spacing: 10) {
                    if cloud.isBusy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(cloud.isBusy ? "Checking with your provider..." : (editing == nil ? "Add Line" : "Save"))
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    isFormValid
                        ? AnyShapeStyle(AppTheme.accentGradient)
                        : AnyShapeStyle(Color.gray.opacity(0.3)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .foregroundStyle(.white)
                .shadow(color: AppTheme.primaryRed.opacity(0.4), radius: 14, y: 6)
            }
            .disabled(!isFormValid || cloud.isBusy)
        }
    }

    private func submit() {
        guard isFormValid, !cloud.isBusy else { return }
        focusedField = nil
        let trimmedName = lineName.trimmingCharacters(in: .whitespaces)
        Task {
            let saved = await cloud.saveLine(
                id: editing?.id,
                name: trimmedName.isEmpty ? (URL(string: serverURL)?.host ?? "My IPTV") : trimmedName,
                serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespaces),
                password: password.trimmingCharacters(in: .whitespaces)
            )
            if let saved {
                onSaved(saved)
                if !isFirstLine { dismiss() }
            }
        }
    }

    private func autoParseM3UOrPlayerURLIfPasted(_ raw: String) {
        guard raw.contains("username="),
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let queryItems = components.queryItems else {
            return
        }
        if let extractedUser = queryItems.first(where: { $0.name.lowercased() == "username" })?.value,
           !extractedUser.isEmpty {
            username = extractedUser
        }
        if let extractedPass = queryItems.first(where: { $0.name.lowercased() == "password" })?.value,
           !extractedPass.isEmpty {
            password = extractedPass
        }
        if let scheme = components.scheme, let host = components.host {
            let portStr = components.port.map { ":\($0)" } ?? ""
            serverURL = "\(scheme)://\(host)\(portStr)"
        }
    }
}
