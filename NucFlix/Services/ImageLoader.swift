import SwiftUI
import UIKit
import ImageIO

// MARK: - High-Performance In-Memory Image Cache

/// Downloads, downsamples (off the main thread) and caches artwork.
/// - Memory cache cost = decoded bitmap bytes, so the limit reflects real RAM usage.
/// - Concurrent requests for the same URL share a single download/decode.
/// - URLs that fail permanently (404, dead host, undecodable data) are not refetched this session.
final class ImageCacheManager: @unchecked Sendable {
    static let shared = ImageCacheManager()

    /// Default longest-side pixel budget for decoded artwork. Posters (~150x220pt @3x ≈ 450x660px)
    /// fit comfortably and full-width hero/backdrop images stay reasonably sharp.
    static let defaultMaxPixelSize: CGFloat = 900

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    private let lock = NSLock()
    private var inFlight: [String: InFlightLoad] = [:]
    private var failedURLs: Set<String> = []

    private final class InFlightLoad: @unchecked Sendable {
        var task: Task<UIImage?, Never>?
        /// Number of callers awaiting this load (guarded by `ImageCacheManager.lock`).
        var waiters = 0
    }

    private enum LoadOutcome {
        case success(UIImage, cost: Int)
        case permanentFailure
        case transientFailure
    }

    private init() {
        cache.countLimit = 1_500
        cache.totalCostLimit = 150 * 1024 * 1024 // 150 MB of decoded bitmaps

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        // Artwork URLs are effectively immutable; prefer the on-disk copy when we have one.
        config.requestCachePolicy = .returnCacheDataElseLoad
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ArtworkURLCache", isDirectory: true)
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 300 * 1024 * 1024,
            directory: cacheDirectory
        )
        config.httpAdditionalHeaders = [
            "User-Agent": "IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: Public API

    /// Parses a (possibly blank / padded) artwork string into a URL.
    static func artworkURL(from string: String?) -> URL? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw) else {
            return nil
        }
        return url
    }

    /// Synchronous memory-cache lookup (safe to call from `body`).
    func cachedImage(for url: URL, maxPixelSize: CGFloat = ImageCacheManager.defaultMaxPixelSize) -> UIImage? {
        cache.object(forKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString)
    }

    func image(for url: URL, maxPixelSize: CGFloat = ImageCacheManager.defaultMaxPixelSize) async -> UIImage? {
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let load = joinOrStartLoad(key: key, url: url, maxPixelSize: maxPixelSize) else {
            return nil // known-dead URL
        }
        return await withTaskCancellationHandler {
            await load.task?.value ?? nil
        } onCancel: {
            self.leave(load, key: key)
        }
    }

    // MARK: Internals

    private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        "\(Int(maxPixelSize.rounded()))|\(url.absoluteString)"
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func joinOrStartLoad(key: String, url: URL, maxPixelSize: CGFloat) -> InFlightLoad? {
        synchronized { () -> InFlightLoad? in
            if failedURLs.contains(url.absoluteString) {
                return nil
            }
            if let existing = inFlight[key] {
                existing.waiters += 1
                return existing
            }
            let load = InFlightLoad()
            load.waiters = 1
            let session = self.session
            load.task = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
                let outcome = await Self.fetchAndDecode(url: url, maxPixelSize: maxPixelSize, session: session)
                self.finish(load, key: key, url: url, outcome: outcome)
                if case .success(let image, _) = outcome {
                    return image
                }
                return nil
            }
            inFlight[key] = load
            return load
        }
    }

    /// A waiter went away (its SwiftUI task was cancelled, e.g. the cell scrolled off-screen).
    /// When nobody is waiting any more, cancel the download so fast scrolling doesn't queue
    /// hundreds of stale requests.
    private func leave(_ load: InFlightLoad, key: String) {
        let taskToCancel: Task<UIImage?, Never>? = synchronized { () -> Task<UIImage?, Never>? in
            load.waiters -= 1
            guard load.waiters <= 0 else { return nil }
            if inFlight[key] === load {
                inFlight[key] = nil
            }
            return load.task
        }
        taskToCancel?.cancel()
    }

    private func finish(_ load: InFlightLoad, key: String, url: URL, outcome: LoadOutcome) {
        if case .success(let image, let cost) = outcome {
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        synchronized { () -> Void in
            if inFlight[key] === load {
                inFlight[key] = nil
            }
            if case .permanentFailure = outcome {
                failedURLs.insert(url.absoluteString)
            }
        }
    }

    private static func fetchAndDecode(url: URL, maxPixelSize: CGFloat, session: URLSession) async -> LoadOutcome {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(from: url)
        } catch let error as URLError {
            switch error.code {
            case .badURL, .unsupportedURL, .cannotFindHost, .dnsLookupFailed,
                 .fileDoesNotExist, .resourceUnavailable, .zeroByteResource,
                 .cannotDecodeContentData, .cannotDecodeRawData, .httpTooManyRedirects,
                 .redirectToNonExistentLocation, .secureConnectionFailed,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return .permanentFailure
            default:
                // Cancelled, timed out, offline, connection lost… worth retrying later.
                return .transientFailure
            }
        } catch {
            return .transientFailure
        }

        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let isTransient = http.statusCode == 408 || http.statusCode == 429 || http.statusCode == 503
            return isTransient ? .transientFailure : .permanentFailure
        }

        // Nobody wants this image any more; the bytes are already in the URLCache for next time.
        if Task.isCancelled {
            return .transientFailure
        }

        guard !data.isEmpty, let decoded = downsampledImage(from: data, maxPixelSize: maxPixelSize) else {
            return .permanentFailure
        }
        return .success(decoded.image, cost: decoded.cost)
    }

    /// Decodes straight to a bitmap no larger than `maxPixelSize` on its longest side using ImageIO,
    /// so the full-resolution image is never materialised and no decode happens on the main thread.
    private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> (image: UIImage, cost: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded()))
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
                return (UIImage(cgImage: cgImage), cgImage.bytesPerRow * cgImage.height)
            }
        }

        // Fallback for formats ImageIO can't thumbnail.
        guard let image = UIImage(data: data) else { return nil }
        let prepared = image.preparingForDisplay() ?? image
        return (prepared, decodedCost(of: prepared))
    }

    private static func decodedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        return max(1, Int(pixelWidth * pixelHeight * 4))
    }
}

/// Strictly bounded image view that NEVER expands wider than its proposed frame.
struct ArtworkImageView: View {
    let urlString: String?
    var fallbackTitle: String = ""
    var fallbackIcon: String = "tv"
    var contentMode: ContentMode = .fill
    /// Longest-side decode budget in pixels. Smaller values save memory for thumbnails.
    var maxPixelSize: CGFloat = ImageCacheManager.defaultMaxPixelSize

    @State private var uiImage: UIImage?
    /// The `urlString` that `uiImage` belongs to (guards against showing stale artwork after reuse).
    @State private var loadedURLString: String?
    /// Only network-loaded images fade in; memory-cache hits appear instantly.
    @State private var fadeIn = false

    init(
        urlString: String?,
        fallbackTitle: String = "",
        fallbackIcon: String = "tv",
        contentMode: ContentMode = .fill,
        maxPixelSize: CGFloat = ImageCacheManager.defaultMaxPixelSize
    ) {
        self.urlString = urlString
        self.fallbackTitle = fallbackTitle
        self.fallbackIcon = fallbackIcon
        self.contentMode = contentMode
        self.maxPixelSize = maxPixelSize
    }

    /// The image for the *current* `urlString`: the loaded one if it matches, otherwise a
    /// synchronous memory-cache hit (no placeholder flash), otherwise nil (placeholder).
    private var displayedImage: UIImage? {
        if loadedURLString == urlString {
            return uiImage
        }
        guard let url = ImageCacheManager.artworkURL(from: urlString) else { return nil }
        return ImageCacheManager.shared.cachedImage(for: url, maxPixelSize: maxPixelSize)
    }

    private var imageTransition: AnyTransition {
        fadeIn ? AnyTransition.opacity.animation(.easeOut(duration: 0.18)) : AnyTransition.identity
    }

    var body: some View {
        let image = displayedImage
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(imageTransition)
                } else {
                    placeholderView
                }
            }
            .clipped()
            .task(id: urlString) {
                await load()
            }
    }

    @MainActor
    private func load() async {
        let requested = urlString
        guard let url = ImageCacheManager.artworkURL(from: requested) else {
            uiImage = nil
            loadedURLString = requested
            return
        }

        let manager = ImageCacheManager.shared
        if let cached = manager.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            if uiImage !== cached {
                fadeIn = false
                uiImage = cached
            }
            if loadedURLString != requested {
                loadedURLString = requested
            }
            return
        }

        if loadedURLString != requested {
            uiImage = nil // release artwork that belonged to a previous URL
        }

        let image = await manager.image(for: url, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        fadeIn = true
        uiImage = image
        loadedURLString = requested
    }

    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(white: 0.14),
                    Color(white: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                NucFlixLogoBadge(size: 26)
                if !fallbackTitle.isEmpty {
                    let clean = XtreamTextFormatter.format(fallbackTitle).cleanTitle
                    Text(clean)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

// MARK: - "NucFlix" (Netflix iOS Clone) Design System

enum AppTheme {
    static let netflixRed = Color(red: 0.898, green: 0.035, blue: 0.078) // #E50914
    static let darkRed = Color(red: 0.698, green: 0.027, blue: 0.063)    // #B20710
    static let matchGreen = Color(red: 0.275, green: 0.827, blue: 0.412) // #46D369
    static let gold = Color(red: 1.0, green: 0.75, blue: 0.12)
    static let primaryRed = netflixRed
    static let cardSurface = Color(red: 0.09, green: 0.09, blue: 0.09)   // #171717
    static let elevatedGray = Color(red: 0.18, green: 0.18, blue: 0.18)  // #2E2E2E

    static let accentGradient = LinearGradient(
        colors: [netflixRed, darkRed],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

}

struct ObsidianBackgroundView: View {
    var body: some View {
        Color.black.ignoresSafeArea()
    }
}

/// Authentic Vector 3D Folded Netflix "N" Ribbon Logo (Matches real Netflix iOS header & poster badge)
struct NucFlixLogoBadge: View {
    var size: CGFloat = 28

    var body: some View {
        let width = size * 0.56
        let height = size
        let stemWidth = width * 0.34

        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let sw = stemWidth

            // Left vertical stem (#B20710)
            var leftPath = Path()
            leftPath.move(to: CGPoint(x: 0, y: 0))
            leftPath.addLine(to: CGPoint(x: sw, y: 0))
            leftPath.addLine(to: CGPoint(x: sw, y: h))
            leftPath.addLine(to: CGPoint(x: 0, y: h))
            leftPath.closeSubpath()
            context.fill(leftPath, with: .color(AppTheme.darkRed))

            // Right vertical stem (#B20710)
            var rightPath = Path()
            rightPath.move(to: CGPoint(x: w - sw, y: 0))
            rightPath.addLine(to: CGPoint(x: w, y: 0))
            rightPath.addLine(to: CGPoint(x: w, y: h))
            rightPath.addLine(to: CGPoint(x: w - sw, y: h))
            rightPath.closeSubpath()
            context.fill(rightPath, with: .color(AppTheme.darkRed))

            // Center diagonal ribbon (#E50914) with cast shadow
            var diagPath = Path()
            diagPath.move(to: CGPoint(x: 0, y: 0))
            diagPath.addLine(to: CGPoint(x: sw * 1.02, y: 0))
            diagPath.addLine(to: CGPoint(x: w, y: h))
            diagPath.addLine(to: CGPoint(x: w - sw * 1.02, y: h))
            diagPath.closeSubpath()

            context.drawLayer { layerCtx in
                layerCtx.addFilter(.shadow(color: .black.opacity(0.75), radius: 2.5, x: 0, y: 1))
                layerCtx.fill(diagPath, with: .color(AppTheme.netflixRed))
            }
        }
        .frame(width: width, height: height)
    }
}

/// Exact Red "TOP 10" Top-Left Corner Ribbon Badge from the Netflix iOS App
struct NetflixTop10CornerBadge: View {
    var body: some View {
        VStack(spacing: -1) {
            Text("TOP")
                .font(.system(size: 7.5, weight: .black))
                .tracking(0.3)
            Text("10")
                .font(.system(size: 12, weight: .black))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(AppTheme.netflixRed, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Small "N SERIES" / "N FILM" header tag
struct NucFlixSeriesTag: View {
    var label: String = "SERIES"

    var body: some View {
        HStack(spacing: 6) {
            NucFlixLogoBadge(size: 15)
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

struct QualityBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
            )
            .foregroundStyle(.white.opacity(0.9))
    }
}

struct LivePulseBadge: View {
    var text: String = "LIVE"

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.netflixRed, in: RoundedRectangle(cornerRadius: 3))
    }
}

extension View {
    func obsidianGlassCard(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
            )
    }
}

// MARK: - Netflix-Style Category Explorer Sheet

struct CategoryExplorerSheet: View {
    let title: String
    let categories: [XtreamCategory]
    @Binding var selectedCategoryID: String
    let favoritesCount: Int
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var selectedGroup: String = "All"

    private let regionGroups = ["All", "Cricket & Sports", "India & Asia", "UK", "USA", "4K & UHD"]

    private var filteredCategories: [XtreamCategory] {
        var list = categories

        if selectedGroup != "All" {
            list = list.filter { cat in
                let raw = cat.categoryName.uppercased()
                switch selectedGroup {
                case "Cricket & Sports":
                    return raw.contains("CRICKET") || raw.contains("SPORT") || raw.contains("FOOTBALL") || raw.contains("IPL") || raw.contains("FIFA") || raw.contains("UFC") || raw.contains("WWE")
                case "India & Asia":
                    return raw.contains("ASIA") || raw.contains("IN ") || raw.contains("IN|") || raw.contains("HINDI") || raw.contains("PUNJABI") || raw.contains("GUJARATI") || raw.contains("TAMIL") || raw.contains("TELUGU") || raw.contains("MALAYALAM") || raw.contains("MARATHI") || raw.contains("YUPP") || raw.contains("PAK") || raw.contains("BANGLA")
                case "UK":
                    return raw.contains("UK") || raw.contains("SKY") || raw.contains("TNT") || raw.contains("BBC")
                case "USA":
                    return raw.contains("US") || raw.contains("USA") || raw.contains("NFL") || raw.contains("NBA") || raw.contains("HBO")
                case "4K & UHD":
                    return !cat.qualityBadges.filter({ $0 == "4K" || $0 == "DOLBY" || $0 == "RAW" }).isEmpty || raw.contains("4K") || raw.contains("HEVC")
                default:
                    return true
                }
            }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list = list.filter { $0.categoryName.localizedCaseInsensitiveContains(trimmed) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(regionGroups, id: \.self) { group in
                                let isSelected = selectedGroup == group
                                Button {
                                    selectedGroup = group
                                } label: {
                                    Text(group)
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            isSelected ? AppTheme.netflixRed : AppTheme.elevatedGray,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            categoryRow(
                                id: "FAV",
                                prefix: "★",
                                name: "My List",
                                badges: ["\(favoritesCount)"],
                                isSelected: selectedCategoryID == "FAV"
                            )

                            ForEach(filteredCategories) { cat in
                                categoryRow(
                                    id: cat.id,
                                    prefix: cat.prefixBadge,
                                    name: cat.cleanName,
                                    badges: cat.qualityBadges,
                                    isSelected: selectedCategoryID == cat.id
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("\(title) (\(filteredCategories.count))")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search categories (Cricket, UK, Hindi, Netflix)...")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func categoryRow(
        id: String,
        prefix: String?,
        name: String,
        badges: [String],
        isSelected: Bool
    ) -> some View {
        Button {
            selectedCategoryID = id
            onSelect(id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if let prefix, !prefix.isEmpty {
                    Text(prefix)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .foregroundStyle(.white)
                }

                Text(name)
                    .font(.subheadline.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                ForEach(badges, id: \.self) { badge in
                    QualityBadgeView(text: badge)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                isSelected ? AppTheme.netflixRed : AppTheme.cardSurface,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
