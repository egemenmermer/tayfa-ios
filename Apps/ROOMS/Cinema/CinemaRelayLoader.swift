import AVFoundation
import Foundation
import RoomsCore
import UniformTypeIdentifiers

/// Serves the relay's media playlist to AVPlayer under `roomscinema://stream/<session>/index.m3u8`.
///
/// Every relay URL carries a 120-second ticket that Electron swaps per request (`community-cinema.ts`
/// `ticketFor`/`serve`). AVPlayer keeps reloading a live-style playlist from one URL, so the playlist goes
/// through this delegate: each reload is fetched with the current ticket (renewed 30 s before it expires,
/// renewed once more after a 401) and rewritten so `init.mp4` and the segments are absolute HTTPS relay URLs
/// under that ticket. AVFoundation only lets a resource loader answer playlists and keys; media segments
/// must come over HTTP(S), which they now do straight from the relay.
///
/// Answering a playlist: when AVFoundation asks for content information, give it the playlist UTI, the byte
/// length and no byte-range access; hand the bytes from the requested offset to `dataRequest.respond(with:)`;
/// then `finishLoading()`. `public.m3u-playlist` is the UTI the system assigns to `.m3u8` and to
/// `application/vnd.apple.mpegurl`, and it is one of `AVURLAsset.audiovisualTypes()`; an unknown UTI would
/// fail playback. Refusals end the request with `finishLoading(with:)`, which fails the player item.
final class CinemaRelayLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "roomscinema"
    let session: String
    /// AVFoundation calls the delegate on this queue; answers go back on it too.
    let queue = DispatchQueue(label: "rooms.cinema.relay-loader")
    private let api: APIClient
    private let tickets: CinemaTicketStore
    private let onGone: @Sendable () -> Void
    private let onPlaylist: @Sendable (CinemaPlaylist.Summary) -> Void
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// `onGone`: the relay session ended or restarted (404/410, or no ticket any more), so watch again.
    /// `onPlaylist`: every served playlist, for the playing-date fallback and the end marker.
    init(api: APIClient, hallID: String, watch: CinemaWatch, onGone: @escaping @Sendable () -> Void, onPlaylist: @escaping @Sendable (CinemaPlaylist.Summary) -> Void) {
        self.api = api; session = watch.session; self.onGone = onGone; self.onPlaylist = onPlaylist
        let session = watch.session
        tickets = CinemaTicketStore(ticket: watch.ticket, ttlMs: watch.ttlMs) { try await api.cinemaRenewTicket(hall: hallID, session: session) }
    }

    var url: URL { URL(string: "\(Self.scheme)://stream/\(session)/index.m3u8")! }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme, url.host == "stream", url.pathComponents == ["/", session, "index.m3u8"] else { return false }
        let pending = PendingPlaylist(loadingRequest, queue: queue), id = ObjectIdentifier(loadingRequest)
        // Registered under the lock, so the task cannot unregister itself before it is stored.
        lock.withLock { tasks[id] = Task { [weak self] in await self?.serve(pending, id: id) } }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }
    /// Stops every playlist request still in flight (the player moved on).
    func cancelAll() { lock.withLock { let all = tasks; tasks = [:]; return all }.values.forEach { $0.cancel() } }

    private func serve(_ pending: PendingPlaylist, id: ObjectIdentifier) async {
        defer { _ = lock.withLock { tasks.removeValue(forKey: id) } }
        do {
            guard var ticket = await tickets.current() else { throw CinemaError(code: "CINEMA_RELAY_GONE") }
            var data: Data
            do { data = try await api.cinemaRelayFile(ticket: ticket, file: "index.m3u8") }
            catch let error as CinemaError where error.ticketExpired {
                // Clock skew or a lost renewal: renew once and retry.
                guard let renewed = await tickets.current(force: true) else { throw CinemaError(code: "CINEMA_RELAY_GONE") }
                ticket = renewed
                data = try await api.cinemaRelayFile(ticket: ticket, file: "index.m3u8")
            }
            try Task.checkCancellation()
            let base = try await api.cinemaRelayURL(ticket: ticket, file: "index.m3u8").deletingLastPathComponent()
            let text = String(decoding: data, as: UTF8.self)
            let playlist = try CinemaPlaylist.rewrite(text, base: base)
            onPlaylist(CinemaPlaylist.summary(text))
            pending.respond(with: Data(playlist.utf8))
        } catch is CancellationError {
            return
        } catch let error as CinemaError where error.needsNewWatch || error.ticketExpired {
            onGone()
            pending.fail(error)
        } catch {
            pending.fail(error)
        }
    }
}

/// One playlist request from AVFoundation, answered on the loader's queue.
private final class PendingPlaylist: @unchecked Sendable {
    private let request: AVAssetResourceLoadingRequest
    private let queue: DispatchQueue
    init(_ request: AVAssetResourceLoadingRequest, queue: DispatchQueue) { self.request = request; self.queue = queue }

    func respond(with data: Data) {
        queue.async { [self] in
            guard !request.isCancelled, !request.isFinished else { return }
            if let info = request.contentInformationRequest {
                info.contentType = UTType.m3uPlaylist.identifier
                info.contentLength = Int64(data.count)
                info.isByteRangeAccessSupported = false
            }
            if let url = request.request.url {
                request.response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store"])
            }
            if let dataRequest = request.dataRequest {
                let start = Int(min(Int64(data.count), max(0, dataRequest.currentOffset)))
                let end = dataRequest.requestsAllDataToEndOfResource ? data.count : min(data.count, Int(dataRequest.requestedOffset) + dataRequest.requestedLength)
                if start < end { dataRequest.respond(with: data.subdata(in: start..<end)) }
            }
            request.finishLoading()
        }
    }
    func fail(_ error: Error) {
        let message = error.localizedDescription
        queue.async { [self] in
            guard !request.isCancelled, !request.isFinished else { return }
            request.finishLoading(with: NSError(domain: "ROOMSCinemaRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
}
