import Foundation
import XCTest
@testable import RoomsCore

private final class LibraryResponses: @unchecked Sendable {
    static let shared = LibraryResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest, Data) -> (Int, Data) = { _, _ in (503, Data()) }
    func set(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, Data)) { lock.lock(); self.handler = handler; lock.unlock() }
    func reply(_ request: URLRequest, _ body: Data) -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return handler(request, body) }
}
private final class LibraryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        let (status, data) = LibraryResponses.shared.reply(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MusicLibraryTests: XCTestCase {
    private let session = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", track = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private func api() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LibraryURLProtocol.self]
        return APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "test-session", session: URLSession(configuration: config))
    }
    private let catalog = #"""
    [{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","revision":2,"name":"Akşam","updatedAt":"2026-10-17T20:00:00.000Z",
      "tracks":[{"videoId":"dQw4w9WgXcQ","title":"Şarkı","durationSec":212},{"spotifyTrackId":"4uLU6hMCjMI75M1A2tKUQC","title":"Parça","durationSec":0,"artists":["Sanatçı"]}]}]
    """#

    func testHistoryPlaylistsAndCommandsMatchTheDesktopContract() throws {
        let history = try JSONDecoder().decode([MusicHistorySession].self, from: Data(#"[{"id":"\#(session)","startedAt":"2026-10-17T19:00:00.000Z","endedAt":null,"tracks":[{"id":"\#(track)","title":"Şarkı","durationSec":200,"played":true}]}]"#.utf8))
        XCTAssertEqual(history.first?.tracks.first?.played, true); XCTAssertNotNil(history.first?.started)
        let lists = try JSONDecoder().decode([SharedPlaylist].self, from: Data(catalog.utf8))
        XCTAssertEqual(lists.first?.tracks.map(\.id), ["yt:dQw4w9WgXcQ", "sp:4uLU6hMCjMI75M1A2tKUQC"])
        XCTAssertEqual(lists.first?.tracks.last?.json["artists"], .array([.string("Sanatçı")]))
        XCTAssertEqual(PlaylistTrack.youtube(videoID: "dQw4w9WgXcQ", title: "  ", durationSec: 9000).json,
                       .object(["videoId": .string("dQw4w9WgXcQ"), "title": .string("YouTube parçası"), "durationSec": .number(7200)]))
        XCTAssertEqual(PlaylistChange.save(id: nil, revision: nil, name: " Yeni ", tracks: []).json, .object(["op": .string("save"), "name": .string("Yeni"), "tracks": .array([])]))
        XCTAssertEqual(PlaylistChange.save(id: "x", revision: 3, name: "A", tracks: []).json["revision"], .number(3))
        XCTAssertEqual(PlaylistChange.saveQueue(name: "Dinleme", sessionID: session).json, .object(["op": .string("saveQueue"), "name": .string("Dinleme"), "sessionId": .string(session)]))
        XCTAssertEqual(PlaylistChange.importList(name: "L", url: " https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M ").json["url"], .string("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"))
        XCTAssertEqual(PlaylistChange.remove(id: "x", revision: 2).json, .object(["op": .string("remove"), "id": .string("x"), "revision": .number(2)]))
        XCTAssertEqual(MusicCommand.addList(tracks: lists[0].tracks, playNow: false).json["type"], .string("add-list"))
        XCTAssertEqual(MusicCommand.addList(tracks: [], playNow: true).json["playNow"], .bool(true))
        XCTAssertEqual(MusicCommand.restore(sessionID: session, trackID: nil).json, .object(["type": .string("restore"), "sessionId": .string(session)]))
        XCTAssertEqual(MusicCommand.restore(sessionID: session, trackID: track).json["trackId"], .string(track))
        XCTAssertEqual(MusicCommand.reorder(ids: [track, session]).json, .object(["type": .string("reorder"), "ids": .array([.string(track), .string(session)])]))
    }
    func testDJLinksFollowDesktopParsing() {
        XCTAssertEqual(DJLink.parse("dQw4w9WgXcQ"), .video("dQw4w9WgXcQ"))
        XCTAssertEqual(DJLink.parse("https://youtu.be/dQw4w9WgXcQ"), .video("dQw4w9WgXcQ"))
        XCTAssertEqual(DJLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG"), .playlist("PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG"))
        XCTAssertEqual(DJLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ"), .video("dQw4w9WgXcQ"))
        XCTAssertEqual(DJLink.parse("https://m.youtube.com/shorts/dQw4w9WgXcQ"), .video("dQw4w9WgXcQ"))
        XCTAssertNil(DJLink.parse("http://youtu.be/dQw4w9WgXcQ")); XCTAssertNil(DJLink.parse("https://youtube.com:8443/watch?v=dQw4w9WgXcQ")); XCTAssertNil(DJLink.parse("https://vimeo.com/1"))
        XCTAssertTrue(DJLink.isPlaylist("https://open.spotify.com/intl-tr/playlist/37i9dQZF1DXcBWIGoYBM5M"))
        XCTAssertTrue(DJLink.isPlaylist("https://music.youtube.com/playlist?list=PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG"))
        XCTAssertFalse(DJLink.isPlaylist("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"))
    }
    func testLyricsParseNormalizeAndMatchLikeDesktop() throws {
        let lines = MusicLyrics.parse(synced: "[00:12.5]İkinci\n[00:01.00][00:20.250]Nakarat <b>\r\n[xx]bozuk\n[00:05]Birinci")
        XCTAssertEqual(lines.map(\.time), [1, 5, 12.5, 20.25]); XCTAssertEqual(lines.map(\.text), ["Nakarat b", "Birinci", "İkinci", "Nakarat b"])
        XCTAssertEqual(MusicLyrics.activeLine(lines, at: 0.5), nil); XCTAssertEqual(MusicLyrics.activeLine(lines, at: 13), 2)
        XCTAssertEqual(MusicLyrics.normalize("Tarkan — Şımarık!! (Ýeni)"), "tarkan simarik yeni")
        let exact = try XCTUnwrap(MusicLyrics.request(title: "Tarkan - Şımarık (Official Video)", durationSec: 211))
        XCTAssertTrue(exact.exact); XCTAssertEqual(exact.query, "Tarkan - Şımarık")
        XCTAssertEqual(URLComponents(url: exact.url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.value), ["Tarkan", "Şımarık", "211"])
        XCTAssertEqual(exact.url.host, "lrclib.net"); XCTAssertEqual(exact.url.path, "/api/get")
        let search = try XCTUnwrap(MusicLyrics.request(title: "Sezen Aksu Gülümse [Lyrics] · YouTube", durationSec: 200.5))
        XCTAssertFalse(search.exact); XCTAssertEqual(search.query, "Sezen Aksu Gülümse"); XCTAssertEqual(search.url.path, "/api/search")
        XCTAssertNil(MusicLyrics.request(title: "x", durationSec: 0))
        let record = #"{"trackName":"Şımarık","artistName":"Tarkan","duration":212,"instrumental":false,"syncedLyrics":"[00:01.00]Öp"}"#
        XCTAssertEqual(MusicLyrics.match(Data(record.utf8), exact: true, query: exact.query, durationSec: 211), .found([.init(time: 1, text: "Öp")]))
        XCTAssertEqual(MusicLyrics.match(Data(record.utf8), exact: true, query: exact.query, durationSec: 220), .unavailable)
        XCTAssertEqual(MusicLyrics.match(Data("[\(record),\(record)]".utf8), exact: false, query: exact.query, durationSec: 211), .unavailable)
        XCTAssertEqual(MusicLyrics.match(Data(record.replacingOccurrences(of: #""instrumental":false"#, with: #""instrumental":true"#).utf8), exact: true, query: exact.query, durationSec: 211), .instrumental)
    }
    func testLibraryRequestsUseTheMusicRoutesAndDesktopErrors() async throws {
        LibraryResponses.shared.set { [catalog] request, body in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-session" else { return (401, Data()) }
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("GET", "/rooms-access/v1/music/room/history"): return (200, Data("[]".utf8))
            case ("GET", "/rooms-access/v1/music/room/playlists"): return (200, Data(catalog.utf8))
            case ("POST", "/rooms-access/v1/music/room/playlists"):
                let change = try? JSONDecoder().decode(JSONValue.self, from: body)
                return change?["op"] == .string("remove") ? (409, Data(#"{"error":"MUSIC_PLAYLIST_CHANGED"}"#.utf8)) : (200, Data(catalog.utf8))
            default: return (404, Data())
            }
        }
        let client = try api()
        let history = try await client.musicHistory(channel: "room"); XCTAssertTrue(history.isEmpty)
        let lists = try await client.musicPlaylists(channel: "room"); XCTAssertEqual(lists.first?.name, "Akşam")
        let saved = try await client.changeMusicPlaylist(channel: "room", .saveQueue(name: "Kuyruk", sessionID: nil)); XCTAssertEqual(saved.count, 1)
        do { _ = try await client.changeMusicPlaylist(channel: "room", .remove(id: "x", revision: 1)); XCTFail("expected a refusal") }
        catch let error as MusicError { XCTAssertEqual(error.localizedDescription, "Liste başka biri tarafından değiştirildi. Yenileyip tekrar dene.") }
    }
}
