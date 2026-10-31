import Foundation
import UIKit
import CryptoKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import GoogleSignIn

// MARK: - Firebase bootstrap

enum CloudBootstrap {
    /// Launch argument that points Auth, Firestore and Functions at the local emulators (used for testing on the simulator).
    static let emulatorFlag = "-useFirebaseEmulator"

    static func configure() {
        guard FirebaseApp.app() == nil else { return }
        FirebaseApp.configure()
        let db = Firestore.firestore()
        let settings = FirestoreSettings()
        // Memory-only cache: nothing from Firestore — Xtream logins included — is ever written to disk.
        settings.cacheSettings = MemoryCacheSettings()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(emulatorFlag) {
            settings.host = "127.0.0.1:8181"
            settings.isSSLEnabled = false
            Auth.auth().useEmulator(withHost: "127.0.0.1", port: 9099)
            Functions.functions(region: SmartAI.region).useEmulator(withHost: "127.0.0.1", port: 5001)
        }
        #endif
        db.settings = settings
    }
}

// MARK: - Household data

/// An Xtream Codes line. Profile-agnostic: any profile in the household plays through it.
struct CloudLine: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var serverURL: String
    var username: String
    var password: String

    var credentials: XtreamCredentials {
        XtreamCredentials(lineName: name, serverURL: serverURL, username: username, password: password)
    }

    init(id: String, name: String, serverURL: String, username: String, password: String) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }

    init?(id: String, data: [String: Any]) {
        guard let serverURL = data["serverURL"] as? String, let username = data["username"] as? String else { return nil }
        self.id = id
        self.name = data["name"] as? String ?? "IPTV"
        self.serverURL = serverURL
        self.username = username
        self.password = data["password"] as? String ?? ""
    }
}

/// A person watching (you, kids, ...). Each has their own Continue Watching, My List and preferences.
struct CloudProfile: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var avatar: String
    var kids: Bool
    var order: Int
    // Synced settings (prefs map), shared with the Fire TV app.
    var autoplayNext: Bool
    var showAdult: Bool
    /// Profile Lock: SHA-256 of "nucflix-pin:<profileId>:<pin>" (same as the Fire TV app), empty when off.
    var pinHash: String

    /// Standard profiles may have a 4-digit PIN; kids profiles never do.
    var isLocked: Bool { !kids && !pinHash.isEmpty }

    static func pinHash(profileID: String, pin: String) -> String {
        SHA256.hash(data: Data("nucflix-pin:\(profileID):\(pin)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func pinMatches(_ pin: String) -> Bool { isLocked && Self.pinHash(profileID: id, pin: pin) == pinHash }

    static let avatarColors = ["red", "blue", "green", "yellow", "purple", "orange", "teal", "pink"]

    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.avatar = data["avatar"] as? String ?? "red"
        self.kids = data["kids"] as? Bool ?? false
        self.order = data["order"] as? Int ?? 0
        let prefs = data["prefs"] as? [String: Any] ?? [:]
        self.autoplayNext = prefs["autoplayNext"] as? Bool ?? true
        self.showAdult = !kids && (prefs["showAdult"] as? Bool ?? false)
        self.pinHash = prefs["pinHash"] as? String ?? ""
    }
}

// MARK: - Account store

/// Firebase session for the household: sign-in, the Xtream lines and the people profiles.
/// Lines are only ever held in memory (see `CloudBootstrap`); the device keeps just the IDs of the
/// chosen profile and line, which are not secret.
@MainActor
@Observable
final class CloudAccount {
    enum Phase: Equatable {
        case starting, signedOut, signedIn
    }

    private(set) var phase: Phase = .starting
    private(set) var uid: String?
    private(set) var email: String?
    private(set) var displayName: String?

    private(set) var lines: [CloudLine] = []
    private(set) var profiles: [CloudProfile] = []
    private(set) var linesLoaded = false
    private(set) var profilesLoaded = false

    private(set) var selectedProfileID: String?
    private(set) var activeLineID: String?
    /// Fire TVs allowed into this household (users/{uid}/members).
    private(set) var pairedTVs: [PairedTV] = []

    struct PairedTV: Identifiable, Equatable {
        let id: String
        let name: String
        let pairedAt: Date?
    }

    var authError: String?
    var isBusy = false

    @ObservationIgnored private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var listeners: [ListenerRegistration] = []
    @ObservationIgnored private var creatingFirstProfile = false
    @ObservationIgnored private let db = Firestore.firestore()

    var selectedProfile: CloudProfile? { profiles.first { $0.id == selectedProfileID } }
    var activeLine: CloudLine? { lines.first { $0.id == activeLineID } ?? lines.first }

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.handle(user: user) }
        }
    }

    // MARK: Session

    private func handle(user: User?) {
        listeners.forEach { $0.remove() }
        listeners = []
        lines = []
        profiles = []
        pairedTVs = []
        linesLoaded = false
        profilesLoaded = false
        guard let user, !user.isAnonymous else {
            uid = nil
            email = nil
            displayName = nil
            selectedProfileID = nil
            activeLineID = nil
            phase = .signedOut
            return
        }
        uid = user.uid
        email = user.email
        displayName = user.displayName
        selectedProfileID = UserDefaults.standard.string(forKey: Self.profileKey(user.uid))
        activeLineID = UserDefaults.standard.string(forKey: Self.lineKey(user.uid))
        phase = .signedIn
        startListening(uid: user.uid)
    }

    private func startListening(uid: String) {
        let userRef = db.collection("users").document(uid)
        userRef.setData(["name": displayName ?? email ?? "NucFlix", "updatedAt": FieldValue.serverTimestamp()], merge: true)

        listeners.append(userRef.collection("lines").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, self.uid == uid, let snap else { return }
                self.lines = snap.documents
                    .compactMap { CloudLine(id: $0.documentID, data: $0.data()) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.linesLoaded = true
                await self.ensureFirstProfile()
            }
        })
        listeners.append(userRef.collection("members").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, self.uid == uid, let snap else { return }
                self.pairedTVs = snap.documents.map {
                    PairedTV(id: $0.documentID, name: $0.get("name") as? String ?? "Fire TV",
                             pairedAt: ($0.get("pairedAt") as? Timestamp)?.dateValue())
                }.sorted { ($0.pairedAt ?? .distantPast) > ($1.pairedAt ?? .distantPast) }
            }
        })
        listeners.append(userRef.collection("profiles").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, self.uid == uid, let snap else { return }
                self.profiles = snap.documents
                    .compactMap { CloudProfile(id: $0.documentID, data: $0.data()) }
                    .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
                self.profilesLoaded = true
                if let selected = self.selectedProfileID, !self.profiles.contains(where: { $0.id == selected }) {
                    self.selectProfile(nil)
                }
                await self.ensureFirstProfile()
            }
        })
    }

    // MARK: Fire TV pairing

    /// Approves the code a Fire TV is showing: adds the TV as a member of this household and marks the
    /// code approved, in one batch (the security rules require both). Returns the TV's name.
    func approvePairing(code raw: String) async -> String? {
        guard let uid else { return nil }
        let code = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 8 else {
            authError = "Enter the 8-character code shown on your TV."
            return nil
        }
        var tvName: String?
        await run {
            let ref = db.collection("pairing").document(code)
            let snap = try await ref.getDocument()
            guard snap.exists, let data = snap.data() else {
                throw CloudError.message("No TV is showing that code. Check the code on the TV, or choose New Code there.")
            }
            guard data["status"] as? String == "pending", let tvUid = data["tvUid"] as? String else {
                throw CloudError.message("That code has already been used. Choose New Code on the TV.")
            }
            if let expires = (data["expiresAt"] as? Timestamp)?.dateValue(), expires < Date() {
                throw CloudError.message("That code has expired. Choose New Code on the TV.")
            }
            let name = (data["tvName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Fire TV"
            let batch = db.batch()
            batch.setData(["name": String(name.prefix(80)), "platform": "firetv", "pairedAt": FieldValue.serverTimestamp()],
                          forDocument: db.collection("users").document(uid).collection("members").document(tvUid))
            batch.updateData(["status": "approved", "ownerUid": uid,
                              "ownerName": String((displayName ?? email ?? "NucFlix").prefix(80)),
                              "approvedAt": FieldValue.serverTimestamp()], forDocument: ref)
            try await batch.commit()
            tvName = name
        }
        return tvName
    }

    func removeTV(_ tv: PairedTV) async {
        guard let uid else { return }
        await run { try await db.collection("users").document(uid).collection("members").document(tv.id).delete() }
    }

    func selectProfile(_ id: String?) {
        selectedProfileID = id
        guard let uid else { return }
        UserDefaults.standard.set(id, forKey: Self.profileKey(uid))
    }

    func selectLine(_ id: String?) {
        activeLineID = id
        guard let uid else { return }
        UserDefaults.standard.set(id, forKey: Self.lineKey(uid))
    }

    private static func profileKey(_ uid: String) -> String { "nucflix.cloud.profile.\(uid)" }
    private static func lineKey(_ uid: String) -> String { "nucflix.cloud.line.\(uid)" }

    // MARK: Sign-in

    func signInWithGoogle() async {
        guard let clientID = FirebaseApp.app()?.options.clientID,
              let presenter = Self.topViewController() else { return }
        await run {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw CloudError.message("Google didn't return an ID token. Please try again.")
            }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                           accessToken: result.user.accessToken.tokenString)
            try await Auth.auth().signIn(with: credential)
        }
    }

    func signIn(email: String, password: String) async {
        await run { try await Auth.auth().signIn(withEmail: email, password: password) }
    }

    func signUp(name: String, email: String, password: String) async {
        await run {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let change = result.user.createProfileChangeRequest()
            change.displayName = name
            try await change.commitChanges()
            self.displayName = name
        }
    }

    func sendPasswordReset(email: String) async -> Bool {
        var sent = false
        await run {
            try await Auth.auth().sendPasswordReset(withEmail: email)
            sent = true
        }
        return sent
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }

    /// Runs a cloud call with the busy flag set and a readable error on failure.
    private func run(_ work: () async throws -> Void) async {
        isBusy = true
        authError = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            if (error as NSError).domain == "com.google.GIDSignIn", (error as NSError).code == -5 { return } // cancelled
            authError = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        if case CloudError.message(let text) = error { return text }
        let ns = error as NSError
        if ns.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: ns.code) {
            switch code {
            case .wrongPassword, .invalidCredential, .userNotFound: return "That email and password don't match an account."
            case .emailAlreadyInUse: return "An account with this email already exists — sign in instead."
            case .weakPassword: return "Choose a password with at least 6 characters."
            case .invalidEmail: return "That doesn't look like a valid email address."
            case .networkError: return "No connection to NucFlix. Check your internet and try again."
            case .tooManyRequests: return "Too many attempts. Wait a moment and try again."
            default: break
            }
        }
        return ns.localizedDescription
    }

    // MARK: Lines

    /// Checks the line against the provider first, so only working logins (with the scheme that actually
    /// works — https or http) are saved.
    @discardableResult
    func saveLine(id: String? = nil, name: String, serverURL: String, username: String, password: String) async -> CloudLine? {
        guard let uid else { return nil }
        var saved: CloudLine?
        await run {
            let probe = XtreamCredentials(lineName: name, serverURL: serverURL, username: username, password: password)
            let (_, working) = try await XtreamAPIService.shared.authenticateResolvingScheme(credentials: probe)
            let ref = id.map { db.collection("users").document(uid).collection("lines").document($0) }
                ?? db.collection("users").document(uid).collection("lines").document()
            var data: [String: Any] = [
                "name": name, "serverURL": working.normalizedBaseURL, "username": username, "password": password,
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if id == nil { data["createdAt"] = FieldValue.serverTimestamp() }
            try await ref.setData(data, merge: true)
            saved = CloudLine(id: ref.documentID, name: name, serverURL: working.normalizedBaseURL,
                              username: username, password: password)
        }
        if let saved, activeLineID == nil { selectLine(saved.id) }
        return saved
    }

    func deleteLine(_ line: CloudLine) async {
        guard let uid else { return }
        await run { try await db.collection("users").document(uid).collection("lines").document(line.id).delete() }
        if activeLineID == line.id { selectLine(nil) }
    }

    // MARK: Profiles

    @discardableResult
    func saveProfile(id: String? = nil, name: String, avatar: String, kids: Bool) async -> String? {
        guard let uid else { return nil }
        let col = db.collection("users").document(uid).collection("profiles")
        let ref = id.map { col.document($0) } ?? col.document()
        var data: [String: Any] = ["name": name, "avatar": avatar, "kids": kids, "updatedAt": FieldValue.serverTimestamp()]
        if id == nil {
            data["createdAt"] = FieldValue.serverTimestamp()
            data["order"] = (profiles.map(\.order).max() ?? -1) + 1
            data["prefs"] = ["autoplayNext": true]
        }
        var ok = false
        await run {
            try await ref.setData(data, merge: true)
            ok = true
        }
        return ok ? ref.documentID : nil
    }

    /// Turns Profile Lock on (a PIN's hash, see `CloudProfile.pinHash`) or off (empty).
    func setProfilePin(_ profile: CloudProfile, hash: String) async {
        guard let uid else { return }
        let ref = db.collection("users").document(uid).collection("profiles").document(profile.id)
        await run { try await ref.setData(["prefs": ["pinHash": hash], "updatedAt": FieldValue.serverTimestamp()], merge: true) }
    }

    /// Deletes the profile and everything it watched or saved.
    func deleteProfile(_ profile: CloudProfile) async {
        guard let uid else { return }
        let ref = db.collection("users").document(uid).collection("profiles").document(profile.id)
        await run {
            for sub in ["progress", "favorites"] {
                let docs = try await ref.collection(sub).getDocuments().documents
                for chunk in stride(from: 0, to: docs.count, by: 400) {
                    let batch = db.batch()
                    docs[chunk..<min(chunk + 400, docs.count)].forEach { batch.deleteDocument($0.reference) }
                    try await batch.commit()
                }
            }
            try await ref.delete()
        }
        if selectedProfileID == profile.id { selectProfile(nil) }
    }

    // MARK: First sign-in

    /// A brand-new account gets one profile named after the signed-in person.
    private func ensureFirstProfile() async {
        guard uid != nil, linesLoaded, profilesLoaded, profiles.isEmpty, !creatingFirstProfile else { return }
        creatingFirstProfile = true
        await saveProfile(name: (displayName ?? email ?? "Me").components(separatedBy: CharacterSet(charactersIn: " @")).first ?? "Me",
                          avatar: "red", kids: false)
        creatingFirstProfile = false
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

enum CloudError: Error {
    case message(String)
}
