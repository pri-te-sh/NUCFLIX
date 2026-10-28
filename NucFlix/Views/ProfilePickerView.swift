import SwiftUI

/// "Who's watching?" — the people profiles in the household account (synced with the TVs).
struct ProfilePickerView: View {
    @Environment(CloudAccount.self) var cloud
    @State private var editing = false
    @State private var editorTarget: EditorTarget?

    private struct EditorTarget: Identifiable {
        let profile: CloudProfile?
        var id: String { profile?.id ?? "new" }
    }

    static let maxProfiles = 5
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
                            if editing {
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
                            editorTarget = EditorTarget(profile: nil)
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

/// Add or edit a person profile (name, colour, kids).
struct ProfileEditorView: View {
    @Environment(CloudAccount.self) var cloud
    @Environment(\.dismiss) private var dismiss
    let profile: CloudProfile?

    @State private var name = ""
    @State private var avatar = "red"
    @State private var kids = false
    @State private var confirmDelete = false

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

    private var preview: CloudProfile {
        CloudProfile(id: "preview", data: ["name": trimmed.isEmpty ? "?" : trimmed, "avatar": avatar, "kids": kids])!
    }
}
