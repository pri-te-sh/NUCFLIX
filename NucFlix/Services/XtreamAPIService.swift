import Foundation

enum XtreamAPIError: LocalizedError {
    case invalidServerURL
    case invalidCredentials(String)
    case subscriptionExpired(String)
    case connectionLimit(String)
    case networkBlocked(String)
    case httpError(Int)
    case decodingError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Invalid server URL. Please enter a valid Xtream Codes URL (e.g., http://example.com:8080)."
        case .invalidCredentials(let message):
            return message
        case .subscriptionExpired(let message):
            return message
        case .connectionLimit(let message):
            return message
        case .networkBlocked(let message):
            return message
        case .httpError(let code):
            return "Server returned HTTP status \(code). Please verify your server URL and port."
        case .decodingError(let details):
            return "Unable to parse response from server (\(details))."
        case .networkError(let reason):
            return reason
        }
    }

    /// Maps a raw HTTP status from an Xtream panel onto a meaningful error.
    ///
    /// Xtream panels use non-standard codes: `884` means every connection slot is taken,
    /// `509` means the line hit its connection/bandwidth cap, and `511` is what Cloudflare
    /// returns when the panel's edge refuses the client's network (commonly hosting and
    /// datacenter IP ranges) — that one is a network problem, not a credentials problem.
    static func from(httpStatusCode code: Int) -> XtreamAPIError {
        switch code {
        case 401, 403:
            return .invalidCredentials("Server rejected the credentials (HTTP \(code)). The line may be expired, disabled, or blocked.")
        case 509:
            return .connectionLimit("The provider refused the request (HTTP 509): this line has no free connection slot or has hit its bandwidth cap. Close other apps or devices using it and try again.")
        case 884:
            return .connectionLimit("All connection slots are in use (HTTP 884). This line allows a limited number of simultaneous connections — close other apps or devices using it and try again.")
        case 511:
            return .networkBlocked("Your network was refused by the provider's firewall (HTTP 511). This is not a credentials problem — providers block many hosting and datacenter IP ranges. Try a different connection (mobile hotspot, home broadband) or ask your provider to whitelist your network.")
        default:
            return .httpError(code)
        }
    }
}

final class XtreamAPIService {
    static let shared = XtreamAPIService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        // Every request URL carries the Xtream login (and the auth reply echoes the password),
        // so nothing from this session goes to the on-disk HTTP cache.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        // Many Xtream Codes providers whitelist known IPTV player User-Agents
        config.httpAdditionalHeaders = [
            "User-Agent": "IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)",
            "Accept": "application/json, */*"
        ]
        self.session = URLSession(configuration: config)
    }

    private func makePlayerAPIURL(credentials: XtreamCredentials, action: String? = nil, extraParams: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: "\(credentials.normalizedBaseURL)/player_api.php") else {
            throw XtreamAPIError.invalidServerURL
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        if let action {
            items.append(URLQueryItem(name: "action", value: action))
        }
        for (key, val) in extraParams {
            items.append(URLQueryItem(name: key, value: val))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw XtreamAPIError.invalidServerURL
        }
        return url
    }

    private func request<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw XtreamAPIError.networkError(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw XtreamAPIError.from(httpStatusCode: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw XtreamAPIError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Authentication

    func authenticate(credentials: XtreamCredentials) async throws -> XtreamAuthResponse {
        let url = try makePlayerAPIURL(credentials: credentials)
        let response = try await request(XtreamAuthResponse.self, url: url)
        guard let userInfo = response.userInfo else {
            throw XtreamAPIError.invalidCredentials("Authentication failed: the server did not return account information.")
        }

        // A dead line comes back as status "Expired"/"Disabled" with auth = 0.
        // Check that before the generic auth check so the user gets the real reason.
        let status = (userInfo.status ?? "").lowercased()
        if status == "expired" || status == "disabled" {
            let providerZone = XtreamExpiryFormatter.timeZone(response.serverInfo?.timezone)
            let expiry = userInfo.expirationDate.map {
                XtreamExpiryFormatter.date($0, timeZone: providerZone, includeTime: true)
            } ?? "an unknown date"
            throw XtreamAPIError.subscriptionExpired("This subscription is \(status) (provider expiry: \(expiry)). Renew or extend the line with your IPTV provider to restore access.")
        }

        guard userInfo.isAuthenticated else {
            let statusMsg = userInfo.status ?? userInfo.message ?? "Invalid username or password."
            throw XtreamAPIError.invalidCredentials("Authentication failed: \(statusMsg)")
        }
        return response
    }

    /// Authenticates and resolves the scheme that actually works.
    ///
    /// A bare hostname is tried over HTTPS first so the credentials in the request URL
    /// are not exposed in clear text. Panels without TLS fail the handshake, in which
    /// case the request is retried over plain HTTP. The credentials that worked are
    /// returned so the caller can persist the correct scheme for streams as well.
    func authenticateResolvingScheme(credentials: XtreamCredentials) async throws -> (response: XtreamAuthResponse, credentials: XtreamCredentials) {
        do {
            let response = try await authenticate(credentials: credentials)
            return (response, credentials)
        } catch let error as XtreamAPIError {
            guard case .networkError = error,
                  credentials.normalizedBaseURL.lowercased().hasPrefix("https://") else {
                throw error
            }
            var plain = credentials
            plain.serverURL = credentials.normalizedBaseURL.replacingOccurrences(of: "https://", with: "http://")
            let response = try await authenticate(credentials: plain)
            return (response, plain)
        }
    }

    // MARK: - Live TV

    func fetchLiveCategories(credentials: XtreamCredentials) async throws -> [XtreamCategory] {
        let url = try makePlayerAPIURL(credentials: credentials, action: "get_live_categories")
        return (try? await request([XtreamCategory].self, url: url)) ?? []
    }

    func fetchLiveStreams(credentials: XtreamCredentials, categoryId: String? = nil) async throws -> [XtreamLiveStream] {
        var params: [String: String] = [:]
        if let categoryId {
            params["category_id"] = categoryId
        }
        let url = try makePlayerAPIURL(credentials: credentials, action: "get_live_streams", extraParams: params)
        return (try? await request([XtreamLiveStream].self, url: url)) ?? []
    }

    func fetchShortEPG(credentials: XtreamCredentials, streamId: Int, limit: Int = 10) async throws -> [XtreamEPGItem] {
        let url = try makePlayerAPIURL(
            credentials: credentials,
            action: "get_short_epg",
            extraParams: ["stream_id": String(streamId), "limit": String(limit)]
        )
        let response = try? await request(XtreamEPGResponse.self, url: url)
        return response?.epgListings ?? []
    }

    // MARK: - Movies (VOD)

    func fetchVODCategories(credentials: XtreamCredentials) async throws -> [XtreamCategory] {
        let url = try makePlayerAPIURL(credentials: credentials, action: "get_vod_categories")
        return (try? await request([XtreamCategory].self, url: url)) ?? []
    }

    func fetchVODStreams(credentials: XtreamCredentials, categoryId: String? = nil) async throws -> [XtreamVODStream] {
        var params: [String: String] = [:]
        if let categoryId {
            params["category_id"] = categoryId
        }
        let url = try makePlayerAPIURL(credentials: credentials, action: "get_vod_streams", extraParams: params)
        return (try? await request([XtreamVODStream].self, url: url)) ?? []
    }

    func fetchVODInfo(credentials: XtreamCredentials, vodId: Int) async throws -> XtreamVODInfoResponse? {
        let url = try makePlayerAPIURL(
            credentials: credentials,
            action: "get_vod_info",
            extraParams: ["vod_id": String(vodId)]
        )
        return try? await request(XtreamVODInfoResponse.self, url: url)
    }

    // MARK: - TV Series

    func fetchSeriesCategories(credentials: XtreamCredentials) async throws -> [XtreamCategory] {
        let url = try makePlayerAPIURL(credentials: credentials, action: "get_series_categories")
        return (try? await request([XtreamCategory].self, url: url)) ?? []
    }

    func fetchSeries(credentials: XtreamCredentials, categoryId: String? = nil) async throws -> [XtreamSeries] {
        var params: [String: String] = [:]
        if let categoryId {
            params["category_id"] = categoryId
        }
        let url = try makePlayerAPIURL(credentials: credentials, action: "get_series", extraParams: params)
        return (try? await request([XtreamSeries].self, url: url)) ?? []
    }

    func fetchSeriesInfo(credentials: XtreamCredentials, seriesId: Int) async throws -> XtreamSeriesInfoResponse {
        let url = try makePlayerAPIURL(
            credentials: credentials,
            action: "get_series_info",
            extraParams: ["series_id": String(seriesId)]
        )
        return (try? await request(XtreamSeriesInfoResponse.self, url: url)) ?? XtreamSeriesInfoResponse()
    }
}
