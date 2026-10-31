import SwiftUI
import LocalAuthentication

/// "Who's watching?" — the people profiles in the household account (synced with the TVs).
struct ProfilePickerView: View {
    @Environment(CloudAccount.self) var cloud
    @State private var editing = false
    @State private var editorTarget: EditorTarget?
    @State private var pinTarget: PinTarget?

    /// What a PIN unlocks: opening or editing a locked profile, or adding one while others are locked.
    private struct PinTarget: Identifiable {
        enum Action { case open, edit, add }
        let action: Action
        let profile: CloudProfile?
        var id: String { "\(action)-\(profile?.id ?? "")" }
    }

    private struct EditorTarget: Identifiable {
        let profile: CloudProfile?
        var id: String { profile?.id ?? "new" }
    }

    static let maxProfiles = 10
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 26)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 34) {
                HStack {
                    NucFlixWordmark(height: 30)
                    Spacer()
                    if !cloud.profiles.isEmpty {
                        Button(editing ? "Done" : "Edit") {
                            withAnimation(.snappy) { editing.toggle() }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                Text(editing ? "Manage Profiles" : "Who's watching?")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 30)

                LazyVGrid(columns: columns, spacing: 30) {
                    ForEach(cloud.profiles) { profile in
                        Button {
                            if profile.isLocked {
                                pinTarget = PinTarget(action: editing ? .edit : .open, profile: profile)
                            } else if editing {
                                editorTarget = EditorTarget(profile: profile)
                            } else {
                                cloud.selectProfile(profile.id)
                            }
                        } label: {
                            ProfileTile(profile: profile, editing: editing)
                        }
                        .buttonStyle(.plain)
                    }
                    if cloud.profiles.count < Self.maxProfiles {
                        Button {
                            // With locked profiles, adding one needs one of their PINs (else it's a way around them).
                            if cloud.profiles.contains(where: \.isLocked) {
                                pinTarget = PinTarget(action: .add, profile: nil)
                            } else {
                                editorTarget = EditorTarget(profile: nil)
                            }
                        } label: {
                            VStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(.white.opacity(0.45), lineWidth: 2)
                                    .frame(width: 110, height: 110)
                                    .overlay(Image(systemName: "plus").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.8)))
                                Text("Add Profile")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 30)

                Spacer()

                if let email = cloud.email {
                    VStack(spacing: 6) {
                        Text(email).font(.footnote).foregroundStyle(.white.opacity(0.45))
                        Button("Sign out of NucFlix") { cloud.signOut() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            ProfileEditorView(profile: target.profile)
                .environment(cloud)
        }
        .sheet(item: $pinTarget) { target in
            let locked = target.profile.map { [$0] } ?? cloud.profiles.filter(\.isLocked)
            PinPadView(
                title: target.profile.map { "Enter \($0.name)'s PIN" } ?? "Enter a profile PIN",
                subtitle: target.action == .add ? "Adding a profile needs the PIN of \(locked.map(\.name).joined(separator: " or "))." : nil,
                onForgot: { unlockWithDeviceOwner { unlocked(target) } }
            ) { pin in
                guard locked.contains(where: { $0.pinMatches(pin) }) else { return .wrong }
                unlocked(target)
                return .done
            }
            .presentationDetents([.large])
        }
    }

    private func unlocked(_ target: PinTarget) {
        pinTarget = nil
        switch target.action {
        case .open: if let p = target.profile { cloud.selectProfile(p.id) }
        case .edit: editorTarget = EditorTarget(profile: target.profile)
        case .add: editorTarget = EditorTarget(profile: nil)
        }
    }

    /// "Forgot PIN?": Face ID / Touch ID / the iPhone's passcode stands in for the PIN on the owner's phone.
    private func unlockWithDeviceOwner(_ then: @escaping () -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { then(); return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open a locked NucFlix profile") { ok, _ in
            if ok { DispatchQueue.main.async(execute: then) }
        }
    }
}

/// 4-digit PIN keypad. `onPin` decides: `.done` closes, `.wrong` shakes and clears, `.message` shows the next step.
struct PinPadView: View {
    enum Result { case done, wrong, message(String) }

    let title: String
    var subtitle: String?
    var onForgot: (() -> Void)?
    let onPin: (String) -> Result

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var message = ""
    @State private var shake = 0

    var body: some View {
        VStack(spacing: 26) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.8))
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center) }
            HStack(spacing: 22) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(.white.opacity(0.7), lineWidth: 2)
                        .background(Circle().fill(i < pin.count ? Color.white : .clear))
                        .frame(width: 18, height: 18)
                }
            }
            .modifier(ShakeEffect(shakes: CGFloat(shake)))
            .animation(.default, value: shake)
            Text(message).font(.footnote).foregroundStyle(AppTheme.netflixRed).frame(height: 18)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 22), count: 3), spacing: 18) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "forgot", "0", "del"], id: \.self) { key in
                    switch key {
                    case "forgot":
                        if let onForgot {
                            Button("Forgot?") { onForgot() }.font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        } else { Color.clear.frame(height: 72) }
                    case "del":
                        Button { if !pin.isEmpty { pin.removeLast() } } label: {
                            Image(systemName: "delete.left").font(.title2).foregroundStyle(.white).frame(width: 84, height: 72)
                        }
                    default:
                        Button { press(key) } label: {
                            Text(key).font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                                .frame(width: 72, height: 72)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func press(_ digit: String) {
        guard pin.count < 4 else { return }
        pin += digit
        message = ""
        guard pin.count == 4 else { return }
        let entered = pin
        pin = ""
        switch onPin(entered) {
        case .done: dismiss()
        case .wrong:
            message = "Wrong PIN. Try again."
            shake += 1
        case .message(let text): message = text
        }
    }
}

private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(shakes * .pi * 4), y: 0))
    }
}

struct ProfileTile: View {
    let profile: CloudProfile
    var editing = false
    var size: CGFloat = 110

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                ProfileAvatar(profile: profile, size: size)
                if editing {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.5))
                        .frame(width: size, height: size)
                    Image(systemName: "pencil")
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            Text(profile.name)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }
}

struct ProfileAvatar: View {
    let profile: CloudProfile
    var size: CGFloat = 110

    static func color(_ key: String) -> Color {
        switch key {
        case "blue": return Color(red: 0.12, green: 0.5, blue: 0.88)
        case "green": return Color(red: 0.16, green: 0.62, blue: 0.36)
        case "yellow": return Color(red: 0.95, green: 0.72, blue: 0.1)
        case "purple": return Color(red: 0.48, green: 0.28, blue: 0.85)
        case "orange": return Color(red: 0.96, green: 0.45, blue: 0.1)
        case "teal": return Color(red: 0.1, green: 0.6, blue: 0.62)
        case "pink": return Color(red: 0.93, green: 0.3, blue: 0.58)
        default: return AppTheme.netflixRed
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
            .fill(Self.color(profile.avatar).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(profile.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            )
            .overlay(alignment: .bottom) {
                if profile.kids {
                    Text("KIDS")
                        .font(.system(size: size * 0.12, weight: .black))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .padding(.bottom, size * 0.07)
                }
            }
    }
}

/// Asks for a new PIN twice, then hands it to `onChosen`.
private struct PinChooser: View {
    let onChosen: (String) -> Void
    @State private var first: String?

    var body: some View {
        PinPadView(title: first == nil ? "Choose a 4-digit PIN" : "Enter the PIN again") { pin in
            guard let chosen = first else {
                first = pin
                return .message("Enter the same PIN again")
            }
            guard pin == chosen else {
                first = nil
                return .message("Those PINs didn't match. Choose a PIN again.")
            }
            onChosen(pin)
            return .done
        }
    }
}

/// Add or edit a person profile (name, colour, kids).
struct ProfileEditorView: View {
    @Environment(CloudAccount.self) var cloud
    @Environment(\.dismiss) private var dismiss
    let profile: CloudProfile?

    @State private var name = ""
    @State private var avatar = "red"
    @State private var kids = false
    @State private var confirmDelete = false
    @State private var choosingPin = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatar(profile: preview, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                        ForEach(CloudProfile.avatarColors, id: \.self) { key in
                            Circle()
                                .fill(ProfileAvatar.color(key))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(.white, lineWidth: avatar == key ? 3 : 0))
                                .onTapGesture { avatar = key }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Toggle("Kids profile", isOn: $kids)
                } footer: {
                    Text("Kids profiles never show adult content.")
                }
                if let profile, !kids {
                    Section {
                        if lockedNow {
                            Button("Change PIN") { choosingPin = true }
                            Button("Turn Off Profile Lock", role: .destructive) {
                                Task { await cloud.setProfilePin(profile, hash: "") }
                            }
                        } else {
                            Button("Turn On Profile Lock") { choosingPin = true }
                        }
                    } header: {
                        Text("Profile Lock")
                    } footer: {
                        Text(lockedNow ? "A 4-digit PIN is needed to open or edit this profile on every device."
                             : "Ask for a 4-digit PIN to open this profile on the iPhone and your TVs.")
                    }
                }
                if let error = cloud.authError {
                    Section { Text(error).foregroundStyle(AppTheme.primaryRed) }
                }
                if profile != nil {
                    Section {
                        Button("Delete Profile", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Removes this profile's My List and Continue Watching on all devices.")
                    }
                }
            }
            .navigationTitle(profile == nil ? "Add Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await cloud.saveProfile(id: profile?.id, name: trimmed, avatar: avatar, kids: kids) != nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(trimmed.isEmpty || cloud.isBusy)
                }
            }
            .sheet(isPresented: $choosingPin) {
                if let profile { choosePinSheet(profile) }
            }
            .confirmationDialog("Delete \(profile?.name ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) {
                    guard let profile else { return }
                    Task {
                        await cloud.deleteProfile(profile)
                        dismiss()
                    }
                }
            }
            .onAppear {
                cloud.authError = nil
                if let profile {
                    name = profile.name
                    avatar = profile.avatar
                    kids = profile.kids
                } else {
                    avatar = CloudProfile.avatarColors.first { key in !cloud.profiles.contains { $0.avatar == key } } ?? "red"
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var trimmed: String { String(name.trimmingCharacters(in: .whitespaces).prefix(40)) }

    /// The live profile (the lock may change while the editor is open).
    private var lockedNow: Bool { cloud.profiles.first { $0.id == profile?.id }?.isLocked ?? false }

    @ViewBuilder
    private func choosePinSheet(_ profile: CloudProfile) -> some View {
        PinChooser { pin in
            Task { await cloud.setProfilePin(profile, hash: CloudProfile.pinHash(profileID: profile.id, pin: pin)) }
        }
    }

    private var preview: CloudProfile {
        CloudProfile(id: "preview", data: ["name": trimmed.isEmpty ? "?" : trimmed, "avatar": avatar, "kids": kids])!
    }
}
