import XCTest
@testable import RoomsCore

final class RoomCueTests: XCTestCase {
    private func update(_ tracker: inout RoomCueTracker, scope: String = "account", channel: String? = "room",
                        connected: Bool = true, others: [String] = ["friend"], sounds: [String: ParticipantSounds] = [:]) -> [RosterCue] {
        tracker.update(scope: scope, channel: channel, connected: connected,
                       others: Dictionary(uniqueKeysWithValues: others.map { ($0, sounds[$0] ?? ParticipantSounds()) }))
    }
    private let ownEnter = RosterCue(kind: .enter, actor: "", local: true)
    private let ownLeave = RosterCue(kind: .leave, actor: "", local: true)
    func testOneSelfJoinCueWithFullInitialRosterAndNoBurst() {
        var tracker = RoomCueTracker()
        XCTAssertEqual(update(&tracker, others: ["friend", "second", "third"]), [ownEnter])
        XCTAssertTrue(tracker.rebased)
        XCTAssertEqual(update(&tracker, others: ["friend", "second", "third"]), [])
        XCTAssertFalse(tracker.rebased)
    }
    func testHumanJoinAndLeaveCueOnceAndTheDJIsSilent() {
        var tracker = RoomCueTracker(); _ = update(&tracker)
        XCTAssertEqual(update(&tracker, others: ["friend", "new", "rooms-music-room"]), [RosterCue(kind: .enter, actor: "new")])
        XCTAssertEqual(update(&tracker, others: ["friend", "new"]), [])
        XCTAssertEqual(update(&tracker, others: ["friend"]), [RosterCue(kind: .leave, actor: "new")])
    }
    func testEveryJoinAndLeaveIsItsOwnCueWithThatPersonsSound() {
        var tracker = RoomCueTracker(); _ = update(&tracker)
        let sounds = ["a": ParticipantSounds(enter: "p.fanfar", leave: "p.kapanis"), "b": ParticipantSounds(enter: "p.kapi")]
        XCTAssertEqual(update(&tracker, others: ["friend", "a", "b"], sounds: sounds), [
            RosterCue(kind: .enter, actor: "a", sound: "p.fanfar"), RosterCue(kind: .enter, actor: "b", sound: "p.kapi"),
        ])
        // A departure carries the leave sound from the roster the person was last seen in.
        XCTAssertEqual(update(&tracker, others: ["b", "c"], sounds: sounds), [
            RosterCue(kind: .enter, actor: "c"),
            RosterCue(kind: .leave, actor: "a", sound: "p.kapanis"), RosterCue(kind: .leave, actor: "friend"),
        ])
    }
    func testAChangedAttributeIsNotACueButTheLatestLeaveSoundIsUsed() {
        var tracker = RoomCueTracker(); _ = update(&tracker)
        XCTAssertEqual(update(&tracker, others: ["friend"], sounds: ["friend": ParticipantSounds(leave: "p.kapanis")]), [])
        XCTAssertEqual(update(&tracker, others: []), [RosterCue(kind: .leave, actor: "friend", sound: "p.kapanis")])
    }
    func testReconnectRebasesTheRosterWithoutSounds() {
        var tracker = RoomCueTracker(); _ = update(&tracker)
        XCTAssertEqual(update(&tracker, connected: false, others: []), [])
        XCTAssertTrue(tracker.rebased)
        XCTAssertEqual(update(&tracker, others: []), [])
        XCTAssertTrue(tracker.rebased)
        XCTAssertEqual(update(&tracker, others: ["back"]), [RosterCue(kind: .enter, actor: "back")])
    }
    func testOwnLeaveCuesOnceAndAFailedJoinNeverCues() {
        var tracker = RoomCueTracker()
        XCTAssertEqual(update(&tracker, connected: false), [])
        XCTAssertEqual(update(&tracker, channel: nil, connected: false), [])
        _ = update(&tracker)
        XCTAssertEqual(update(&tracker, channel: nil, connected: false), [ownLeave])
        XCTAssertTrue(tracker.rebased)
        XCTAssertEqual(update(&tracker, channel: nil, connected: false), [])
    }
    func testAccountSwitchNeverComparesRosters() {
        var tracker = RoomCueTracker(); _ = update(&tracker)
        XCTAssertEqual(update(&tracker, scope: "other", channel: nil, connected: false, others: []), [])
        XCTAssertEqual(update(&tracker, scope: "other", others: ["someone"]), [ownEnter])
    }
    func testRoomSwitchIsAnOwnJoinNotTheOldRostersDepartures() {
        var tracker = RoomCueTracker(); _ = update(&tracker, others: ["friend", "other"])
        XCTAssertEqual(update(&tracker, channel: "second", others: ["stranger"]), [ownEnter])
        XCTAssertTrue(tracker.rebased)
    }
    func testToneIsAShortQuietTwoNoteWav() {
        let wav = RoomCueTone.wav(.enter)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.count, 44 + 5760 * 2)
        let peak = RoomCueTone.samples(.leave).map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 3000); XCTAssertLessThanOrEqual(peak, Int(0.13 * 32767) + 1)
        XCTAssertNotEqual(RoomCueTone.samples(.enter), RoomCueTone.samples(.leave))
    }
    func testSoundsPreferenceDefaultsOnAndSurvivesOlderSavedData() throws {
        XCTAssertTrue(AudioPreferences().roomEventSounds)
        let old = try JSONDecoder().decode(AudioPreferences.self, from: Data(#"{"noiseSuppression":false}"#.utf8))
        XCTAssertTrue(old.roomEventSounds)
        var off = AudioPreferences(); off.roomEventSounds = false
        let roundTrip = try JSONDecoder().decode(AudioPreferences.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(roundTrip.roomEventSounds)
    }
}
