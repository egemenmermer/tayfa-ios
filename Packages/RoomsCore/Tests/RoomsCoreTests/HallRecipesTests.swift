import Foundation
import XCTest
@testable import RoomsCore

final class HallRecipesTests: XCTestCase {
    /// A hall snapshot; `items` are `(id, ref, live)` and `current` the playing id.
    private func hall(_ items: [(String, String, Bool)], current: String?, primary: String? = "hall", controlMode: String? = nil) throws -> ActivityRoom {
        let queue = items.map { #"{"id":"\#($0.0)","addedBy":"ece","media":{"kind":"community-media","ref":"\#($0.1)","title":"\#($0.1)","live":\#($0.2)}}"# }.joined(separator: ",")
        let mode = controlMode.map { #","controlMode":"\#($0)","controllers":[]"# } ?? ""
        let head = primary.map { #"{"activity":"\#($0)","title":"Sinema salonu","hostUserId":"host","startedAt":1,"state":"live"\#(mode)}"# } ?? "null"
        let json = #"""
        {"protocolVersion":1,"serverTimeMs":1,"events":[],"room":{"roomId":"hall","revision":3,
         "participants":[{"userId":"host","displayName":"Host","joinedAt":1,"lastSeenAt":1,"canControl":true},{"userId":"ece","displayName":"Ece","joinedAt":2,"lastSeenAt":2,"canControl":true}],
         "primary":\#(head),"timeline":{"playing":true,"positionSec":0,"rate":1,"effectiveServerTimeMs":1,"epoch":1,"itemId":\#(current.map { "\"\($0)\"" } ?? "null")},
         "queue":[\#(queue)],"polls":[],"whiteboard":[]}}
        """#
        return try JSONDecoder().decode(ActivityResponse.self, from: Data(json.utf8)).room
    }
    private let film = ActivityMedia.community(ref: "m-film", title: "Film", live: false, art: nil)
    private let channel = ActivityMedia.community(ref: "l-trt1", title: "TRT 1", live: true, art: nil)

    func testOpeningInAnIdleHallStartsItAndPlaysAtOnce() {
        XCTAssertEqual(HallRecipes.openNow(nil, media: film, itemID: "n1"), [.start(activity: "hall", title: "Sinema salonu"), .addMedia(itemID: "n1", media: film, start: true)])
        XCTAssertEqual(HallRecipes.suggest(nil, media: film, itemID: "n1"), [.start(activity: "hall", title: "Sinema salonu"), .addMedia(itemID: "n1", media: film, start: false)])
        XCTAssertTrue(HallRecipes.opensNow(nil, canDirect: false))
    }
    func testOpeningSomethingAlreadyQueuedSelectsItAndZappingDropsThePreviousLiveChannel() throws {
        let room = try hall([("a", "l-trt1", true), ("b", "m-film", false)], current: "a")
        XCTAssertEqual(HallRecipes.openNow(room, media: film, itemID: "n1"), [.select(itemID: "b", play: true), .remove(itemID: "a")])
        XCTAssertEqual(HallRecipes.openNow(room, media: channel, itemID: "n1"), [], "the playing channel is not reopened")
        let next = ActivityMedia.community(ref: "l-show", title: "Show", live: true, art: nil)
        XCTAssertEqual(HallRecipes.openNow(room, media: next, itemID: "n2"), [.addMedia(itemID: "n2", media: next, start: true), .remove(itemID: "a")])
        XCTAssertEqual(HallRecipes.suggest(room, media: next, itemID: "n3"), [.addMedia(itemID: "n3", media: next, start: false)])
        XCTAssertFalse(HallRecipes.opensNow(room, canDirect: false)); XCTAssertTrue(HallRecipes.opensNow(room, canDirect: true))
    }
    func testAFullQueueDropsItsOldestWatchedItemsFirst() throws {
        let items = (0..<100).map { ("i\($0)", "m-f\($0)", false) }
        let room = try hall(items, current: "i50")
        let commands = HallRecipes.openNow(room, media: film, itemID: "n1")
        XCTAssertEqual(commands, [.remove(itemID: "i0"), .addMedia(itemID: "n1", media: film, start: true)])
        let nothingWatched = try hall(items, current: "i0")
        XCTAssertEqual(HallRecipes.openNow(nothingWatched, media: film, itemID: "n1"), [.addMedia(itemID: "n1", media: film, start: true)])
    }
    func testProgressNeedsTheHallActivity() throws {
        let room = try hall([("a", "m-a", false), ("b", "m-b", false), ("c", "m-c", false)], current: "b")
        XCTAssertEqual(HallRecipes.progress(room).current?.id, "b"); XCTAssertEqual(HallRecipes.progress(room).upcoming.map(\.id), ["c"])
        XCTAssertEqual(HallRecipes.watched(room).map(\.id), ["a"])
        let ended = try hall([("a", "m-a", false)], current: "a", primary: nil)
        XCTAssertNil(HallRecipes.progress(ended).current); XCTAssertTrue(HallRecipes.watched(ended).isEmpty)
        XCTAssertEqual(HallRecipes.openNow(ended, media: film, itemID: "n1").first, .start(activity: "hall", title: "Sinema salonu"))
    }
    func testSteeringFollowsTheHostMode() throws {
        let hostMode = try hall([], current: nil, controlMode: "host")
        XCTAssertTrue(HallRecipes.canDirect(hostMode, me: "host", connected: true)); XCTAssertFalse(HallRecipes.canDirect(hostMode, me: "ece", connected: true))
        XCTAssertFalse(HallRecipes.canDirect(hostMode, me: "host", connected: false))
        XCTAssertEqual(HallRecipes.directReason(connected: true, roleControl: true), "Kumanda ev sahibinde. Sıraya öneri ekleyebilirsin.")
        XCTAssertEqual(HallRecipes.directReason(connected: false, roleControl: true), "Salon hizmeti bağlı değil.")
    }
    func testReorderKeepsThePlayingItemInPlace() throws {
        let room = try hall([("a", "m-a", false), ("b", "m-b", false), ("c", "m-c", false), ("d", "m-d", false)], current: "b")
        XCTAssertEqual(HallRecipes.reorder(room.queue, current: "b", from: IndexSet(integer: 3), to: 2), ["a", "b", "d", "c"])
        XCTAssertNil(HallRecipes.reorder(room.queue, current: "b", from: IndexSet(integer: 3), to: 0), "moving above the playing item shifts it")
        XCTAssertNil(HallRecipes.reorder(room.queue, current: "b", from: IndexSet(integer: 2), to: 3), "no change")
    }
    func testEpisodesAndCatalogItemsBecomeQueueMedia() {
        let series = CinemaItem(ref: "s-dizi", kind: .series, title: "Dizi")
        let episode = try! JSONDecoder().decode(CinemaEpisode.self, from: Data(#"{"ref":"e-5","season":2,"episode":5,"title":"Bölüm","plot":null,"durationSec":null,"art":"0123456789abcdef"}"#.utf8))
        XCTAssertEqual(HallRecipes.episodeMedia(series: series, episode: episode), .community(ref: "e-5", title: "Dizi · 2. Sezon 5. Bölüm", live: false, art: "0123456789abcdef"))
        XCTAssertEqual(HallRecipes.media(CinemaItem(ref: "l-x", kind: .live, title: "  ", art: "bad")), .community(ref: "l-x", title: "Adsız", live: true, art: nil))
    }
    func testNeighbourWrapsAround() {
        let list = ["l-a", "l-b", "l-c"].map { CinemaItem(ref: $0, kind: .live, title: $0) }
        XCTAssertEqual(HallRecipes.neighbour(list, ref: "l-c", step: 1)?.ref, "l-a")
        XCTAssertEqual(HallRecipes.neighbour(list, ref: "l-a", step: -1)?.ref, "l-c")
        XCTAssertEqual(HallRecipes.neighbour(list, ref: "l-x", step: -1)?.ref, "l-c")
        XCTAssertNil(HallRecipes.neighbour([], ref: nil, step: 1))
    }
    func testGuideAndLabels() {
        let list = try! JSONDecoder().decode([CinemaProgramme].self, from: Data(#"[{"start":0,"stop":3600000,"title":"Haber","subTitle":null,"description":null,"category":null},{"start":3600000,"stop":7200000,"title":"Dizi","subTitle":null,"description":null,"category":null}]"#.utf8))
        XCTAssertEqual(HallRecipes.programme(at: 1_800_000, in: list)?.title, "Haber"); XCTAssertEqual(HallRecipes.programme(after: 1_800_000, in: list)?.title, "Dizi")
        XCTAssertEqual(HallRecipes.share(of: list.first, now: 1_800_000), 0.5, accuracy: 0.001)
        XCTAssertEqual(HallRecipes.timeRange(list[1], timeZone: TimeZone(identifier: "UTC")!), "01:00–02:00")
        XCTAssertEqual(HallRecipes.minutesLabel(ms: 45 * 60_000), "45 dk"); XCTAssertEqual(HallRecipes.minutesLabel(ms: 110 * 60_000), "1 sa 50 dk")
        XCTAssertEqual(HallRecipes.minutesLabel(ms: 120 * 60_000), "2 sa"); XCTAssertEqual(HallRecipes.minutesLabel(ms: 0), "1 dk")
        XCTAssertEqual(HallRecipes.did("Sen", "açtı"), "Sen açtın"); XCTAssertEqual(HallRecipes.did("Ece", "ekledi"), "Ece ekledi")
        XCTAssertEqual(HallRecipes.initials("TRT 1 HD", count: 2), "T1"); XCTAssertEqual(HallRecipes.initials("ışık tv", count: 3), "I")
        XCTAssertTrue(HallRecipes.matches("İZMİR TV HD", filter: "izmir tv")); XCTAssertFalse(HallRecipes.matches("TRT Spor", filter: "haber"))
        XCTAssertTrue(HallRecipes.isNew(addedAt: 1_000, now: 1_000 + 86_400_000)); XCTAssertFalse(HallRecipes.isNew(addedAt: nil, now: 1))
        XCTAssertEqual(HallRecipes.rating(7.5), "7,5"); XCTAssertEqual(HallRecipes.rating(8), "8")
    }
    func testErrorsUseHallWording() {
        XCTAssertEqual(HallRecipes.errorText(ActivityError(code: "SESSION_HOST_CONTROL")), "Kumanda ev sahibinde.")
        XCTAssertEqual(HallRecipes.errorText(ActivityError(code: "QUEUE_FULL")), "Sıra dolu. Önce birkaç öğeyi kaldır.")
        XCTAssertEqual(HallRecipes.errorText(ActivityError(code: "QUEUE_END")), "Sırada başka video yok.")
        XCTAssertEqual(HallRecipes.errorText(CinemaError(code: "CINEMA_RELAY_BUSY")), "Hesabın aynı anda açabileceği yayın sınırı dolu.")
        XCTAssertEqual(HallRecipes.errorText(CancellationError()), "Bir şeyler ters gitti. Yeniden dene.")
    }
    func testYouTubeTitlesFromOEmbed() {
        XCTAssertEqual(YouTubeLink.oEmbedURL("dQw4w9WgXcQ")?.absoluteString, "https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ&format=json")
        XCTAssertNil(YouTubeLink.oEmbedURL("bad"))
        XCTAssertEqual(YouTubeLink.oEmbedTitle(status: 200, data: Data(#"{"title":" Şarkı ","author_name":"x"}"#.utf8)), .title("Şarkı"))
        XCTAssertEqual(YouTubeLink.oEmbedTitle(status: 404, data: Data()), .unavailable)
        XCTAssertEqual(YouTubeLink.oEmbedTitle(status: 401, data: Data()), .unknown)
        XCTAssertTrue(YouTubeLink.placeholder("YouTube videosu")); XCTAssertTrue(YouTubeLink.placeholder("YouTube · dQw4w9WgXcQ")); XCTAssertFalse(YouTubeLink.placeholder("Şarkı"))
    }
}
