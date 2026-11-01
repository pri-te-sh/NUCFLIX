import SwiftUI
import CoreImage.CIFilterBuiltins
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// MARK: - The new phone

/// "Sign in with another device" on the phone being signed in: it gets a code from the deviceSignIn Cloud Function
/// (signed in anonymously just for that), shows it as text and a QR code, and waits for a phone that's signed in to
/// approve it. The approval arrives on deviceSignIn/{code}; the code is then swapped for a sign-in token.
@MainActor
@Observable
final class DeviceSignInSession {
    enum State: Equatable {
        case starting
        case waiting(code: String, expires: Date)
        case signingIn
        case failed(String)
    }

    private(set) var state: State = .starting

    @ObservationIgnored private var listener: ListenerRegistration?
    @ObservationIgnored private var renew: Task<Void, Never>?

    private var callable: HTTPSCallable { Functions.functions(region: SmartAI.region).httpsCallable("deviceSignIn") }

    func start() async {
        stopWaiting()
        state = .starting
        do {
            if Auth.auth().currentUser?.isAnonymous != true {
                try await Auth.auth().signInAnonymously()
            }
            let result = try await callable.call(["action": "start", "name": UIDevice.current.name, "platform": "ios"])
            let data = result.data as? [String: Any] ?? [:]
            guard let code = data["code"] as? String, let millis = (data["expiresAt"] as? NSNumber)?.doubleValue else {
                throw CloudError.message("Couldn't get a code. Try again.")
            }
            let expires = Date(timeIntervalSince1970: millis / 1000)
            state = .waiting(code: code, expires: expires)
            listener = Firestore.firestore().collection("deviceSignIn").document(code).addSnapshotListener { [weak self] snap, _ in
                guard snap?.get("status") as? String == "approved" else { return }
                Task { @MainActor in await self?.redeem(code) }
            }
            // An unused code expires: show a fresh one.
            renew = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(expires.timeIntervalSinceNow, 1)))
                guard !Task.isCancelled else { return }
                await self?.start()
            }
        } catch {
            state = .failed(CloudAccount.describe(error))
        }
    }

    private func redeem(_ code: String) async {
        guard case .waiting(let waiting, _) = state, waiting == code else { return }
        stopWaiting()
        state = .signingIn
        do {
            let result = try await callable.call(["action": "redeem", "code": code])
            guard let token = (result.data as? [String: Any])?["token"] as? String else {
                throw CloudError.message("The approval didn't come through. Try again.")
            }
            // CloudAccount picks the account up from here, like any other sign-in.
            try await Auth.auth().signIn(withCustomToken: token)
        } catch {
            state = .failed(CloudAccount.describe(error))
        }
    }

    /// Stops waiting; the anonymous user only existed to ask for the code, so it goes too.
    func cancel() {
        stopWaiting()
        if let user = Auth.auth().currentUser, user.isAnonymous {
            user.delete { _ in }
        }
    }

    private func stopWaiting() {
        listener?.remove()
        listener = nil
        renew?.cancel()
        renew = nil
    }
}

struct DeviceSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = DeviceSignInSession()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text("On a phone or tablet that's already signed in to NucFlix, open **Account → Sign in another device** and enter this code, or scan the QR code with its camera.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)

                    switch session.state {
                    case .starting:
                        ProgressView().tint(.white).frame(height: 300)
                    case .waiting(let code, let expires):
                        waiting(code: code, expires: expires)
                    case .signingIn:
                        VStack(spacing: 14) {
                            ProgressView().tint(.white)
                            Text("Approved. Signing in…").font(.headline)
                        }
                        .frame(height: 300)
                    case .failed(let message):
                        VStack(spacing: 16) {
                            Label(message, systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(AppTheme.primaryRed)
                            Button("Try Again") { Task { await session.start() } }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.netflixRed)
                        }
                        .frame(minHeight: 300)
                    }
                }
                .padding(22)
            }
            .background(Color.black)
            .navigationTitle("Sign in with another device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .task { await session.start() }
        .onDisappear { if session.state != .signingIn { session.cancel() } }
    }

    private func waiting(code: String, expires: Date) -> some View {
        VStack(spacing: 18) {
            Text(code)
                .font(.system(size: 38, weight: .bold, design: .monospaced))
                .tracking(6)
                .textSelection(.enabled)
            if let qr = Self.qrCode("nucflix://signin?code=\(code)") {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .frame(width: 230, height: 230)
                    .accessibilityLabel("QR code for \(code)")
            }
            HStack(spacing: 8) {
                ProgressView().tint(.white.opacity(0.7))
                Text("Waiting for approval")
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            Text("New code in \(Text(expires, style: .timer))")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
            Button("Get a New Code") { Task { await session.start() } }
                .font(.subheadline.weight(.semibold))
        }
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - The phone that's signed in

/// Lets another phone or tablet into this account: enter the code it shows (or scan its QR code with the camera,
/// which opens this with the code filled in), check which device it is, then approve.
struct ApproveDeviceView: View {
    @Environment(CloudAccount.self) var cloud
    @Environment(\.dismiss) private var dismiss
    var initialCode: String?

    @State private var code = ""
    @State private var device: CloudAccount.WaitingDevice?
    @State private var approved: CloudAccount.WaitingDevice?
    @FocusState private var focused: Bool

    private var normalizedCode: String { code.uppercased().filter { $0.isLetter || $0.isNumber } }

    var body: some View {
        NavigationStack {
            List {
                if let approved {
                    Section {
                        Label("\(approved.name) is signed in to your account.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.matchGreen)
                    }
                } else if let device {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text("Sign in \(Text(device.name).bold())?")
                            } icon: {
                                Image(systemName: device.platform == "android" ? "candybarphone" : "iphone")
                            }
                            .font(.title3)
                            Text("It gets this whole account, like this \(UIDevice.current.model): every profile, your IPTV lines, My List and Continue Watching. Only approve a device you have with you.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button(action: approve) {
                                HStack {
                                    Spacer()
                                    if cloud.isBusy { ProgressView().tint(.white) }
                                    Text("Approve").font(.headline)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.netflixRed)
                            .disabled(cloud.isBusy)
                            Button("Not Now") { dismiss() }
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("On the phone or tablet you want to sign in, open NucFlix and choose **Sign in with another device**. Enter the code it shows, or scan its QR code with this \(UIDevice.current.model)'s camera.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("K7Q2M9XD", text: $code)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused($focused)
                                .submitLabel(.go)
                                .onSubmit(lookUp)
                                .tracking(6)
                            Button(action: lookUp) {
                                HStack {
                                    Spacer()
                                    if cloud.isBusy { ProgressView().tint(.white) }
                                    Text("Continue").font(.headline)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.netflixRed)
                            .disabled(normalizedCode.count != 8 || cloud.isBusy)
                        }
                        .padding(.vertical, 6)
                    }
                }
                if let error = cloud.authError {
                    Section { Text(error).foregroundStyle(AppTheme.primaryRed) }
                }
            }
            .navigationTitle("Sign in another device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                cloud.authError = nil
                if let initialCode {
                    code = initialCode
                    lookUp()
                } else {
                    focused = true
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func lookUp() {
        guard normalizedCode.count == 8 else { return }
        focused = false
        let entered = normalizedCode
        Task { device = await cloud.lookUpDeviceSignIn(code: entered) }
    }

    private func approve() {
        let entered = normalizedCode
        Task {
            if let done = await cloud.approveDeviceSignIn(code: entered) {
                approved = done
                device = nil
                code = ""
            }
        }
    }
}
