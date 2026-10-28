import SwiftUI

/// Sign in to (or create) the household NucFlix account: Google, or email + password.
struct CloudAuthView: View {
    @Environment(CloudAccount.self) var cloud

    @State private var creating = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var resetSent = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case name, email, password }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6 && (!creating || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        ZStack {
            ObsidianBackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        NucFlixWordmark(height: 54)
                        Text(creating ? "Create your NucFlix account" : "Sign in to NucFlix")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        Text("One account for your iPhone and TVs: profiles, My List and Continue Watching follow you everywhere.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 36)

                    Button {
                        Task { await cloud.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "g.circle.fill")
                                .font(.title3)
                            Text("Continue with Google")
                                .font(.headline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.black)
                    }
                    .disabled(cloud.isBusy)

                    HStack {
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                        Text("or use email").font(.caption).foregroundStyle(.white.opacity(0.5))
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                    }

                    VStack(spacing: 14) {
                        if creating {
                            field("Your name", icon: "person.fill", text: $name, content: .name)
                                .focused($focused, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focused = .email }
                        }
                        field("Email", icon: "envelope.fill", text: $email, content: .emailAddress, keyboard: .emailAddress)
                            .focused($focused, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focused = .password }
                        field("Password (6+ characters)", icon: "key.fill", text: $password,
                              content: creating ? .newPassword : .password, secure: true)
                            .focused($focused, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    }
                    .padding(18)
                    .obsidianGlassCard(cornerRadius: 22)

                    if let error = cloud.authError {
                        message(error, icon: "exclamationmark.octagon.fill", color: AppTheme.primaryRed)
                    } else if resetSent {
                        message("Password reset email sent to \(email).", icon: "envelope.badge", color: AppTheme.matchGreen)
                    }

                    Button(action: submit) {
                        HStack(spacing: 10) {
                            if cloud.isBusy { ProgressView().tint(.white) }
                            Text(creating ? "Create Account" : "Sign In")
                                .font(.headline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canSubmit ? AnyShapeStyle(AppTheme.accentGradient) : AnyShapeStyle(Color.gray.opacity(0.3)),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                    }
                    .disabled(!canSubmit || cloud.isBusy)

                    HStack {
                        Button(creating ? "I already have an account" : "Create an account") {
                            withAnimation(.snappy) { creating.toggle() }
                            cloud.authError = nil
                            resetSent = false
                        }
                        Spacer()
                        if !creating {
                            Button("Forgot password?") {
                                Task { resetSent = await cloud.sendPasswordReset(email: email) }
                            }
                            .disabled(!email.contains("@"))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 32)
            }
        }
    }

    private func submit() {
        guard canSubmit, !cloud.isBusy else { return }
        focused = nil
        resetSent = false
        let mail = email.trimmingCharacters(in: .whitespaces)
        Task {
            if creating {
                await cloud.signUp(name: name.trimmingCharacters(in: .whitespaces), email: mail, password: password)
            } else {
                await cloud.signIn(email: mail, password: password)
            }
        }
    }

    private func field(_ placeholder: String, icon: String, text: Binding<String>, content: UITextContentType,
                       keyboard: UIKeyboardType = .default, secure: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.primaryRed)
                .frame(width: 20)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textContentType(content)
            .keyboardType(keyboard)
            .textInputAutocapitalization(content == .name ? .words : .never)
            .autocorrectionDisabled()
            .foregroundStyle(.white)
        }
        .padding(14)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.8))
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.footnote).foregroundStyle(.white)
            Spacer()
        }
        .padding(14)
        .obsidianGlassCard(cornerRadius: 14)
    }
}

/// The NUCFLIX wordmark, letters slightly taller towards the ends like the TV app's logo.
struct NucFlixWordmark: View {
    var height: CGFloat = 40
    private let scales: [CGFloat] = [1.17, 1.075, 1.02, 1, 1.02, 1.075, 1.17]

    var body: some View {
        HStack(spacing: height * 0.04) {
            ForEach(Array("NUCFLIX".enumerated()), id: \.offset) { index, letter in
                Text(String(letter))
                    .font(.system(size: height, weight: .black, design: .default).width(.condensed))
                    .scaleEffect(x: 1, y: scales[index])
            }
        }
        .foregroundStyle(AppTheme.netflixRed)
        .accessibilityLabel("NUCFLIX")
    }
}
