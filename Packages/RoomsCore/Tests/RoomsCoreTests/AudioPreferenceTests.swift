import XCTest
@testable import RoomsCore

final class AudioPreferenceTests: XCTestCase {
    func testRoomMuteDoesNotErasePersonalVolumeOrMute() {
        var prefs = AudioPreferences()
        prefs.setParticipant("a", volume: 0.2)
        XCTAssertEqual(prefs.participant("a").playbackVolume(roomMuted: true), 0)
        XCTAssertEqual(prefs.participant("a").playbackVolume(roomMuted: false), 0.2)
        prefs.setParticipant("a", muted: true)
        prefs.setParticipant("a", volume: 0.6)
        XCTAssertEqual(prefs.participant("a").playbackVolume(roomMuted: false), 0)
        prefs.setParticipant("a", muted: false)
        XCTAssertEqual(prefs.participant("a").playbackVolume(roomMuted: false), 0.6)
        XCTAssertEqual(prefs.participant("b").playbackVolume(roomMuted: false), 1)
    }
    func testBoundsAndReset() {
        var prefs = AudioPreferences()
        prefs.setParticipant("a", volume: -1); XCTAssertEqual(prefs.participant("a").volume, 0)
        prefs.setParticipant("a", volume: 9); XCTAssertEqual(prefs.participant("a").volume, 2)
        prefs.setParticipant("a", volume: 0.3)
        prefs.setParticipant("a", volume: .nan); XCTAssertEqual(prefs.participant("a").volume, 0.3)
        prefs.setParticipant("a", muted: true)
        prefs.resetParticipant("a"); XCTAssertEqual(prefs.participant("a"), .init())
    }
    @MainActor func testPersistenceSurvivesNewStoreAndIsolatesAccountsAndServers() throws {
        let suite = "rooms-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let origin = try XCTUnwrap(URL(string: "https://rooms.test"))
        var prefs = AudioPreferences(); prefs.noiseSuppression = false
        prefs.setParticipant("peer", volume: 0.25, muted: true)
        AudioPreferenceStore(defaults: defaults).save(prefs, origin: origin, userID: "owner")
        let restored = AudioPreferenceStore(defaults: defaults)
        XCTAssertEqual(restored.load(origin: origin, userID: "owner"), prefs)
        XCTAssertEqual(restored.load(origin: origin, userID: "other"), AudioPreferences())
        XCTAssertEqual(restored.load(origin: URL(string: "https://other.test")!, userID: "owner"), AudioPreferences())
    }
    func testRoomLevelIsAPercentOnADecibelCurve() {
        var prefs = AudioPreferences()
        XCTAssertEqual(prefs.roomLevel, 0.8)
        XCTAssertEqual(RoomLoudness.gain(forLevel: 0), 0)
        XCTAssertEqual(RoomLoudness.gain(forLevel: 2.0 / 3.0), 1, accuracy: 0.001)
        XCTAssertEqual(RoomLoudness.gain(forLevel: 1), 3.98, accuracy: 0.01)
        XCTAssertGreaterThan(RoomLoudness.gain(forLevel: 0.5), RoomLoudness.gain(forLevel: 0.25))
        prefs.setParticipant("a", volume: 2)
        prefs.setRoomLevel(1)
        XCTAssertEqual(prefs.playbackVolume(for: "a", roomMuted: false), 6)
        XCTAssertEqual(prefs.playbackVolume(for: "a", roomMuted: false, boostRoom: false), 2)
        XCTAssertEqual(prefs.playbackVolume(for: "a", roomMuted: true), 0)
        prefs.setRoomLevel(0); XCTAssertEqual(prefs.playbackVolume(for: "a", roomMuted: false), 0)
        prefs.setRoomLevel(-3); XCTAssertEqual(prefs.roomLevel, 0)
        prefs.setRoomLevel(.nan); XCTAssertEqual(prefs.roomLevel, 0)
    }
    func testPreferencesSavedBeforeRoomVolumeStillLoad() throws {
        let legacy = Data(#"{"noiseSuppression":false,"participants":{"peer":{"volume":0.4,"muted":false}}}"#.utf8)
        let prefs = try JSONDecoder().decode(AudioPreferences.self, from: legacy)
        XCTAssertFalse(prefs.noiseSuppression)
        XCTAssertEqual(prefs.roomLevel, RoomLoudness.defaultLevel)
        XCTAssertEqual(prefs.participant("peer").volume, 0.4)
    }
    func testFormerRoomMultiplierKeepsItsLoudness() throws {
        for gain in [0.5, 1.5, 3.0] {
            let saved = Data(#"{"roomVolume":\#(gain)}"#.utf8)
            let prefs = try JSONDecoder().decode(AudioPreferences.self, from: saved)
            XCTAssertEqual(prefs.roomGain, gain, accuracy: 0.001)
        }
        var prefs = AudioPreferences(); prefs.setRoomLevel(0.3)
        let restored = try JSONDecoder().decode(AudioPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored, prefs)
    }
}
