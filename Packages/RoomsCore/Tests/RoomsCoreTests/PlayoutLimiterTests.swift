import XCTest
@testable import RoomsCore

final class PlayoutLimiterTests: XCTestCase {
    private func run(_ limiter: inout PlayoutLimiter, _ samples: inout [Float], gain: Float) {
        samples.withUnsafeMutableBufferPointer { pointer in
            let base = pointer.baseAddress!
            limiter.process(channels: 1, frames: pointer.count, gain: gain) { _ in base }
        }
    }
    private func speech(amplitude: Float) -> [Float] {
        (0..<480).map { amplitude * sin(Float($0) * 0.2) }
    }

    func testLeavesOrdinarySpeechUntouched() {
        var limiter = PlayoutLimiter()
        var samples = speech(amplitude: 8000)
        let original = samples
        run(&limiter, &samples, gain: 1)
        XCTAssertEqual(samples, original)
    }

    func testBoostedAudioNeverPassesTheCeiling() {
        var limiter = PlayoutLimiter()
        let limit = PlayoutLimiter.ceiling * 32767
        for _ in 0..<20 {
            var samples = speech(amplitude: 30000)
            run(&limiter, &samples, gain: 4)
            XCTAssertLessThanOrEqual(samples.map(abs).max()!, limit)
        }
        var silent = speech(amplitude: 30000)
        run(&limiter, &silent, gain: 0)
        XCTAssertEqual(silent.map(abs).max(), 0)
    }

    func testBoostMakesQuietSpeechLouderAndRecoversGradually() {
        var limiter = PlayoutLimiter()
        var quiet = speech(amplitude: 2000)
        run(&limiter, &quiet, gain: 4)
        XCTAssertEqual(quiet.map(abs).max()!, 8000, accuracy: 5)
        var loud = speech(amplitude: 30000)
        run(&limiter, &loud, gain: 4)
        var after = speech(amplitude: 2000)
        run(&limiter, &after, gain: 4)
        XCTAssertLessThan(after.map(abs).max()!, 7000)
        XCTAssertNotEqual(after.map(abs).max()!, 0)
    }

    func testSharedLoudnessReportsPlayoutActivity() {
        let loudness = PlayoutLoudness()
        XCTAssertFalse(loudness.isActive(now: 10))
        var samples = speech(amplitude: 1000)
        loudness.setGain(2)
        samples.withUnsafeMutableBufferPointer { pointer in
            let base = pointer.baseAddress!
            loudness.process(channels: 1, frames: pointer.count, now: 1_000) { _ in base }
        }
        XCTAssertTrue(loudness.isActive(now: 1_000_000))
        XCTAssertFalse(loudness.isActive(now: 3_000_000_000))
        XCTAssertEqual(samples.map(abs).max()!, 2000, accuracy: 3)
        loudness.setGain(.nan); XCTAssertEqual(loudness.gain, 1)
        loudness.setGain(99); XCTAssertEqual(loudness.gain, 6)
    }
}
