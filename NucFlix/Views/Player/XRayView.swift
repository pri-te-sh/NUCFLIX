import SwiftUI

/// X-Ray, as on Prime Video: who's in the paused scene (found by face matching in the xray Cloud Function against the
/// title's TMDB cast), trivia from the title's Wikipedia article, and the full cast, which is also what shows when
/// nobody on screen is recognised. An actor opens their bio and best-known titles.
struct XRayView: View {
    let heading: String
    let subheading: String
    let load: () async -> SmartAI.XRayScene?

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var result: SmartAI.XRayScene?
    @State private var trivia: [String] = []

    /// Trivia per title (type_id), for the app's lifetime.
    @MainActor private static var triviaCache: [String: [String]] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        XRayBadge()
                        Text(subheading).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                content
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: SmartAI.XRayPerson.self) { XRayPersonView(person: $0) }
        }
        .preferredColorScheme(.dark)
        .task {
            result = await load()
            loading = false
            if let title = result?.title, title.hasTrivia { await loadTrivia(title) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack(spacing: 12) {
                ProgressView()
                Text("Looking at this scene…").foregroundStyle(.secondary)
            }
        } else if let result, let title = result.title {
            let scene = result.scene ?? []
            Section("In this scene") {
                if scene.isEmpty {
                    Text("\(result.scene == nil ? "X-Ray couldn’t see this scene." : result.faces > 0 ? "X-Ray doesn’t recognise anyone on screen right now." : "Nobody is on screen right now.") Here’s the full cast of \(title.name)\(title.year.isEmpty ? "" : " (\(title.year))").")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scene) { person in
                        NavigationLink(value: person) { XRayPersonRow(person: person, large: true) }
                    }
                }
            }
            if !trivia.isEmpty {
                Section("Trivia") {
                    ForEach(trivia, id: \.self) { fact in
                        Text(fact).font(.callout)
                    }
                }
            }
            Section(scene.isEmpty ? "Cast" : "All cast") {
                if result.cast.isEmpty {
                    Text("No cast listed.").foregroundStyle(.secondary)
                }
                ForEach(result.cast) { person in
                    NavigationLink(value: person) { XRayPersonRow(person: person, large: false) }
                }
            }
        } else {
            Text(result == nil ? "X-Ray couldn’t load right now. Check the connection and try again." : "X-Ray couldn’t find this title’s cast.")
                .foregroundStyle(.secondary)
        }
    }

    private func loadTrivia(_ title: SmartAI.XRayTitle) async {
        let key = "\(title.type)_\(title.id)"
        if let cached = Self.triviaCache[key] {
            trivia = cached
            return
        }
        let facts = await SmartAI.shared.xrayTrivia(type: title.type, id: title.id)
        Self.triviaCache[key] = facts
        withAnimation { trivia = facts }
    }
}

private struct XRayBadge: View {
    var body: some View {
        Label("X-RAY", systemImage: "person.crop.square.badge.camera")
            .font(.system(size: 13, weight: .heavy))
            .kerning(1.2)
            .foregroundStyle(Color(red: 0.12, green: 0.78, blue: 1))
    }
}

private struct XRayPersonRow: View {
    let person: SmartAI.XRayPerson
    let large: Bool

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImageView(urlString: person.photo, fallbackTitle: initials, fallbackIcon: "person.fill", maxPixelSize: 240)
                .frame(width: large ? 60 : 44, height: large ? 80 : 58)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(large ? .headline : .subheadline.weight(.semibold))
                if !person.character.isEmpty {
                    Text(person.character).font(large ? .subheadline : .caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

/// An actor: photo, birth details, biography, and their best-known titles.
struct XRayPersonView: View {
    let person: SmartAI.XRayPerson
    @State private var detail: SmartAI.XRayPersonDetail?
    @State private var loading = true

    @MainActor private static var cache: [Int: SmartAI.XRayPersonDetail] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    ArtworkImageView(urlString: detail?.photo.isEmpty == false ? detail?.photo : person.photo,
                                     fallbackTitle: person.name, fallbackIcon: "person.fill", maxPixelSize: 480)
                        .frame(width: 120, height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.name).font(.title2.bold())
                        if !person.character.isEmpty {
                            Text("as \(person.character)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let detail {
                            if !detail.born.isEmpty {
                                fact("Born", Self.date(detail.born) + (detail.place.isEmpty ? "" : " in \(detail.place)"))
                            }
                            if !detail.died.isEmpty { fact("Died", Self.date(detail.died)) }
                        }
                    }
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let detail {
                    Text(detail.bio.isEmpty ? "No biography yet." : detail.bio)
                        .font(.callout)
                        .foregroundStyle(detail.bio.isEmpty ? .secondary : .primary)
                    if !detail.credits.isEmpty {
                        Text("Known for").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(detail.credits) { credit in
                                    VStack(alignment: .leading, spacing: 4) {
                                        ArtworkImageView(urlString: credit.poster, fallbackTitle: credit.title, fallbackIcon: "film", maxPixelSize: 300)
                                            .frame(width: 104, height: 156)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(credit.title).font(.caption.weight(.semibold)).lineLimit(1)
                                        Text([credit.year, credit.character].filter { !$0.isEmpty }.joined(separator: " • "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(width: 104)
                                }
                            }
                        }
                    }
                } else {
                    Text("Couldn’t load more about this person right now.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color.black)
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let cached = Self.cache[person.id] {
                detail = cached
            } else if let d = await SmartAI.shared.xrayPerson(id: person.id) {
                Self.cache[person.id] = d
                detail = d
            }
            loading = false
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        (Text(label + "  ").foregroundStyle(.secondary).bold() + Text(value)).font(.footnote)
    }

    private static func date(_ iso: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: iso) else { return iso }
        return d.formatted(date: .long, time: .omitted)
    }
}
