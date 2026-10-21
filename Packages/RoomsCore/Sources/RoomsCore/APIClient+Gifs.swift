import Foundation

// MARK: GIF search (Access `GET /v1/gifs`, KLIPY behind the server; desktop `ComposerPickers.tsx`)

public enum GifPolicy {
    /// Only media from KLIPY's own CDN is shown or sent (access `gifs.ts` `GIF_MEDIA_HOST`).
    public static let mediaHost = "static.klipy.com"
    public static func mediaURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host?.lowercased() == mediaHost,
              parts.user == nil, parts.password == nil, parts.port == nil, value.count <= 2048, let url = parts.url else { return nil }
        return url
    }
}
public struct GifMedia: Codable, Equatable, Sendable {
    public let url: String
    public let width: Int
    public let height: Int
}
public struct GifItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// Small (webp or gif) for the picker grid.
    public let preview: GifMedia
    /// The GIF that is sent: its URL becomes the message.
    public let gif: GifMedia
}
public struct GifPage: Codable, Equatable, Sendable {
    public let items: [GifItem]
    public let more: Bool
    public init(items: [GifItem], more: Bool) { self.items = items; self.more = more }
}
/// A refused GIF search, with the desktop's Turkish text.
public struct GifError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "GIFS_NOT_CONFIGURED": "GIF araması kapalı. Sunucuya KLIPY anahtarı eklenmeli."
        case "GIFS_MISSING": "Bu sunucu GIF aramasını henüz desteklemiyor."
        case "RATE_LIMITED": "Çok fazla GIF araması yapıldı. Biraz bekleyip yeniden dene."
        default: "GIF servisine şu an ulaşılamıyor. Biraz sonra yeniden dene."
        }
    }
}
public protocol GifTransport: Sendable {
    /// Trending GIFs for an empty query; 24 per page, pages 1–20.
    func gifs(query: String, page: Int) async throws -> GifPage
}

extension APIClient: GifTransport {
    public func gifs(query: String, page: Int) async throws -> GifPage {
        var parts = URLComponents()
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        parts.queryItems = (text.isEmpty ? [] : [URLQueryItem(name: "q", value: text)]) + [URLQueryItem(name: "page", value: String(min(20, max(1, page))))]
        guard let query = parts.percentEncodedQuery, let url = URL(string: "/rooms-access/v1/gifs?" + query, relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 12)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw GifError(code: "GIFS_UNAVAILABLE") }
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw RoomsError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            guard let page = try? JSONDecoder().decode(GifPage.self, from: data) else { throw RoomsError.invalidResponse }
            // Defense in depth: anything off KLIPY's CDN is dropped, as the service does.
            let items = page.items.prefix(50).filter { GifPolicy.mediaURL($0.preview.url) != nil && GifPolicy.mediaURL($0.gif.url) != nil }
            return GifPage(items: Array(items), more: page.more)
        case 401: throw RoomsError.expired
        case 404: throw GifError(code: "GIFS_MISSING")
        case 429: throw GifError(code: "RATE_LIMITED")
        default:
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"].string ?? ""
            throw GifError(code: code == "GIFS_NOT_CONFIGURED" ? code : "GIFS_UNAVAILABLE")
        }
    }
}

/// Bounded downloads from a fixed set of public third-party hosts (KLIPY's GIF CDN, LRCLIB).
/// No session token, cookies or redirects ever leave the app for these hosts.
public actor ExternalFetcher {
    public static let shared = ExternalFetcher()
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }
    public func data(_ url: URL, allowedHosts: Set<String>, limit: Int, headers: [String: String] = [:]) async throws -> Data {
        guard url.scheme == "https", let host = url.host?.lowercased(), allowedHosts.contains(host), url.user == nil, url.password == nil else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw RoomsError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw http.statusCode == 404 ? RoomsError.denied : RoomsError.unavailable }
            guard http.expectedContentLength <= Int64(limit) else { throw RoomsError.fileTooLarge }
            // Stop reading as soon as the limit is passed instead of buffering an oversized body.
            var data = Data(); data.reserveCapacity(min(limit, max(0, Int(http.expectedContentLength))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw RoomsError.fileTooLarge }
            }
            return data
        } catch let error as RoomsError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw RoomsError.unavailable }
    }
}
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
