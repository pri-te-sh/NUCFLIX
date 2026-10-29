import Foundation
import UIKit
import AVFoundation
import CoreImage
import MobileVLCKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// NucFlix "smart" features: frame checks for credits / intros / dead channels, AI category tags and
/// natural-language search. The AI itself runs in Cloud Functions (Ollama Cloud: Clef decisions, Gemma 4);
/// nothing here ever blocks playback — every call can fail and the app carries on as before.
@MainActor
final class SmartAI {
    static let shared = SmartAI()
    static let region = "us-central1"

    /// Set when the household is out of AI budget or the service refuses us; reset on the next sign-in.
    private(set) var disabled = false
    private let db = Firestore.firestore()

    private var uid: String? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return user.uid
    }

    func reset() {
        disabled = false
        searchCache = [:]
    }

    private func call(_ name: String, _ data: [String: Any]) async -> [String: Any]? {
        guard !disabled, uid != nil else { return nil }
        let callable = Functions.functions(region: Self.region).httpsCallable(name)
        callable.timeoutInterval = 30
        do {
            return try await callable.call(data).data as? [String: Any]
        } catch {
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code),
               [.resourceExhausted, .permissionDenied, .unauthenticated].contains(code) {
                disabled = true
            }
            print("ai \(name): \(ns.localizedDescription)")
            return nil
        }
    }

    // MARK: - Frame checks

    struct FrameVerdict {
        let label: String
        let confidence: Double
        let probabilities: [String: Double]

        func p(_ label: String) -> Double { probabilities[label] ?? 0 }
    }

    /// Clef's verdict on one or two frames (task: credits, intro or live).
    func frameCheck(task: String, images: [Data], title: String?) async -> FrameVerdict? {
        var data: [String: Any] = ["task": task, "images": images.map { $0.base64EncodedString() }]
        if let title, !title.isEmpty { data["title"] = String(title.prefix(200)) }
        guard let res = await call("frameCheck", data), let label = res["label"] as? String else { return nil }
        let probs = (res["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return FrameVerdict(label: label, confidence: (res["confidence"] as? NSNumber)?.doubleValue ?? 0, probabilities: probs)
    }

    /// A ~512 px wide JPEG of a decoded video frame.
    nonisolated static func jpeg(from pixelBuffer: CVPixelBuffer, width: CGFloat = 512) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = width / max(image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.72)
    }

    nonisolated static func jpeg(from image: UIImage, width: CGFloat = 512) -> Data? {
        let size = CGSize(width: width, height: (width * image.size.height / max(image.size.width, 1)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.72)
    }

    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// VLC writes snapshots to disk asynchronously; waits up to ~3 s for the file.
    static func snapshot(_ player: VLCMediaPlayer) async -> Data? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nucflix-frame-\(UUID().uuidString).png").path
        player.saveVideoSnapshot(at: path, withWidth: 512, andHeight: 0)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var lastSize = -1
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if size > 0 && size == lastSize, let image = UIImage(contentsOfFile: path) {
                return jpeg(from: image)
            }
            lastSize = size
        }
        return nil
    }

    // MARK: - Credits / intro markers (users/{uid}/markers, shared by the household)

    struct ContentMarker {
        var creditsAt: Double?
        var introStart: Double?
        var introEnd: Double?
    }

    func marker(lineID: String, kind: String, id: String) async -> ContentMarker {
        guard let uid else { return ContentMarker() }
        let ref = db.collection("users").document(uid).collection("markers").document("\(lineID):\(kind):\(id)")
        guard let d = try? await ref.getDocument().data() else { return ContentMarker() }
        let num = { (k: String) in (d[k] as? NSNumber)?.doubleValue }
        return ContentMarker(creditsAt: num("creditsAt"), introStart: num("introStart"), introEnd: num("introEnd"))
    }

    func saveMarker(lineID: String, kind: String, id: String, duration: Double, fields: [String: Double]) {
        guard let uid, duration.isFinite, duration > 0 else { return }
        var doc: [String: Any] = ["lineId": lineID, "kind": kind, "source": "ai", "updatedAt": FieldValue.serverTimestamp(),
                                  "duration": (duration * 10).rounded() / 10]
        for (k, v) in fields where v.isFinite { doc[k] = (v * 10).rounded() / 10 }
        db.collection("users").document(uid).collection("markers").document("\(lineID):\(kind):\(id)")
            .setData(doc, merge: true) { error in
                if let error { print("marker: \(error.localizedDescription)") }
            }
    }

    // MARK: - Category tags (users/{uid}/lineTags/{lineId}, written by the classifyCategories function)

    struct CategoryTag: Equatable {
        let kids: Double
        let adult: Double
        let lang: String?
        let genre: String?
    }

    private(set) var tags: [String: CategoryTag] = [:]
    private var tagsLineID: String?
    private var tagsListener: ListenerRegistration?
    private var tagsCategories: [(kind: String, cats: [XtreamCategory])] = []
    private var fillingTags = false

    func tag(_ kind: String, _ categoryID: String?) -> CategoryTag? {
        guard let categoryID, !categoryID.isEmpty else { return nil }
        return tags["\(kind):\(categoryID)"]
    }

    /// Follows the line's tags and fills in categories that don't have any yet, in the background.
    func startTags(lineID: String, categories: [(kind: String, cats: [XtreamCategory])], onChange: @escaping () -> Void) {
        tagsCategories = categories
        if tagsLineID == lineID, tagsListener != nil {
            fillTags(lineID: lineID)
            return
        }
        stopTags()
        guard let uid else { return }
        tagsLineID = lineID
        tagsListener = db.collection("users").document(uid).collection("lineTags").document(lineID)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, self.tagsLineID == lineID else { return }
                    let cats = snap?.data()?["cats"] as? [String: Any] ?? [:]
                    let parsed: [String: CategoryTag] = cats.compactMapValues { raw in
                        guard let t = raw as? [String: Any] else { return nil }
                        return CategoryTag(kids: (t["kids"] as? NSNumber)?.doubleValue ?? 0.5,
                                           adult: (t["adult"] as? NSNumber)?.doubleValue ?? 0,
                                           lang: t["lang"] as? String, genre: t["genre"] as? String)
                    }
                    if parsed != self.tags {
                        self.tags = parsed
                        onChange()
                    }
                    self.fillTags(lineID: lineID)
                }
            }
    }

    func stopTags() {
        tagsListener?.remove()
        tagsListener = nil
        tagsLineID = nil
        tags = [:]
    }

    private func fillTags(lineID: String) {
        guard !fillingTags, !disabled else { return }
        var todo: [[String: String]] = []
        for (kind, cats) in tagsCategories {
            for c in cats where tags["\(kind):\(c.id)"] == nil && !c.id.isEmpty && !c.categoryName.isEmpty {
                todo.append(["id": c.id, "name": String(c.categoryName.prefix(120)), "kind": kind])
            }
        }
        guard !todo.isEmpty else { return }
        fillingTags = true
        Task { @MainActor in
            defer { fillingTags = false }
            for start in stride(from: 0, to: todo.count, by: 16) {
                guard tagsLineID == lineID, !disabled else { return }
                let batch = Array(todo[start..<min(start + 16, todo.count)])
                guard await call("classifyCategories", ["lineId": lineID, "categories": batch]) != nil else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000) // gentle: one batch every couple of seconds
            }
        }
    }

    // MARK: - Smart search

    struct SearchFilters: Equatable {
        let kind: String // movie | series | live | any
        let keywords: [String]
        let genres: [String]
        let languages: [String]
        let yearFrom: Int?
        let yearTo: Int?
        let sort: String // relevance | newest | rating

        /// "Hindi comedy movies, 2010–2019"
        var summary: String {
            let names = ["en": "English", "hi": "Hindi", "ta": "Tamil", "te": "Telugu", "ml": "Malayalam",
                         "es": "Spanish", "ar": "Arabic", "fr": "French"]
            let noun = ["movie": "movies", "series": "shows", "live": "channels"][kind] ?? "titles"
            var text = [languages.map { names[$0] ?? $0.uppercased() }.joined(separator: "/"), genres.joined(separator: "/"), noun]
                .filter { !$0.isEmpty }.joined(separator: " ")
            text = text.prefix(1).uppercased() + text.dropFirst()
            if let from = yearFrom, let to = yearTo, from != to {
                text += ", \(from)–\(to)"
            } else if let year = yearFrom ?? yearTo {
                text += ", \(year)"
            }
            if !keywords.isEmpty { text += " matching “\(keywords.joined(separator: " "))”" }
            return text
        }
    }

    private var searchCache: [String: SearchFilters] = [:]

    /// Natural-language request -> filters (nil when it reads like a plain title search or AI is off).
    func searchFilters(_ query: String) async -> SearchFilters? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
        if let cached = searchCache[q] { return cached }
        guard let r = await call("smartSearch", ["query": q]) else { return nil }
        let year = { (k: String) in (r[k] as? NSNumber)?.intValue }
        let f = SearchFilters(kind: r["kind"] as? String ?? "any", keywords: r["keywords"] as? [String] ?? [],
                              genres: r["genres"] as? [String] ?? [], languages: r["languages"] as? [String] ?? [],
                              yearFrom: year("yearFrom"), yearTo: year("yearTo"), sort: r["sort"] as? String ?? "relevance")
        searchCache[q] = f
        return f
    }

    nonisolated static func year(in title: String) -> Int? {
        guard let range = title.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        return Int(title[range])
    }

    // MARK: - Live channel alternatives

    private nonisolated static let qualityWords = #"\b(uhd|fhd|hd|sd|4k|8k|hevc|h265|backup|bk|raw|vip|plus|\d{3,4}p|50fps|60fps)\b"#

    /// "UK: Sky News FHD" and "Sky News HD" -> "sky news".
    nonisolated static func channelKey(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"^[a-z]{2,3}\s*[|:\-]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: qualityWords, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Player companion

/// Watches playback for the AI checks: where the credits start (so the next episode is offered when they
/// really begin), the opening titles (Skip Intro), and live channels that are black, frozen or off air.
/// Findings are saved as markers so every device in the household gets them without asking again.
@MainActor
@Observable
final class PlayerAI {
    /// Seek target while the Skip Intro button should show.
    private(set) var skipIntroTo: Double?
    /// When the AI (or a saved marker) saw the credits start.
    private(set) var creditsReachedAt: Date?
    /// "This channel is showing a black screen." when a live channel looks broken.
    private(set) var offAirMessage: String?

    @ObservationIgnored var grabFrame: (() async -> Data?)?
    @ObservationIgnored var onCreditsReached: (() -> Void)?

    @ObservationIgnored private var item: PlaybackItem?
    @ObservationIgnored private var ref: (lineID: String, kind: String, id: String)?
    @ObservationIgnored private var marker: SmartAI.ContentMarker?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var nextCheckAt = Date.distantPast
    /// A normal scene from this episode, sent with intro checks so the AI can compare: on real episodes an opening
    /// montage scored 0.2–0.5 "intro" alone and 0.86–0.95 next to a scene from the same episode.
    @ObservationIgnored private var scene: Data?
    @ObservationIgnored private var lastPosition: (position: Double, at: Date, playing: Bool)?
    /// Bumped on every seek: answers to checks started before it are dropped.
    @ObservationIgnored private var pass = 0
    @ObservationIgnored private var creditsHit: Double?
    @ObservationIgnored private var creditsDone = false
    @ObservationIgnored private var introStart: Double?
    @ObservationIgnored private var introLast: Double?
    @ObservationIgnored private var introFirstCheck: Double?
    @ObservationIgnored private var introCandidate: Double?
    @ObservationIgnored private var introDone = false
    @ObservationIgnored private var liveDone = false
    @ObservationIgnored private var playingSince: Date?

    private static let checkInterval: TimeInterval = 10
    private static let confirmInterval: TimeInterval = 3
    /// Finding intros frame by frame doesn't work on real shows (an opening montage reads as "a scene"), so the
    /// scan is off; saved intro markers still show Skip Intro. Planned instead: matching the opening across
    /// episodes of a series, the way streaming services do.
    private static let introScan = false
    /// Opening titles usually come within the first 7 minutes.
    private static let introScanUntil: Double = 420

    func start(item: PlaybackItem, lineID: String?) {
        stop()
        self.item = item
        let gen = generation
        guard item.contentType != .live, item.localFileURL == nil, let lineID else { return }
        let ref: (lineID: String, kind: String, id: String)?
        switch item.contentType {
        case .movie: ref = item.streamID.map { (lineID, "movie", String($0)) }
        case .seriesEpisode: ref = item.episodeID.map { (lineID, "episode", $0) }
        case .live: ref = nil
        }
        guard let ref else { return }
        self.ref = ref
        Task { @MainActor in
            let m = await SmartAI.shared.marker(lineID: ref.lineID, kind: ref.kind, id: ref.id)
            guard self.generation == gen else { return }
            self.marker = m
        }
    }

    func stop() {
        generation += 1
        item = nil
        ref = nil
        marker = nil
        busy = false
        nextCheckAt = .distantPast
        scene = nil
        lastPosition = nil
        creditsHit = nil
        creditsDone = false
        introStart = nil
        introLast = nil
        introFirstCheck = nil
        introCandidate = nil
        introDone = false
        liveDone = false
        playingSince = nil
        skipIntroTo = nil
        creditsReachedAt = nil
        offAirMessage = nil
    }

    func dismissOffAir() { offAirMessage = nil }
    func dismissSkipIntro() { skipIntroTo = nil }

    /// Past the detected start of the credits (progress then saves as finished).
    func pastCredits(_ position: Double) -> Bool {
        guard let at = marker?.creditsAt, at > 0 else { return false }
        return position >= at
    }

    func tick(position: Double, duration: Double, playing: Bool) {
        guard let item, position.isFinite else { return }
        if item.contentType == .live {
            liveTick(playing: playing)
            return
        }
        guard let m = marker, duration > 1, duration.isFinite else { return }
        watchForSeeks(position, playing: playing)
        if !creditsDone {
            if let at = m.creditsAt, at > 0 {
                if position >= at && position < duration - 2 { creditsReached() }
            } else if duration > 300 && position >= max(duration * 0.8, duration - 600) && playing {
                check("credits", position: position, duration: duration)
            }
        }
        guard item.contentType == .seriesEpisode else { return }
        if let end = m.introEnd {
            let from = m.introStart ?? 0
            let target: Double? = end > from + 5 && position >= from - 1 && position < end - 3 ? end : nil
            if skipIntroTo != target { skipIntroTo = target }
        } else if Self.introScan && !introDone && position < Self.introScanUntil && playing {
            check("intro", position: position, duration: duration)
        }
    }

    /// A jump (scrubbing, skipping, resuming) breaks the run of frames the evidence was built on: start over.
    private func watchForSeeks(_ position: Double, playing: Bool) {
        // Compared even while buffering (a seek pauses playback for a moment). Standing still is a stall, not a
        // jump; only moving backwards, or forwards faster than the clock, is.
        let previous = lastPosition
        lastPosition = (position, Date(), playing)
        guard let previous else { return }
        let ran = previous.playing ? Date().timeIntervalSince(previous.at) : 0
        guard position <= previous.position - 3 || position >= previous.position + ran + 8 else { return }
        pass += 1
        // Every jump starts a fresh pass over the opening minutes (also after one that ended without a result);
        // "no intro" is only concluded by a pass that ran unbroken from the first minute.
        if marker?.introEnd == nil {
            introStart = nil
            introLast = nil
            introCandidate = nil
            introFirstCheck = nil
            introDone = false
        }
        creditsHit = nil
        nextCheckAt = Date().addingTimeInterval(2) // look again once the picture has settled
    }

    private func check(_ task: String, position: Double, duration: Double) {
        guard !busy, Date() >= nextCheckAt, !SmartAI.shared.disabled, let grabFrame, let item else { return }
        busy = true
        nextCheckAt = Date().addingTimeInterval(Self.checkInterval)
        let gen = generation
        let pass = self.pass
        let scene = self.scene
        Task { @MainActor in
            defer { if self.generation == gen { self.busy = false } }
            guard let frame = await grabFrame(), self.generation == gen,
                  let r = await SmartAI.shared.frameCheck(task: task, images: task == "intro" ? scene.map { [frame, $0] } ?? [frame] : [frame],
                                                          title: item.title),
                  self.generation == gen, self.pass == pass else { return }
            if self.scene == nil && r.p("programme") >= 0.7 { self.scene = frame }
            if task == "credits" {
                self.creditsFrame(r, position: position, duration: duration)
            } else {
                self.introFrame(r, position: position, duration: duration)
            }
        }
    }

    private func creditsFrame(_ r: SmartAI.FrameVerdict, position: Double, duration: Double) {
        let credits = r.p("end_credits") + r.p("next_preview")
        guard credits >= 0.7 else {
            creditsHit = nil
            return
        }
        guard let hit = creditsHit ?? (credits >= 0.92 ? position : nil) else {
            creditsHit = position // confirm with a second look a few seconds later
            nextCheckAt = Date().addingTimeInterval(Self.confirmInterval)
            return
        }
        marker?.creditsAt = hit
        if let ref { SmartAI.shared.saveMarker(lineID: ref.lineID, kind: ref.kind, id: ref.id, duration: duration, fields: ["creditsAt": hit]) }
        creditsReached()
    }

    private func creditsReached() {
        creditsDone = true
        creditsReachedAt = Date()
        onCreditsReached?()
    }

    private func introFrame(_ r: SmartAI.FrameVerdict, position: Double, duration: Double) {
        if introFirstCheck == nil { introFirstCheck = position }
        if r.p("intro") >= 0.7 {
            // Two sightings in a row (3 s apart) before the titles count as started: one odd frame isn't an
            // intro. Keep looking often while inside, to find the end to a second or two.
            nextCheckAt = Date().addingTimeInterval(Self.confirmInterval)
            if introStart == nil {
                guard let candidate = introCandidate else {
                    introCandidate = position
                    return
                }
                introStart = max(0, candidate - 4)
            }
            introLast = position
            return
        }
        introCandidate = nil
        var fields: [String: Double]?
        if let start = introStart {
            introDone = true // the titles just ended, somewhere between the last two looks
            fields = ["introStart": start, "introEnd": ((introLast ?? position) + position) / 2]
        } else if position > Self.introScanUntil - 20 {
            introDone = true
            // No opening titles in the first minutes: remember that too, but only if all of them were watched.
            if (introFirstCheck ?? .infinity) < 60 { fields = ["introStart": 0, "introEnd": 0] }
        }
        guard let fields else { return }
        marker?.introStart = fields["introStart"]
        marker?.introEnd = fields["introEnd"]
        if let ref { SmartAI.shared.saveMarker(lineID: ref.lineID, kind: ref.kind, id: ref.id, duration: duration, fields: fields) }
    }

    private func liveTick(playing: Bool) {
        guard !liveDone else { return }
        guard playing else {
            playingSince = nil
            return
        }
        guard let since = playingSince else {
            playingSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= 10, !busy, !SmartAI.shared.disabled, let grabFrame, let item else { return }
        liveDone = true
        busy = true
        let gen = generation
        Task { @MainActor in
            defer { if self.generation == gen { self.busy = false } }
            guard let a = await grabFrame() else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.generation == gen, let b = await grabFrame(), self.generation == gen,
                  let r = await SmartAI.shared.frameCheck(task: "live", images: [a, b], title: item.title),
                  self.generation == gen else { return }
            guard r.label != "ok", r.p(r.label) >= 0.7, r.confidence >= 0.5 else { return }
            self.offAirMessage = [
                "black": "This channel is showing a black screen.",
                "frozen": "This channel’s picture looks frozen.",
                "offline": "This channel looks off air."
            ][r.label] ?? "This channel may not be working."
        }
    }
}
