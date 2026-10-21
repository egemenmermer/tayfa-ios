import Foundation

// MARK: Community cinema (`/rooms-cinema`, desktop `electron/community-cinema.ts`)
// The service takes the raw Stoat session token in `Authorization` and checks hall membership
// itself. Relay files need no header: the short-lived ticket in the path is the credential.
extension APIClient {
    public func cinemaStatus(community: String) async throws -> CinemaStatus {
        try decodeCinema(CinemaStatus.self, await cinemaRequest("/v1/communities/\(EndpointPolicy.id(community))"))
    }
    public func cinemaCategories(hall: String, kind: CinemaKind) async throws -> [CinemaCategory] {
        try decodeCinema([CinemaCategory].self, await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/categories?kind=\(kind.rawValue)"))
    }
    /// One page of a kind, optionally within a category; the service allows 1–1000 per page.
    public func cinemaItems(hall: String, kind: CinemaKind, category: String? = nil, sort: CinemaSort = .standard, offset: Int = 0, limit: Int = 60) async throws -> CinemaItemPage {
        var query = "kind=\(kind.rawValue)&sort=\(sort.rawValue)&offset=\(max(0, offset))&limit=\(min(1000, max(1, limit)))"
        if let category { guard CinemaRef.validCategory(category) else { throw CinemaError(code: "CINEMA_SOURCE_INVALID") }; query += "&categoryId=\(category)" }
        return try decodeCinema(CinemaItemPage.self, await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/items?\(query)"))
    }
    /// Turkish-aware search on the server (at most 40 results).
    public func cinemaSearch(hall: String, query: String, kinds: [CinemaKind] = CinemaKind.allCases) async throws -> [CinemaItem] {
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "kinds", value: kinds.map(\.rawValue).joined(separator: ","))]
        guard let encoded = components.percentEncodedQuery else { throw CinemaError(code: "CINEMA_SOURCE_INVALID") }
        return try decodeCinema([CinemaItem].self, await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/search?\(encoded)"))
    }
    /// Programmes per live ref between two epoch-ms instants (at most 3 days, 200 refs).
    public func cinemaGuide(hall: String, refs: [String], from: Double, to: Double) async throws -> [String: [CinemaProgramme]] {
        let checked = refs.filter(CinemaRef.valid).prefix(200)
        guard !checked.isEmpty else { return [:] }
        let body = JSONValue.object(["refs": .array(checked.map(JSONValue.string)), "from": .number(from.rounded()), "to": .number(to.rounded())])
        return try decodeCinema([String: [CinemaProgramme]].self, await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/guide", method: "POST", body: body))
    }
    public func cinemaDetails(hall: String, ref: String) async throws -> CinemaDetails {
        guard CinemaRef.valid(ref) else { throw CinemaError(code: "CINEMA_ITEM_NOT_FOUND") }
        return try decodeCinema(CinemaDetails.self, await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/details/\(ref)"))
    }
    /// Artwork bytes (the request needs the session token, so image views cannot load the URL directly).
    public func cinemaArt(hall: String, art: String) async throws -> Data {
        guard CinemaRef.validArt(art) else { throw CinemaError(code: "CINEMA_ITEM_NOT_FOUND") }
        return try await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/art/\(art)", timeout: 20, limit: 4_000_000)
    }
    /// Starts or joins the relay for the hall's current item.
    public func cinemaWatch(hall: String) async throws -> CinemaWatch {
        let watch = try decodeCinema(CinemaWatch.self, await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/watch", method: "POST", timeout: 45))
        guard watch.session.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil, Self.validTicket(watch.ticket) else { throw RoomsError.invalidResponse }
        return watch
    }
    /// A fresh ticket for a running relay session; never starts or restarts a relay (410 once the hall moved on).
    public func cinemaRenewTicket(hall: String, session: String) async throws -> CinemaTicket {
        guard session.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { throw CinemaError(code: "CINEMA_SESSION_ENDED") }
        let ticket = try decodeCinema(CinemaTicket.self, await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/sessions/\(session)/ticket", method: "POST"))
        guard Self.validTicket(ticket.ticket) else { throw RoomsError.invalidResponse }
        return ticket
    }
    /// The remote holder picks the relayed audio stream; running relays stop and players watch again.
    public func cinemaSetAudio(hall: String, ref: String, track: Int) async throws -> Int? {
        guard CinemaRef.valid(ref), (0...31).contains(track) else { throw CinemaError(code: "CINEMA_SOURCE_INVALID") }
        let data = try await cinemaRequest("/v1/halls/\(EndpointPolicy.id(hall))/audio", method: "POST", body: .object(["ref": .string(ref), "track": .number(Double(track))]))
        struct Choice: Decodable { let audioTrack: Int? }
        return try decodeCinema(Choice.self, data).audioTrack
    }
    /// A relay file under the current ticket: `index.m3u8`, `init.mp4` or `segNNNNNN.m4s`.
    public func cinemaRelayURL(ticket: String, file: String) throws -> URL {
        guard Self.validTicket(ticket), file.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil, !file.contains(".."),
              let url = URL(string: "/rooms-cinema/v1/relay/\(ticket)/\(file)", relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        return url
    }
    /// Fetches a relay file. 401 means the ticket expired (renew and retry once); 404/410 mean the relay
    /// is gone (`CINEMA_RELAY_GONE`, watch again).
    public func cinemaRelayFile(ticket: String, file: String, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: try cinemaRelayURL(ticket: ticket, file: file), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw CinemaError(code: "CINEMA_UNAVAILABLE") }
        guard let http = response as? HTTPURLResponse, data.count <= 16_000_000 else { throw RoomsError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw CinemaError(code: "CINEMA_TICKET_EXPIRED")
        case 404, 410: throw CinemaError(code: "CINEMA_RELAY_GONE")
        default: throw CinemaError(code: "CINEMA_STREAM_FAILED")
        }
    }

    static func validTicket(_ ticket: String) -> Bool {
        ticket.count <= 1024 && ticket.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
    private func decodeCinema<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw RoomsError.invalidResponse }
    }
    private func cinemaRequest(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval = 20, limit: Int = 4_194_304) async throws -> Data {
        try Task.checkCancellation()
        guard let url = URL(string: "/rooms-cinema" + path, relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: timeout); request.httpMethod = method
        if let token { request.setValue(token, forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw CinemaError(code: "CINEMA_UNAVAILABLE") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= limit else { throw RoomsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"].string ?? ""
            throw CinemaError(code: code.range(of: "^CINEMA_[A-Z_]{1,48}$", options: .regularExpression) != nil ? code : http.statusCode == 429 ? "CINEMA_RATE_LIMITED" : "CINEMA_UNAVAILABLE")
        }
        return data
    }
}
