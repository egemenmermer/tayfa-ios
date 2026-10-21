import Foundation
import XCTest
@testable import RoomsCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double
    init(_ value: Double) { self.value = value }
    var now: Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ ms: Double) { lock.lock(); value += ms; lock.unlock() }
}

final class HallPlayerTests: XCTestCase {
    private let base = URL(string: "https://rooms.test/rooms-cinema/v1/relay/T.abc/")!
    // ffmpeg's fMP4 HLS output as the relay writes it (`tests/community-cinema-relay.test.ts`).
    private let relay = "#EXTM3U\r\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:12\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2.000000,\n#EXT-X-PROGRAM-DATE-TIME:2026-10-17T18:00:00.000+0000\nseg000012.m4s\n#EXT-X-DISCONTINUITY\n#EXTINF:1.500000,\n#EXT-X-PROGRAM-DATE-TIME:2026-10-17T18:00:02.000+0000\nseg000013.m4s\n#EXT-X-ENDLIST\n"

    func testRewritesTheRelayPlaylistUnderTheCurrentTicket() throws {
        let text = try CinemaPlaylist.rewrite(relay, base: base)
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"https://rooms.test/rooms-cinema/v1/relay/T.abc/init.mp4\""))
        XCTAssertTrue(text.contains("\nhttps://rooms.test/rooms-cinema/v1/relay/T.abc/seg000012.m4s\n"))
        XCTAssertTrue(text.contains("#EXT-X-PROGRAM-DATE-TIME:2026-10-17T18:00:00.000+00:00"))
        XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY\n") && text.hasSuffix("#EXT-X-ENDLIST\n") && text.hasPrefix("#EXTM3U\n"))
        XCTAssertFalse(text.contains("\r"))
        let summary = CinemaPlaylist.summary(text)
        XCTAssertEqual(summary, CinemaPlaylist.Summary(mediaSequence: 12, durations: [2, 1.5], ended: true, discontinuity: true, firstPdtMs: CinemaPlaylist.dateMs("2026-10-17T18:00:00Z")))
        XCTAssertEqual(CinemaPlaylist.dateMs("2026-10-17T18:00:00.000+0000"), CinemaPlaylist.dateMs("2026-10-17T20:00:00+02:00"))
        XCTAssertEqual(CinemaPlaylist.summary("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:3\n#EXTINF:2.000,\nseg000003.m4s\n").firstPdtMs, nil)
    }
    func testRefusesAnythingButRelayFileNames() {
        for bad in ["#EXTM3U\nhttps://evil.example/seg.m4s\n", "#EXTM3U\n../seg.m4s\n", "#EXTM3U\n#EXT-X-MAP:URI=\"/etc/x\"\n", "seg000001.m4s\n", "#EXTM3U\n#EXT-X-MAP:BYTERANGE=1\n"] {
            XCTAssertThrowsError(try CinemaPlaylist.rewrite(bad, base: base), bad)
        }
        XCTAssertThrowsError(try CinemaPlaylist.rewrite(relay, base: URL(string: "http://rooms.test/relay/T/")!))
        XCTAssertThrowsError(try CinemaPlaylist.rewrite(relay, base: URL(string: "https://rooms.test/relay/T")!))
    }

    func testLiveAlignsOnTheRelayEdge() {
        XCTAssertEqual(HallSync.liveRate(0.4), 1); XCTAssertEqual(HallSync.liveRate(0.6), 1.05); XCTAssertEqual(HallSync.liveRate(-0.6), 0.95)
        XCTAssertNil(HallSync.liveRate(3.1)); XCTAssertNil(HallSync.liveRate(-3.1))
        // The relay's 16 s window (8 two-second segments): the hall's target is three segments behind its end.
        let window = 100.0...116
        XCTAssertEqual(HallSync.liveEdge(window), 110)
        XCTAssertEqual(HallSync.live(currentTime: 110, window: window, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 1, behindLive: false))
        XCTAssertEqual(HallSync.live(currentTime: 110.4, window: window, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 1, behindLive: false))
        XCTAssertEqual(HallSync.live(currentTime: 109, window: window, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 1.05, behindLive: false))
        XCTAssertEqual(HallSync.live(currentTime: 111, window: window, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 0.95, behindLive: false))
        // Far behind: one jump to the target, then normal speed until the 3 s guard has passed.
        XCTAssertEqual(HallSync.live(currentTime: 103, window: window, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: 110, rate: 1, behindLive: true))
        XCTAssertEqual(HallSync.live(currentTime: 103, window: window, nowMs: 1000, seekAllowedAtMs: 4000), .init(seekTo: nil, rate: 1, behindLive: true))
        XCTAssertEqual(HallSync.live(currentTime: 106, window: window, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: 110, rate: 1, behindLive: false))
        // A player left before the window never aims below its start.
        XCTAssertEqual(HallSync.live(currentTime: 90, window: 100...104, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: 100, rate: 1, behindLive: true))
        // Ahead of the hall: slow down, never jump back over what this viewer already saw.
        XCTAssertEqual(HallSync.live(currentTime: 115.5, window: window, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 0.95, behindLive: false))
        XCTAssertEqual(HallSync.live(currentTime: 110, window: nil, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 1, behindLive: false))
    }
    func testLiveIgnoresTheWallClockWhenTheRelayRunsAhead() {
        // A provider's connect burst put the relay's PROGRAM-DATE-TIME 20 s ahead of the wall clock. The old target
        // (server clock − 10 s) sat 30 s behind the live edge, outside the 16 s window: it seeked to the window
        // start, that segment slid out within 2 s, the player fell back to the edge and the seek came again.
        // The step takes no clock or date at all; `nowMs` only paces the jumps.
        for nowMs in [1000.0, 21_000, 1_800_000_000_000] {
            XCTAssertEqual(HallSync.live(currentTime: 110, window: 100...116, nowMs: nowMs, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 1, behindLive: false))
        }
        // Two minutes of that relay (20 s burst, then real time in 2 s segments) from the window start.
        var current = 4.0, seekAllowedAtMs = 0.0, seeks: [Double] = []
        for second in 0..<120 {
            let nowMs = 1_800_000_000_000 + Double(second) * 1000, end = 2 * ((20 + Double(second)) / 2).rounded(.down)
            let window = max(0, end - 16)...end
            XCTAssertTrue(window.contains(current), "second \(second): \(current) outside \(window)")
            let step = HallSync.live(currentTime: current, window: window, nowMs: nowMs, seekAllowedAtMs: seekAllowedAtMs)
            if let target = step.seekTo { seeks.append(target); seekAllowedAtMs = nowMs + 3000 }
            current = (step.seekTo ?? current) + step.rate
        }
        XCTAssertEqual(seeks, [14], "one jump to the edge, then only gentle rates")
        XCTAssertFalse(seeks.contains { $0 <= 4.5 }, "never back to the window start")
    }
    func testLiveWaitsOnAStalledUpstreamInsteadOfReplaying() {
        // The upstream stops: the window's end stays at 116 while this viewer plays on to it and waits there.
        var current = 110.0, seeks = 0
        for second in 0..<30 {
            let step = HallSync.live(currentTime: current, window: 100...116, nowMs: Double(second) * 1000, seekAllowedAtMs: 0)
            if step.seekTo != nil { seeks += 1 }
            current = min(116, current + step.rate)
        }
        XCTAssertEqual(seeks, 0)
        XCTAssertEqual(current, 116)
    }
    func testAShortFreshRelayWindowTargetsItsStart() {
        XCTAssertEqual(HallSync.liveEdge(0...4), 0)
        XCTAssertEqual(HallSync.live(currentTime: 0.3, window: 0...4, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 1, behindLive: false))
        XCTAssertEqual(HallSync.live(currentTime: 3.8, window: 0...4, nowMs: 1000, seekAllowedAtMs: 0), .init(seekTo: nil, rate: 0.95, behindLive: false))
        XCTAssertEqual(HallSync.liveEdge(0...10), 4)
    }
    func testFilmsFollowTheRoomAndWatchAgainOutsideTheRelayWindow() {
        XCTAssertEqual(HallSync.workPosition(offsetSec: 598, originPdtMs: 1_000_000, playingDateMs: 1_010_000, currentTime: 3), 608)
        XCTAssertEqual(HallSync.workPosition(offsetSec: 598, originPdtMs: nil, playingDateMs: 1_010_000, currentTime: 3), 601)
        XCTAssertEqual(HallSync.estimatedDateMs(firstPdtMs: 5000, windowStart: 2, currentTime: 4), 7000)
        var timers = HallSync.VODTimers()
        XCTAssertEqual(HallSync.vod(target: 100.5, work: 100, currentTime: 20, window: 0...60, nowMs: 1000, timers: &timers), .none)
        XCTAssertEqual(HallSync.vod(target: 102, work: 100, currentTime: 20, window: 0...60, nowMs: 1000, timers: &timers), .seek(22))
        XCTAssertEqual(HallSync.vod(target: 104, work: 100, currentTime: 22, window: 0...60, nowMs: 2000, timers: &timers), .none, "1.5 s between seeks")
        XCTAssertEqual(HallSync.vod(target: 104, work: 100, currentTime: 22, window: 0...60, nowMs: 2600, timers: &timers), .seek(26))
        XCTAssertEqual(HallSync.vod(target: 199, work: 100, currentTime: 22, window: 0...60, nowMs: 3000, timers: &timers), .rewatch)
        XCTAssertEqual(timers.rewatchDelayMs, 8000)
        XCTAssertEqual(HallSync.vod(target: 199, work: 100, currentTime: 22, window: 0...60, nowMs: 6000, timers: &timers), .none, "backs off 4 s")
        XCTAssertEqual(HallSync.vod(target: 199, work: 100, currentTime: 22, window: 0...60, nowMs: 7001, timers: &timers), .rewatch)
        for step in 0..<4 { _ = HallSync.vod(target: 199, work: 100, currentTime: 22, window: 0...60, nowMs: 100_000 * Double(step + 1), timers: &timers) }
        XCTAssertEqual(timers.rewatchDelayMs, 30_000)
        XCTAssertEqual(HallSync.vod(target: 100, work: 100, currentTime: 22, window: 0...60, nowMs: 900_000, timers: &timers), .none)
        XCTAssertEqual(timers.rewatchDelayMs, 4000)
        XCTAssertEqual(HallSync.vod(target: 99, work: 100, currentTime: 0.5, window: 0...60, nowMs: 950_000, timers: &timers), .seek(0), "clamped into the window")
    }
    func testYouTubeResyncRulesAndClock() {
        XCTAssertFalse(HallSync.youtubeNeedsSync(roomPlaying: true, playerState: 2, positionSec: 0, expectedSec: 0, sinceLastSync: 2))
        XCTAssertTrue(HallSync.youtubeNeedsSync(roomPlaying: true, playerState: 2, positionSec: 0, expectedSec: 0, sinceLastSync: 3))
        XCTAssertTrue(HallSync.youtubeNeedsSync(roomPlaying: false, playerState: 1, positionSec: 0, expectedSec: 0, sinceLastSync: 3))
        XCTAssertFalse(HallSync.youtubeNeedsSync(roomPlaying: true, playerState: 1, positionSec: 10, expectedSec: 14, sinceLastSync: 3.5))
        XCTAssertTrue(HallSync.youtubeNeedsSync(roomPlaying: true, playerState: 1, positionSec: 10, expectedSec: 14, sinceLastSync: 4.5))
        XCTAssertFalse(HallSync.youtubeNeedsSync(roomPlaying: true, playerState: 3, positionSec: 10, expectedSec: 14, sinceLastSync: 9))
        XCTAssertEqual(HallSync.clock(65), "1:05"); XCTAssertEqual(HallSync.clock(3725), "1:02:05"); XCTAssertEqual(HallSync.clock(-3), "0:00")
        XCTAssertEqual(HallSync.endKey(itemID: "a", epoch: 3), "a:3"); XCTAssertEqual(HallSync.reconnectDelay(attempt: 2), 1.2, accuracy: 0.0001)
    }

    func testTicketsRenewOnceShortlyBeforeExpiry() async {
        let clock = Clock(0), calls = Counter()
        let store = CinemaTicketStore(ticket: "first", ttlMs: 120_000, now: { clock.now }) {
            try? await Task.sleep(for: .milliseconds(20))
            return CinemaTicket(ticket: "renewed-\(calls.next())", expiresAt: 0, ttlMs: 120_000)
        }
        let early = await store.current()
        XCTAssertEqual(early, "first"); XCTAssertEqual(calls.count, 0)
        clock.advance(91_000)
        async let a = store.current()
        async let b = store.current()
        async let c = store.current()
        let values = await [a, b, c]
        XCTAssertEqual(values, ["renewed-1", "renewed-1", "renewed-1"]); XCTAssertEqual(calls.count, 1, "single flight")
        let forced = await store.current(force: true)
        XCTAssertEqual(forced, "renewed-2")
    }
    func testEndedSessionsAndLostRenewals() async {
        let clock = Clock(0), calls = Counter()
        let flaky = CinemaTicketStore(ticket: "kept", ttlMs: 40_000, now: { clock.now }) { _ = calls.next(); throw CinemaError(code: "CINEMA_UNAVAILABLE") }
        clock.advance(20_000)
        let kept = await flaky.current()
        XCTAssertEqual(kept, "kept", "a lost renewal keeps a ticket that is still valid")
        clock.advance(30_000)
        let expired = await flaky.current()
        XCTAssertNil(expired)
        let ended = CinemaTicketStore(ticket: "old", ttlMs: 1000, now: { clock.now }) { throw CinemaError(code: "CINEMA_SESSION_ENDED") }
        let first = await ended.current(), again = await ended.current(force: true)
        XCTAssertNil(first); XCTAssertNil(again)
    }
}
