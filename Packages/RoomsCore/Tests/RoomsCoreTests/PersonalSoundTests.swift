import Foundation
import XCTest
@testable import RoomsCore

/// Port of desktop `tests/personal-sound-policy.test.ts`, case for case.
final class PersonalCuePolicyTests: XCTestCase {
    private let yes: (String) -> Bool = { _ in true }
    private func enter(_ actor: String, _ sound: String? = nil) -> RosterCue { RosterCue(kind: .enter, actor: actor, local: false, sound: sound) }
    private func leave(_ actor: String, _ sound: String? = nil) -> RosterCue { RosterCue(kind: .leave, actor: actor, local: false, sound: sound) }
    private func plays(_ decisions: [CueDecision]) -> [String] { decisions.map { $0.sound == nil ? "classic" : "personal" } }

    func testPlaysTheActorsSoundForAGenuineJoinAndTheClassicCueForTheListenersOwn() {
        var policy = PersonalCuePolicy()
        XCTAssertEqual(policy.push(RosterCue(kind: .enter, actor: "me", local: true, sound: "p.fanfar"), now: 0, allow: yes),
                       [CueDecision(kind: .enter, actor: "me", play: .classic)])
        XCTAssertEqual(policy.push(enter("a", "p.fanfar"), now: 1000, allow: yes),
                       [CueDecision(kind: .enter, actor: "a", play: .personal("p.fanfar"))])
    }
    func testFallsBackToTheClassicCueWithoutASoundOrWhenTheListenerDoesNotAllowIt() {
        var policy = PersonalCuePolicy()
        XCTAssertEqual(plays(policy.push(enter("a"), now: 0, allow: yes)), ["classic"])
        XCTAssertEqual(plays(policy.push(enter("b", "p.kapi"), now: 1000, allow: { $0 != "b" })), ["classic"])
    }
    func testHoldsDeparturesAndSilencesAReconnectInsideTheHold() {
        var policy = PersonalCuePolicy()
        _ = policy.push(enter("a", "p.fanfar"), now: 0, allow: yes)
        XCTAssertEqual(policy.push(leave("a", "p.kapanis"), now: 20_000, allow: yes), [])
        XCTAssertEqual(policy.nextDue(), 21_500)
        XCTAssertEqual(policy.push(enter("a", "p.fanfar"), now: 20_900, allow: yes), [])
        XCTAssertEqual(policy.tick(now: 22_000, allow: yes), [])
        XCTAssertNil(policy.nextDue())
    }
    func testReleasesAHeldDepartureWithTheActorsLeaveSound() {
        var policy = PersonalCuePolicy()
        _ = policy.push(enter("a"), now: 0, allow: yes)
        _ = policy.push(leave("a", "p.kapanis"), now: 60_000, allow: yes)
        XCTAssertEqual(policy.tick(now: 61_000, allow: yes), [])
        XCTAssertEqual(policy.tick(now: 61_500, allow: yes), [CueDecision(kind: .leave, actor: "a", play: .personal("p.kapanis"))])
    }
    func testUsesTheClassicCueForAQuickReturnAndForAShortStay() {
        var policy = PersonalCuePolicy()
        _ = policy.push(enter("a"), now: 0, allow: yes)
        _ = policy.push(leave("a", "p.kapanis"), now: 60_000, allow: yes)
        _ = policy.tick(now: 61_500, allow: yes)
        XCTAssertEqual(plays(policy.push(enter("a", "p.fanfar"), now: 70_000, allow: yes)), ["classic"])
        _ = policy.push(leave("a", "p.kapanis"), now: 75_000, allow: yes)
        XCTAssertEqual(plays(policy.tick(now: 76_500, allow: yes)), ["classic"])
    }
    func testKeepsTheOriginalJoinTimeAcrossAReconnectForTheShortStayRule() {
        var policy = PersonalCuePolicy()
        _ = policy.push(enter("a"), now: 0, allow: yes)
        _ = policy.push(leave("a"), now: 30_000, allow: yes)
        _ = policy.push(enter("a"), now: 30_500, allow: yes)
        _ = policy.push(leave("a", "p.kapanis"), now: 35_000, allow: yes)
        XCTAssertEqual(plays(policy.tick(now: 36_500, allow: yes)), ["personal"])
    }
    func testLimitsOnePersonalSoundPerPersonAndEventPerCooldown() {
        var policy = PersonalCuePolicy()
        XCTAssertEqual(plays(policy.push(enter("a", "p.fanfar"), now: 0, allow: yes)), ["personal"])
        _ = policy.push(leave("a"), now: 50_000, allow: yes)
        _ = policy.tick(now: 51_500, allow: yes)
        XCTAssertEqual(plays(policy.push(enter("a", "p.fanfar"), now: 100_000, allow: yes)), ["classic"])
        _ = policy.push(leave("a"), now: 110_000, allow: yes)
        _ = policy.tick(now: 111_500, allow: yes)
        XCTAssertEqual(plays(policy.push(enter("a", "p.fanfar"), now: 150_000, allow: yes)), ["personal"])
    }
    func testPlaysOnePersonalSoundPerRoomWindowAndCoalescesABurstOfClassicCues() {
        var policy = PersonalCuePolicy()
        let heard = ["a", "b", "c", "d", "e"].enumerated().flatMap { index, actor in
            policy.push(enter(actor, "p.fanfar"), now: 1000 + Double(index) * 150, allow: yes)
        }
        XCTAssertEqual(heard.filter { $0.sound != nil }.count, 1)
        XCTAssertLessThanOrEqual(heard.filter { $0.sound == nil }.count, 2)
        XCTAssertEqual(plays(policy.push(enter("f", "p.kapi"), now: 6100, allow: yes)), ["personal"])
    }
    func testForgetsPendingDeparturesOnReset() {
        var policy = PersonalCuePolicy()
        _ = policy.push(enter("a"), now: 0, allow: yes)
        _ = policy.push(leave("a", "p.kapanis"), now: 20_000, allow: yes)
        policy.reset()
        XCTAssertNil(policy.nextDue())
        XCTAssertEqual(policy.tick(now: 30_000, allow: yes), [])
    }
    // iPhone additions beyond the desktop cases.
    func testReleasesDeparturesInTheOrderTheyHappened() {
        var policy = PersonalCuePolicy()
        _ = policy.push(leave("z", "p.kapanis"), now: 0, allow: yes)
        _ = policy.push(leave("a", "p.hoscakal"), now: 100, allow: yes)
        XCTAssertEqual(policy.nextDue(), 1_500)
        let released = policy.tick(now: 2_000, allow: yes)
        XCTAssertEqual(released, [CueDecision(kind: .leave, actor: "z", play: .personal("p.kapanis"))])
    }
    func testNumbersMatchTheDesktopContract() {
        let policy = PersonalSoundPolicy.standard
        XCTAssertEqual([policy.leaveHoldMs, policy.rejoinClassicMs, policy.shortStayClassicMs, policy.perPersonCooldownMs,
                        policy.roomWindowMs, policy.classicCoalesceMs, policy.readyDeadlineMs], [1500, 30_000, 10_000, 120_000, 5000, 400, 1500])
        XCTAssertEqual(policy.personalGain, 0.45); XCTAssertEqual(policy.classicGain, 0.55)
        XCTAssertEqual(PersonalSoundLimits.maxClipBytes, 44 + Int((4.05 * 48_000).rounded(.up)) * 2)
        XCTAssertEqual(PersonalSoundAttribute.key(.enter), "rooms.sound.enter")
        XCTAssertEqual(PersonalSoundAttribute.key(.leave), "rooms.sound.leave")
    }
}

final class PersonalSoundModelTests: XCTestCase {
    func testSoundIDsFollowTheContract() {
        for valid in ["p.fanfar", "p.kapi", "p.a", "p." + String(repeating: "a", count: 32), "p.hosca-kal2",
                      "3f2b8c1e-5d6a-4b7c-9e0f-112233445566", "3F2B8C1E-5D6A-1B7C-AE0F-112233445566",
                      "00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"] {
            XCTAssertTrue(PersonalSoundID.isValid(valid), valid)
        }
        for invalid in ["", "p.", "p.Fanfar", "p.fan_far", "p.fanfar\n", "q.fanfar", "p." + String(repeating: "a", count: 33),
                        "../me", "p.a/b", "3f2b8c1e-5d6a-0b7c-9e0f-112233445566", "3f2b8c1e-5d6a-4b7c-7e0f-112233445566",
                        "3f2b8c1e5d6a4b7c9e0f112233445566", "3f2b8c1e-5d6a-4b7c-9e0f-11223344556g", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"] {
            XCTAssertFalse(PersonalSoundID.isValid(invalid), invalid)
        }
        XCTAssertFalse(PersonalSoundID.isUpload("p.fanfar")); XCTAssertFalse(PersonalSoundID.isPreset("3f2b8c1e-5d6a-4b7c-9e0f-112233445566"))
    }
    func testParticipantSoundsComeFromAttributesAndDropInvalidIDs() {
        let sounds = ParticipantSounds(attributes: ["rooms.sound.enter": "p.fanfar", "rooms.sound.leave": "../../etc", "rooms.deafened": "1"])
        XCTAssertEqual(sounds, ParticipantSounds(enter: "p.fanfar"))
        XCTAssertEqual(sounds[.enter], "p.fanfar"); XCTAssertNil(sounds[.leave])
        XCTAssertTrue(ParticipantSounds(attributes: [:]).isEmpty)
        XCTAssertTrue(ParticipantSounds(attributes: ["rooms.sound.enter": ""]).isEmpty)
    }
    private let profileJSON = #"""
    {"assign":{"enter":"3f2b8c1e-5d6a-4b7c-9e0f-112233445566","leave":null},
     "sounds":[{"id":"3f2b8c1e-5d6a-4b7c-9e0f-112233445566","name":"Benim sesim","durationSec":2.5}],
     "presets":[{"id":"p.fanfar","name":"Fanfar","durationSec":1.2},{"id":"p.kapanis","name":"Kapanış","durationSec":1}],
     "uploads":true}
    """#
    func testProfileParsesAndNamesTheChosenSounds() throws {
        let profile = try PersonalSoundProfile.parse(Data(profileJSON.utf8))
        XCTAssertEqual(profile.assign, PersonalSoundAssign(enter: "3f2b8c1e-5d6a-4b7c-9e0f-112233445566"))
        XCTAssertEqual(profile.item(profile.assign.enter)?.name, "Benim sesim")
        XCTAssertEqual(profile.item("p.kapanis")?.name, "Kapanış")
        XCTAssertNil(profile.item(nil)); XCTAssertTrue(profile.uploads)
    }
    func testMalformedProfilesAreRejected() {
        let broken = [
            profileJSON.replacingOccurrences(of: #""p.fanfar""#, with: #""fanfar""#),
            profileJSON.replacingOccurrences(of: #""durationSec":2.5"#, with: #""durationSec":4.5"#),
            profileJSON.replacingOccurrences(of: #""name":"Fanfar""#, with: #""name":"""#),
            profileJSON.replacingOccurrences(of: #""leave":null"#, with: #""leave":"nope""#),
            profileJSON.replacingOccurrences(of: #""uploads":true"#, with: #""uploads":"yes""#),
            profileJSON.replacingOccurrences(of: #""name":"Fanfar""#, with: #""name":"\#(String(repeating: "ş", count: 41))""#),
        ]
        for json in broken { XCTAssertThrowsError(try PersonalSoundProfile.parse(Data(json.utf8)), json) }
    }
    func testAssignAlwaysSendsBothKeysWithNullForClassic() throws {
        let data = try JSONEncoder().encode(PersonalSoundAssign(enter: "p.fanfar", leave: nil))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .object(["enter": .string("p.fanfar"), "leave": .null]))
        XCTAssertEqual(PersonalSoundAssign(enter: "p.fanfar").json, value)
        var assign = PersonalSoundAssign(); assign[.leave] = "p.kapanis"
        XCTAssertEqual(assign.leave, "p.kapanis"); XCTAssertTrue(assign.valid)
        XCTAssertFalse(PersonalSoundAssign(enter: "x").valid)
    }
    func testErrorsUseTheDesktopText() {
        XCTAssertEqual(PersonalSoundError(code: "PERSONAL_SOUNDS_NOT_CONFIGURED").localizedDescription, "Bu sunucuda giriş sesleri henüz açılmadı.")
        XCTAssertEqual(PersonalSoundError(code: "PERSONAL_SOUND_NOT_FOUND").localizedDescription, "Bu ses artık yok.")
        XCTAssertTrue(PersonalSoundError(code: "PERSONAL_SOUNDS_MISSING").unsupported)
        XCTAssertFalse(PersonalSoundError(code: "PERSONAL_SOUND_NOT_FOUND").unsupported)
        XCTAssertEqual(PersonalSoundError(code: "SOMETHING").localizedDescription, "Giriş sesleri alınamadı. Yeniden dene.")
    }
}

final class PersonalSoundPreferenceTests: XCTestCase {
    func testDefaultsAreOnAtFullLevelAndOlderSavedDataGetsThem() throws {
        let fresh = AudioPreferences()
        XCTAssertTrue(fresh.personalSounds); XCTAssertEqual(fresh.soundEffectsLevel, 1); XCTAssertEqual(fresh.mutedEntranceUsers, [])
        let old = try JSONDecoder().decode(AudioPreferences.self, from: Data(#"{"noiseSuppression":false,"roomEventSounds":false,"microphoneOn":true}"#.utf8))
        XCTAssertTrue(old.personalSounds); XCTAssertEqual(old.soundEffectsLevel, 1); XCTAssertEqual(old.mutedEntranceUsers, [])
        XCTAssertFalse(old.roomEventSounds); XCTAssertTrue(old.microphoneOn)
    }
    func testSavedValuesRoundTripAndTheLevelIsClamped() throws {
        var prefs = AudioPreferences()
        prefs.personalSounds = false; prefs.soundEffectsLevel = 0.4
        prefs.setEntranceMuted("loud", true); prefs.setEntranceMuted("", true)
        let restored = try JSONDecoder().decode(AudioPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored, prefs)
        XCTAssertEqual(restored.mutedEntranceUsers, ["loud"])
        prefs.soundEffectsLevel = 3; XCTAssertEqual(prefs.soundEffectsLevel, 1)
        prefs.soundEffectsLevel = -1; XCTAssertEqual(prefs.soundEffectsLevel, 0)
        prefs.soundEffectsLevel = .nan; XCTAssertEqual(prefs.soundEffectsLevel, 1)
        let saved = try JSONDecoder().decode(AudioPreferences.self, from: Data(#"{"soundEffectsLevel":7,"mutedEntranceUsers":["a","a",""],"personalSounds":"no"}"#.utf8))
        XCTAssertEqual(saved.soundEffectsLevel, 1); XCTAssertEqual(saved.mutedEntranceUsers, ["a"]); XCTAssertTrue(saved.personalSounds)
    }
    func testListenerAllowsPersonalSoundsUnlessOffOrMutedForThatPerson() {
        var prefs = AudioPreferences()
        XCTAssertTrue(prefs.allowsPersonalSound(from: "a"))
        prefs.setEntranceMuted("a", true)
        XCTAssertFalse(prefs.allowsPersonalSound(from: "a")); XCTAssertTrue(prefs.allowsPersonalSound(from: "b"))
        prefs.setEntranceMuted("a", false); prefs.personalSounds = false
        XCTAssertFalse(prefs.allowsPersonalSound(from: "a"))
    }
    /// Desktop `personal-sound-mutes.ts`: at most 500, ids of the user-id shape, oldest forgotten first.
    func testEntranceMutesAreCappedValidatedAndKeepTheirOrder() throws {
        var prefs = AudioPreferences()
        for id in ["", "a b", "ü", "a.b", String(repeating: "x", count: 129)] { prefs.setEntranceMuted(id, true) }
        XCTAssertEqual(prefs.mutedEntranceUsers, [])
        prefs.setEntranceMuted("01HZX_user-9", true); prefs.setEntranceMuted(String(repeating: "x", count: 128), true)
        XCTAssertEqual(prefs.mutedEntranceUsers.count, 2)
        for index in 0..<AudioPreferences.maxMutedEntranceUsers { prefs.setEntranceMuted("u\(index)", true) }
        XCTAssertEqual(prefs.mutedEntranceUsers.count, 500)
        XCTAssertFalse(prefs.entranceMuted("01HZX_user-9")); XCTAssertEqual(prefs.mutedEntranceUsers.first, "u0")
        // Muting again keeps the place in line; unmuting removes.
        prefs.setEntranceMuted("u0", true); XCTAssertEqual(prefs.mutedEntranceUsers.first, "u0")
        prefs.setEntranceMuted("u0", false); XCTAssertFalse(prefs.entranceMuted("u0")); XCTAssertEqual(prefs.mutedEntranceUsers.count, 499)
        let restored = try JSONDecoder().decode(AudioPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored.mutedEntranceUsers, prefs.mutedEntranceUsers)
        // Saved lists keep the valid strings in order, once each, and at most the first 500.
        let saved = try JSONDecoder().decode(AudioPreferences.self, from: Data(#"{"mutedEntranceUsers":["b",7,null,"a b","a","b",{"x":1},"c"]}"#.utf8))
        XCTAssertEqual(saved.mutedEntranceUsers, ["b", "a", "c"])
        let long = (0..<600).map { "\"v\($0)\"" }.joined(separator: ",")
        let crowded = try JSONDecoder().decode(AudioPreferences.self, from: Data(("{\"mutedEntranceUsers\":[" + long + "]}").utf8))
        XCTAssertEqual(crowded.mutedEntranceUsers.count, 500); XCTAssertEqual(crowded.mutedEntranceUsers.last, "v499")
        let broken = try JSONDecoder().decode(AudioPreferences.self, from: Data(#"{"mutedEntranceUsers":"a","personalSounds":false}"#.utf8))
        XCTAssertEqual(broken.mutedEntranceUsers, []); XCTAssertFalse(broken.personalSounds)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var counts: [String: Int] = [:]
    func hit(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
}
private struct Failure: Error {}
/// Downloads running at once, and the most ever seen.
private final class Concurrency: @unchecked Sendable {
    private let lock = NSLock(); private var running = 0, peak = 0
    func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
    func leave() { lock.lock(); running -= 1; lock.unlock() }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

final class PersonalSoundCacheTests: XCTestCase {
    func testConcurrentRequestsShareOneDownload() async {
        let cache = PersonalSoundCache(), counter = Counter()
        let fetch: @Sendable () async throws -> Data = {
            counter.hit("p.fanfar"); try await Task.sleep(for: .milliseconds(50)); return Data([1, 2, 3])
        }
        async let first = cache.clip("p.fanfar", fetch: fetch)
        async let second = cache.clip("p.fanfar", fetch: fetch)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, Data([1, 2, 3])); XCTAssertEqual(b, Data([1, 2, 3]))
        XCTAssertEqual(counter.count("p.fanfar"), 1)
        let cached = await cache.clip("p.fanfar", fetch: fetch)
        XCTAssertEqual(cached, Data([1, 2, 3])); XCTAssertEqual(counter.count("p.fanfar"), 1)
    }
    func testKeepsTheMostRecentlyUsedClips() async {
        let cache = PersonalSoundCache(capacity: 2)
        _ = await cache.clip("p.a") { Data([1]) }
        _ = await cache.clip("p.b") { Data([2]) }
        _ = await cache.cached("p.a")
        _ = await cache.clip("p.c") { Data([3]) }
        let count = await cache.count
        let a = await cache.cached("p.a"), b = await cache.cached("p.b"), c = await cache.cached("p.c")
        XCTAssertEqual(count, 2); XCTAssertEqual(a, Data([1])); XCTAssertNil(b); XCTAssertEqual(c, Data([3]))
        XCTAssertEqual(PersonalSoundCache().capacity, 24)
    }
    func testAFailureIsRememberedForAMinute() async {
        let clock = Clock(), counter = Counter()
        let cache = PersonalSoundCache(clock: { clock.now })
        let failing: @Sendable () async throws -> Data = { counter.hit("x"); throw Failure() }
        let first = await cache.clip("p.x", fetch: failing)
        clock.advance(59)
        let second = await cache.clip("p.x", fetch: failing)
        XCTAssertNil(first); XCTAssertNil(second); XCTAssertEqual(counter.count("x"), 1)
        clock.advance(2)
        let third = await cache.clip("p.x") { counter.hit("x"); return Data([9]) }
        XCTAssertEqual(third, Data([9])); XCTAssertEqual(counter.count("x"), 2)
        // An explicit retry (a preview tap) does not wait out the window.
        _ = await cache.clip("p.y", fetch: failing)
        let retried = await cache.clip("p.y", retry: true) { counter.hit("y"); return Data([8]) }
        XCTAssertEqual(retried, Data([8])); XCTAssertEqual(counter.count("y"), 1)
    }
    func testClearForgetsClipsAndDropsALateDownload() async {
        let cache = PersonalSoundCache()
        _ = await cache.clip("p.a") { Data([1]) }
        async let late = cache.clip("p.b") { try await Task.sleep(for: .milliseconds(100)); return Data([2]) }
        try? await Task.sleep(for: .milliseconds(20))
        await cache.clear()
        let dropped = await late
        let a = await cache.cached("p.a"), b = await cache.cached("p.b")
        XCTAssertNil(dropped); XCTAssertNil(a); XCTAssertNil(b)
    }
    func testWantsOnlyClipsItNeitherHasNorIsFetchingNorRecentlyFailed() async {
        let clock = Clock()
        let cache = PersonalSoundCache(clock: { clock.now })
        _ = await cache.clip("p.have") { Data([1]) }
        _ = await cache.clip("p.broken") { throw Failure() }
        async let slow = cache.clip("p.slow") { try await Task.sleep(for: .milliseconds(100)); return Data([2]) }
        try? await Task.sleep(for: .milliseconds(20))
        let have = await cache.wants("p.have"), broken = await cache.wants("p.broken"), loading = await cache.wants("p.slow"), new = await cache.wants("p.new")
        XCTAssertFalse(have); XCTAssertFalse(broken); XCTAssertFalse(loading); XCTAssertTrue(new)
        _ = await slow
        clock.advance(61)
        let retry = await cache.wants("p.broken")
        XCTAssertTrue(retry)
    }
    func testWarmsOneClipAtATimeAndOnlyWhatItLacks() async {
        let clock = Clock(), counter = Counter(), running = Concurrency()
        let cache = PersonalSoundCache(prefetchGap: .zero, clock: { clock.now })
        _ = await cache.clip("p.have") { Data([1]) }
        _ = await cache.clip("p.broken") { throw Failure() }
        func request(_ id: String) -> PersonalSoundCache.Request {
            .init(id) { counter.hit(id); running.enter(); defer { running.leave() }; try await Task.sleep(for: .milliseconds(10)); return Data([7]) }
        }
        await cache.prefetch(["p.have", "p.broken", "p.a", "p.b", "p.c"].map(request))
        await cache.warmed()
        XCTAssertEqual(["p.have", "p.broken", "p.a", "p.b", "p.c"].map(counter.count), [0, 0, 1, 1, 1])
        XCTAssertEqual(running.maximum, 1)
        let warmed = await cache.cached("p.c")
        XCTAssertEqual(warmed, Data([7]))
    }
    /// A failed warm-up no longer silences that leave sound for the whole connection: it waits out the
    /// failure window and the next list fetches it again.
    func testAFailedWarmUpIsTriedAgainAfterTheWindow() async {
        let clock = Clock(), counter = Counter()
        let cache = PersonalSoundCache(prefetchGap: .zero, clock: { clock.now })
        let failing = PersonalSoundCache.Request("p.leave") { counter.hit("fail"); throw Failure() }
        await cache.prefetch([failing]); await cache.warmed()
        await cache.prefetch([failing]); await cache.warmed()
        XCTAssertEqual(counter.count("fail"), 1)
        clock.advance(61)
        await cache.prefetch([.init("p.leave") { counter.hit("ok"); return Data([3]) }]); await cache.warmed()
        let clip = await cache.cached("p.leave")
        XCTAssertEqual(counter.count("ok"), 1); XCTAssertEqual(clip, Data([3]))
    }
    func testWarmingStaysBesideTheReserveAndOutlivesOneOffClips() async {
        XCTAssertEqual(PersonalSoundCache().prefetchLimit, 16)
        let counter = Counter()
        let wide = PersonalSoundCache(prefetchGap: .zero)
        await wide.prefetch((0..<20).map { index in .init("p.w\(index)") { counter.hit("w"); return Data([1]) } })
        await wide.warmed()
        XCTAssertEqual(counter.count("w"), 16)
        // Capacity 10 warms at most 2; the warm set, marked recent again, survives a run of other clips.
        let cache = PersonalSoundCache(capacity: 10, prefetchGap: .zero)
        let warm = ["p.w1", "p.w2", "p.w3"].map { id in PersonalSoundCache.Request(id) { counter.hit(id); return Data([2]) } }
        await cache.prefetch(warm); await cache.warmed()
        XCTAssertEqual(counter.count("p.w3"), 0)
        for index in 1...8 { _ = await cache.clip("p.o\(index)") { Data([3]) } }
        await cache.prefetch(warm); await cache.warmed()
        _ = await cache.clip("p.o9") { Data([3]) }
        let w1 = await cache.cached("p.w1"), w2 = await cache.cached("p.w2"), o1 = await cache.cached("p.o1"), o9 = await cache.cached("p.o9")
        XCTAssertNotNil(w1); XCTAssertNotNil(w2); XCTAssertNil(o1); XCTAssertNotNil(o9)
        XCTAssertEqual(counter.count("p.w1"), 1); XCTAssertEqual(counter.count("p.w2"), 1)
    }
    func testANewerListReplacesTheQueueAndClearStopsWarming() async {
        let counter = Counter()
        let cache = PersonalSoundCache(prefetchGap: .zero)
        func request(_ id: String, delay: Int = 0) -> PersonalSoundCache.Request {
            .init(id) { counter.hit(id); try await Task.sleep(for: .milliseconds(delay)); return Data([1]) }
        }
        await cache.prefetch([request("p.a", delay: 60), request("p.b")])
        try? await Task.sleep(for: .milliseconds(20))
        await cache.prefetch([request("p.x")])
        await cache.warmed()
        XCTAssertEqual(["p.a", "p.b", "p.x"].map(counter.count), [1, 0, 1])
        let paced = PersonalSoundCache(prefetchGap: .milliseconds(40))
        await paced.prefetch([request("p.late")])
        await paced.clear()
        try? await Task.sleep(for: .milliseconds(80))
        let late = await paced.cached("p.late")
        XCTAssertEqual(counter.count("p.late"), 0); XCTAssertNil(late)
    }
}

final class PersonalSoundRuntimeRuleTests: XCTestCase {
    func testWarmsOneLeaveSoundPerDistinctSoundInJoinOrderWithinTheLimit() {
        let roster: [(actor: String, sounds: ParticipantSounds)] = [
            ("z", .init(leave: "p.z")), ("b", .init(enter: "p.in", leave: "p.shared")), ("d", .init(leave: "p.shared")),
            ("c", .init(enter: "p.only-enter")), ("rooms-music-1", .init(leave: "p.dj")), ("e", .init(leave: "p.e")),
            ("a", .init(leave: "p.a")), ("f", .init(leave: "p.f")),
        ]
        let plan = PersonalSoundPrefetch.plan(roster, limit: 3) { $0 != "e" }
        XCTAssertEqual(plan, [.init(actor: "z", sound: "p.z"), .init(actor: "b", sound: "p.shared"), .init(actor: "a", sound: "p.a")])
        // A newcomer joins at the end and never displaces the clips of the people already there.
        XCTAssertEqual(PersonalSoundPrefetch.plan(roster + [("0", .init(leave: "p.new"))], limit: 3) { $0 != "e" }, plan)
        XCTAssertEqual(PersonalSoundPrefetch.plan(roster, limit: 16) { _ in true }.count, 5)
        XCTAssertEqual(PersonalSoundPrefetch.plan(roster, limit: 0) { _ in true }, [])
        XCTAssertEqual(PersonalSoundPrefetch.plan(roster, limit: 10) { _ in false }, [])
    }
    func testClassicStandInsShareThePolicysCoalescingWindow() {
        var gate = ClassicCueGate()
        XCTAssertEqual(gate.windowMs, PersonalSoundPolicy.standard.classicCoalesceMs)
        XCTAssertTrue(gate.admit(now: 1_000))
        XCTAssertFalse(gate.admit(now: 1_399))
        // A refused cue does not extend the window.
        XCTAssertTrue(gate.admit(now: 1_400))
        XCTAssertFalse(gate.admit(now: 1_500))
        gate.reset()
        XCTAssertTrue(gate.admit(now: 1_500))
    }
}

private final class SoundResponses: @unchecked Sendable {
    static let shared = SoundResponses()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest, Data) -> (Int, Data) = { _, _ in (503, Data()) }
    func set(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, Data)) { lock.lock(); self.handler = handler; lock.unlock() }
    func reply(_ request: URLRequest, body: Data) -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return handler(request, body) }
}
private final class SoundStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
        } ?? Data()
        let (status, data) = SoundResponses.shared.reply(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class Requests: @unchecked Sendable {
    private let lock = NSLock(); private var values: [(String, String, String, Data)] = []
    func add(_ request: URLRequest, _ body: Data) { lock.lock(); values.append((request.httpMethod ?? "", request.url?.path ?? "", request.value(forHTTPHeaderField: "Authorization") ?? "", body)); lock.unlock() }
    var all: [(String, String, String, Data)] { lock.lock(); defer { lock.unlock() }; return values }
}

final class PersonalSoundAPITests: XCTestCase {
    private let profile = #"{"assign":{"enter":null,"leave":"p.kapanis"},"sounds":[],"presets":[{"id":"p.kapanis","name":"Kapanış","durationSec":1}],"uploads":false}"#
    private func api() throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SoundStub.self]
        return APIClient(origin: try EndpointPolicy.origin("https://rooms.test"), token: "test-session", session: URLSession(configuration: config))
    }
    private func wav(_ samples: Int) -> Data { RoomCueTone.wav(samples: [Int16](repeating: 0, count: samples)) }

    func testRoutesMethodsAndBearerToken() async throws {
        let seen = Requests(), profile = profile, clip = wav(100)
        SoundResponses.shared.set { request, body in
            seen.add(request, body)
            return request.url!.path.hasSuffix("/me") || request.httpMethod != "GET" ? (200, Data(profile.utf8)) : (200, clip)
        }
        let api = try api(), upload = "3f2b8c1e-5d6a-4b7c-9e0f-112233445566"
        let loaded = try await api.personalSoundProfile()
        XCTAssertEqual(loaded.assign.leave, "p.kapanis"); XCTAssertFalse(loaded.uploads)
        _ = try await api.assignPersonalSounds(PersonalSoundAssign(enter: "p.fanfar"))
        _ = try await api.removePersonalSound(upload)
        let preview = try await api.personalSoundPreview("p.fanfar")
        let played = try await api.personalSoundClip(channel: "01CHANNEL", user: "01USER", sound: upload)
        XCTAssertEqual(preview, clip); XCTAssertEqual(played, clip)
        let requests = seen.all
        XCTAssertEqual(requests.map { "\($0.0) \($0.1)" }, [
            "GET /rooms-access/v1/personal-sounds/me",
            "PUT /rooms-access/v1/personal-sounds/me/assign",
            "DELETE /rooms-access/v1/personal-sounds/me/sounds/\(upload)",
            "GET /rooms-access/v1/personal-sounds/me/sounds/p.fanfar",
            "GET /rooms-access/v1/personal-sounds/01CHANNEL/01USER/\(upload)",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.2 == "Bearer test-session" })
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: requests[1].3), .object(["enter": .string("p.fanfar"), "leave": .null]))
    }
    func testInvalidIDsNeverReachTheNetwork() async throws {
        let seen = Requests()
        SoundResponses.shared.set { request, body in seen.add(request, body); return (200, Data()) }
        let api = try api()
        await XCTAssertThrowsAsync { _ = try await api.personalSoundPreview("../me") }
        await XCTAssertThrowsAsync { _ = try await api.removePersonalSound("p.fanfar") }
        await XCTAssertThrowsAsync { _ = try await api.personalSoundClip(channel: "a/b", user: "u", sound: "p.fanfar") }
        await XCTAssertThrowsAsync { _ = try await api.assignPersonalSounds(PersonalSoundAssign(enter: "x y")) }
        XCTAssertTrue(seen.all.isEmpty)
    }
    func testErrorCodesAndAServerWithoutTheFeature() async throws {
        let api = try api()
        let cases: [(Int, String, String)] = [
            (501, #"{"error":"PERSONAL_SOUNDS_NOT_CONFIGURED"}"#, "PERSONAL_SOUNDS_NOT_CONFIGURED"),
            (404, #"{"error":"PERSONAL_SOUND_NOT_FOUND"}"#, "PERSONAL_SOUND_NOT_FOUND"),
            (404, #"{"message":"Route GET:/v1/personal-sounds/me not found","error":"Not Found","statusCode":404}"#, "PERSONAL_SOUNDS_MISSING"),
            (503, #"{"error":"SERVICE_UNAVAILABLE"}"#, "PERSONAL_SOUNDS_UNAVAILABLE"),
        ]
        for (status, body, code) in cases {
            SoundResponses.shared.set { _, _ in (status, Data(body.utf8)) }
            do { _ = try await api.personalSoundProfile(); XCTFail("expected \(code)") }
            catch let error as PersonalSoundError { XCTAssertEqual(error.code, code) }
        }
        SoundResponses.shared.set { _, _ in (401, Data()) }
        do { _ = try await api.personalSoundProfile(); XCTFail("expected expiry") } catch { XCTAssertEqual(error as? RoomsError, .expired) }
    }
    func testClipsAreCappedAndMustBeWav() async throws {
        let api = try api()
        let largest = wav((PersonalSoundLimits.maxClipBytes - 44) / 2)
        XCTAssertEqual(largest.count, PersonalSoundLimits.maxClipBytes)
        SoundResponses.shared.set { _, _ in (200, largest) }
        let accepted = try await api.personalSoundPreview("p.fanfar")
        XCTAssertEqual(accepted.count, PersonalSoundLimits.maxClipBytes)
        SoundResponses.shared.set { _, _ in (200, largest + Data([0, 0])) }
        do { _ = try await api.personalSoundPreview("p.fanfar"); XCTFail("expected size limit") }
        catch let error as PersonalSoundError { XCTAssertEqual(error.code, "PERSONAL_SOUND_TOO_LARGE") }
        SoundResponses.shared.set { _, _ in (200, Data(repeating: 7, count: 400)) }
        do { _ = try await api.personalSoundPreview("p.fanfar"); XCTFail("expected WAV check") }
        catch let error as PersonalSoundError { XCTAssertEqual(error.code, "PERSONAL_SOUND_INVALID_AUDIO") }
    }
}

private func XCTAssertThrowsAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("expected an error", file: file, line: line) } catch {}
}
