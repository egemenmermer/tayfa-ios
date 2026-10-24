import XCTest
@testable import RoomsCore

/// Synthesized table cues (desktop `games/shared/sounds.ts` recipes), the 90 ms repeat gate and the "Oyun sesleri" preference.
final class GameCueTests: XCTestCase {
    func testEveryCueIsShortAudibleAndWithinFullScale() {
        for cue in GameCue.allCases {
            let samples = GameCueTone.samples(cue)
            XCTAssertEqual(samples.count, Int((Double(GameCueTone.sampleRate) * GameCueTone.seconds(cue)).rounded()), cue.rawValue)
            XCTAssertLessThanOrEqual(GameCueTone.seconds(cue), 0.7, "a table cue stays short: \(cue)")
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, 1000, "audible: \(cue)")
            XCTAssertLessThan(peak, 32767, "no clipping: \(cue)")
        }
    }
    func testCuesAreDeterministicAndDistinct() {
        XCTAssertEqual(GameCueTone.samples(.dice), GameCueTone.samples(.dice))
        XCTAssertNotEqual(GameCueTone.samples(.deal), GameCueTone.samples(.play))
        XCTAssertNotEqual(GameCueTone.samples(.win), GameCueTone.samples(.end))
    }
    func testWavHeaderIsMono16BitAtTheRoomRate() {
        let wav = GameCueTone.wav(.turn)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.count, 44 + GameCueTone.samples(.turn).count * 2)
        let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(rate), RoomCueTone.sampleRate)
    }
    func testSameCueWithin90MsCollapses() {
        var gate = GameCueGate()
        XCTAssertTrue(gate.admit(.play, now: 1000))
        XCTAssertFalse(gate.admit(.play, now: 1089), "a burst of bot moves plays once")
        XCTAssertTrue(gate.admit(.capture, now: 1050), "other cues are not held back")
        XCTAssertTrue(gate.admit(.play, now: 1090))
        gate.reset()
        XCTAssertTrue(gate.admit(.play, now: 1091))
    }
    func testGameSoundsPreferenceDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(AudioPreferences().gameSounds)
        XCTAssertTrue(try JSONDecoder().decode(AudioPreferences.self, from: Data(#"{"roomEventSounds":false}"#.utf8)).gameSounds,
                      "saved preferences from before the switch keep game sounds on")
        var prefs = AudioPreferences(); prefs.gameSounds = false
        XCTAssertFalse(try JSONDecoder().decode(AudioPreferences.self, from: JSONEncoder().encode(prefs)).gameSounds)
    }
}
