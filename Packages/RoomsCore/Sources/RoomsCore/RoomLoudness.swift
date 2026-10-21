import Foundation
import os

/// The room slider is a 0–100 level heard on a decibel curve: 0 is silent, two thirds is the
/// unmodified level and 100 is +12 dB. ``PlayoutLimiter`` keeps the loud end clean.
public enum RoomLoudness {
    public static let range = 0.0...1.0
    public static let defaultLevel = 0.8
    static let floorDecibels = -24.0
    static let ceilingDecibels = 12.0

    public static func gain(forLevel level: Double) -> Double {
        let value = PlaybackGain.clamp(level, to: range, fallback: defaultLevel)
        guard value > 0.005 else { return 0 }
        return pow(10, (floorDecibels + (ceilingDecibels - floorDecibels) * value) / 20)
    }

    /// Level that plays a former room gain (the old 50–300 % multiplier) at the same loudness.
    public static func level(forGain gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return 0 }
        let decibels = 20 * log10(gain)
        return PlaybackGain.clamp((decibels - floorDecibels) / (ceilingDecibels - floorDecibels), to: range, fallback: defaultLevel)
    }
}

/// Keeps boosted room audio under the speaker's full scale. A peak follower lowers the gain at
/// once and recovers slowly; a soft knee rounds what remains above it instead of clipping.
public struct PlayoutLimiter: Sendable {
    /// About −1 dBFS.
    public static let ceiling: Float = 0.89
    /// LiveKit playout buffers carry Int16-scaled floats.
    public let fullScale: Float
    private let recovery: Float
    private(set) var reduction: Float = 1

    public init(fullScale: Float = 32767, recovery: Float = 0.05) {
        self.fullScale = fullScale
        self.recovery = recovery
    }

    public mutating func process(channels: Int, frames: Int, gain: Float, buffer: (Int) -> UnsafeMutablePointer<Float>) {
        guard channels > 0, frames > 0 else { return }
        let limit = Self.ceiling * fullScale, knee = limit * 0.8
        var peak: Float = 0
        for index in 0..<channels {
            let samples = buffer(index)
            for frame in 0..<frames where samples[frame].isFinite { peak = max(peak, abs(samples[frame] * gain)) }
        }
        let target = peak > limit ? limit / peak : 1
        let next = target < reduction ? target : min(target, reduction + (1 - reduction) * recovery)
        let start = reduction
        for index in 0..<channels {
            let samples = buffer(index)
            for frame in 0..<frames {
                guard samples[frame].isFinite else { samples[frame] = 0; continue }
                let ramp = start + (next - start) * Float(frame + 1) / Float(frames)
                samples[frame] = Self.soften(samples[frame] * gain * ramp, knee: knee, limit: limit)
            }
        }
        reduction = next
    }

    static func soften(_ value: Float, knee: Float, limit: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > knee else { return value }
        let rounded = knee + (limit - knee) * tanh((magnitude - knee) / (limit - knee))
        return value < 0 ? -rounded : rounded
    }
}

/// Room gain plus limiter, shared by the settings (main actor) and the playout thread.
public final class PlayoutLoudness: Sendable {
    private struct State: Sendable {
        var gain: Float = 1
        var limiter = PlayoutLimiter()
        var processedAt: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}

    public var gain: Double { Double(state.withLock { $0.gain }) }
    public func setGain(_ value: Double) {
        let gain = Float(value.isFinite ? min(max(value, 0), PlaybackGain.maximum) : 1)
        state.withLock { $0.gain = gain }
    }

    public func process(channels: Int, frames: Int, now: UInt64 = DispatchTime.now().uptimeNanoseconds,
                        buffer: (Int) -> UnsafeMutablePointer<Float>) {
        state.withLockUnchecked { current in
            current.limiter.process(channels: channels, frames: frames, gain: current.gain, buffer: buffer)
            current.processedAt = now
        }
    }

    /// True while playout passes through here, so the room gain can safely move from the tracks.
    public func isActive(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        let last = state.withLock { $0.processedAt }
        return last > 0 && now >= last && now - last < 2_000_000_000
    }

    /// A new playout configuration starts unlimited; the chosen gain is kept.
    public func resetLimiter() { state.withLock { $0.limiter = PlayoutLimiter(); $0.processedAt = 0 } }
}
