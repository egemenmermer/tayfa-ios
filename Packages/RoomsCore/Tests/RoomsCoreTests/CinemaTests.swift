import Foundation
import XCTest
@testable import RoomsCore

private final class CinemaResponses: @unchecked Sendable {
    static let shared = CinemaResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (503, Data()) }
    func set(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { lock.lock(); self.handler = handler; lock.unlock() }
    func reply(_ request: URLRequest) -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return handler(request) }
}
private final class CinemaStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = CinemaResponses.shared.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CinemaTests: XCTestCase {
    private let ticket = "eyJzIjoiYWJjIn0." + String(repeating: "A", count: 43)
    private func api() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CinemaStub.self]
        return APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "test-session", session: URLSession(configuration: config))
    }

    func testDecodesTheServiceShapes() throws {
        let status = try JSONDecoder().decode(CinemaStatus.self, from: Data(#"""
        {"communityId":"srv","hallChannelId":"hall","isOwner":false,"connected":true,"source":null,"account":null,
         "catalog":{"live":20000,"movies":60000,"series":8000,"programmes":0,"importedAt":1,"guideImportedAt":null},
         "importing":{"step":"movies","counts":{"live":1,"movies":2,"series":0,"programmes":0},"error":null,"startedAt":1,"finishedAt":null},"relaySlots":2}
        """#.utf8))
        XCTAssertEqual(status.hallChannelId, "hall"); XCTAssertTrue(status.importRunning); XCTAssertEqual(status.catalog.movies, 60000)
        let page = try JSONDecoder().decode(CinemaItemPage.self, from: Data(#"""
        {"items":[{"ref":"l-trt1","kind":"live","title":"TRT 1","badges":["FHD"],"categoryId":"c1","number":1,"art":"0123456789abcdef","year":null,"rating":null,"addedAt":null,"hasGuide":true}],"total":1}
        """#.utf8))
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.media, ActivityMedia.community(ref: "l-trt1", title: "TRT 1", live: true, art: "0123456789abcdef"))
        let details = try JSONDecoder().decode(CinemaDetails.self, from: Data(#"""
        {"item":{"ref":"s-dizi","kind":"series","title":"Dizi","badges":[],"categoryId":null,"number":null,"art":null,"year":2024,"rating":7.5,"addedAt":null,"hasGuide":false},
         "plot":"Konu","genre":null,"cast":null,"director":null,"durationSec":null,"backdrop":null,
         "seasons":[{"season":1,"episodes":[{"ref":"e-1","season":1,"episode":2,"title":"Bölüm","plot":null,"durationSec":2700,"art":null}]}],
         "versions":[{"ref":"s-dizi4k","badges":["4K"]}]}
        """#.utf8))
        XCTAssertEqual(details.seasons.first?.episodes.first?.episode, 2); XCTAssertEqual(details.versions?.first?.badges, ["4K"])
        let watch = try JSONDecoder().decode(CinemaWatch.self, from: Data(#"""
        {"session":"0123456789abcdef0123456789abcdef","ticket":"t","expiresAt":120000,"itemRef":"m-film","live":false,"durationSec":5400,"offsetSec":598,
         "epoch":3,"ttlMs":120000,"originPdtMs":null,"audioTracks":[{"index":0,"label":"Almanca"},{"index":1,"label":"Türkçe"}],"audioTrack":1}
        """#.utf8))
        XCTAssertNil(watch.originPdtMs); XCTAssertEqual(watch.audioTracks.count, 2); XCTAssertEqual(watch.audioTrack, 1)
    }

    func testRequestsUseTheRawSessionTokenAndMapErrorCodes() async throws {
        CinemaResponses.shared.set { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "test-session" else { return (403, Data(#"{"error":"CINEMA_ACCESS_DENIED"}"#.utf8)) }
            switch request.url?.path {
            case "/rooms-cinema/v1/halls/hall/categories": return request.url?.query == "kind=movie" ? (200, Data(#"[{"id":"c1","kind":"movie","label":"Aksiyon","flag":null,"count":3}]"#.utf8)) : (400, Data())
            case "/rooms-cinema/v1/halls/hall/watch": return (409, Data(#"{"error":"CINEMA_NOTHING_SELECTED"}"#.utf8))
            case "/rooms-cinema/v1/halls/hall/search": return request.url?.query?.contains("q=a%C4%9Fa") == true ? (200, Data("[]".utf8)) : (400, Data())
            default: return (404, Data())
            }
        }
        let api = try api()
        let categories = try await api.cinemaCategories(hall: "hall", kind: .movie)
        XCTAssertEqual(categories.first?.label, "Aksiyon")
        let found = try await api.cinemaSearch(hall: "hall", query: " ağa ")
        XCTAssertTrue(found.isEmpty)
        do { _ = try await api.cinemaWatch(hall: "hall"); XCTFail("expected a refusal") }
        catch let error as CinemaError { XCTAssertEqual(error.code, "CINEMA_NOTHING_SELECTED"); XCTAssertEqual(error.localizedDescription, "Salonda şu an açık bir şey yok.") }
        do { _ = try await api.cinemaDetails(hall: "hall", ref: "../x"); XCTFail("expected a refusal") }
        catch let error as CinemaError { XCTAssertEqual(error.code, "CINEMA_ITEM_NOT_FOUND") }
    }

    func testRelayFilesUseTheTicketPathAndSignalRenewalOrRewatch() async throws {
        let api = try api()
        let url = try await api.cinemaRelayURL(ticket: ticket, file: "index.m3u8")
        XCTAssertEqual(url.absoluteString, "https://rooms.test/rooms-cinema/v1/relay/\(ticket)/index.m3u8")
        do { _ = try await api.cinemaRelayURL(ticket: "not a ticket", file: "index.m3u8"); XCTFail("expected a refusal") } catch {}
        CinemaResponses.shared.set { request in
            guard request.value(forHTTPHeaderField: "Authorization") == nil else { return (400, Data()) }
            return request.url?.lastPathComponent == "index.m3u8" ? (401, Data()) : (410, Data())
        }
        do { _ = try await api.cinemaRelayFile(ticket: ticket, file: "index.m3u8"); XCTFail("expected a refusal") }
        catch let error as CinemaError { XCTAssertTrue(error.ticketExpired) }
        do { _ = try await api.cinemaRelayFile(ticket: ticket, file: "seg000001.m4s"); XCTFail("expected a refusal") }
        catch let error as CinemaError { XCTAssertTrue(error.needsNewWatch) }
    }

    func testHallQueueAndSessionCommandsMatchTheProtocol() throws {
        let media = ActivityMedia.community(ref: "m-film", title: "  Film  ", live: false, art: "not-hex")
        let add = ActivityCommand.addMedia(itemID: "i1", media: media, start: true).json
        XCTAssertEqual(add["type"], .string("queue.add")); XCTAssertEqual(add["start"], .bool(true))
        XCTAssertEqual(add["media"], .object(["kind": .string("community-media"), "ref": .string("m-film"), "title": .string("Film"), "live": .bool(false)]))
        XCTAssertEqual(ActivityCommand.addMedia(itemID: "i2", media: .youtube(videoID: "aaaaaaaaaaa", title: ""), start: false).json["media"]["title"], .string("YouTube videosu"))
        XCTAssertEqual(ActivityCommand.start(activity: "hall", title: "Sinema salonu").json, .object(["type": .string("start"), "activity": .string("hall"), "title": .string("Sinema salonu")]))
        XCTAssertEqual(ActivityCommand.clear.json, .object(["type": .string("queue.clear")]))
        XCTAssertEqual(ActivityCommand.reorder(itemIDs: ["b", "a"]).json["itemIds"], .array([.string("b"), .string("a")]))
        XCTAssertEqual(ActivityCommand.sessionControl(hostOnly: true).json["mode"], .string("host"))
        XCTAssertEqual(ActivityCommand.sessionPermit(userID: "u", allowed: false).json["allowed"], .bool(false))
        XCTAssertEqual(ActivityCommand.sessionHost(userID: "u").json["type"], .string("session.host"))
    }

    func testHallSnapshotAndWhiteboardDecode() throws {
        let raw = #"""
        {"protocolVersion":1,"serverTimeMs":2000,"events":[],"replayRequired":false,"room":{"roomId":"hall","revision":9,
         "participants":[{"userId":"host","displayName":"Host","joinedAt":1,"lastSeenAt":1,"canControl":true}],
         "primary":{"activity":"hall","title":"Sinema salonu","hostUserId":"host","startedAt":1,"state":"live","controlMode":"host","controllers":[]},
         "timeline":{"playing":true,"positionSec":0,"rate":1,"effectiveServerTimeMs":1000,"epoch":4,"itemId":"a"},
         "queue":[{"id":"a","addedBy":"host","media":{"kind":"community-media","ref":"l-trt1","title":"TRT 1","live":true,"art":null}}],
         "polls":[],"whiteboard":[{"id":"w1","kind":"stroke","points":[[1,2],[3,4.5]],"color":"#ff0000","width":3,"authorId":"host"}]}}
        """#
        let room = try JSONDecoder().decode(ActivityResponse.self, from: Data(raw.utf8)).room
        XCTAssertTrue(room.primary?.sharedPlayer == true); XCTAssertTrue(room.primary?.hostOnly == true)
        XCTAssertTrue(room.current?.media.isLive == true); XCTAssertEqual(room.current?.media.ref, "l-trt1")
        XCTAssertFalse(room.ends("viewer")); XCTAssertTrue(room.ends("host"))
        let element = try XCTUnwrap(room.whiteboard?.first)
        XCTAssertEqual(element.points.last, WhiteboardElement.Point(x: 3, y: 4.5))
        let put = ActivityCommand.whiteboardPut(WhiteboardElement(id: "w2", kind: "stroke", points: [.init(x: -5, y: 5000)], color: "#00ff00", width: 40)).json
        XCTAssertEqual(put["element"]["points"], .array([.array([.number(0), .number(4096)])])); XCTAssertEqual(put["element"]["width"], .number(24))
        XCTAssertEqual(ActivityCommand.whiteboardRemove(elementID: "w1").json["elementId"], .string("w1"))
        XCTAssertEqual(ActivityError(code: "LIVE_PLAYBACK_FIXED").localizedDescription, "Canlı yayın herkes için aynı anda akar; sarılamaz.")
    }
}
