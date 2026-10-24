import Foundation

/// Table sound cues, the names of the desktop's `games/shared/sounds.ts`. `play` is a card on the felt, `tile` a
/// stone/tile knock, `end` a round lost or drawn.
public enum GameCue: String, CaseIterable, Sendable { case deal, play, tile, capture, dice, turn, win, end }

/// Original synthesized PCM for the table cues: the desktop recipes, no bundled asset or network. Played as
/// 16-bit mono WAV through `AVAudioPlayer` like ``RoomCueTone``.
public enum GameCueTone {
    public static var sampleRate: Int { RoomCueTone.sampleRate }

    /// Desktop default cue gain (`playGameCue(cue, 0.8)`), multiplied by the listener's effects level.
    public static let gain = 0.8

    /// Length of one cue in seconds.
    public static func seconds(_ cue: GameCue) -> Double {
        switch cue {
        case .deal: 0.16
        case .play: 0.12
        case .tile: 0.08
        case .capture: 0.3
        case .dice: 0.26
        case .turn: 0.36
        case .win: 0.62
        case .end: 0.4
        }
    }

    public static func samples(_ cue: GameCue) -> [Int16] {
        var random = Noise(seed: Int64(cue.rawValue.count * 7919))
        let count = Int((Double(sampleRate) * seconds(cue)).rounded())
        return (0..<count).map { index in
            let value = sample(cue, Double(index) / Double(sampleRate), &random)
            return Int16((max(-1, min(1, value)) * 32767).rounded())
        }
    }

    public static func wav(_ cue: GameCue) -> Data { RoomCueTone.wav(samples: samples(cue)) }

    // MARK: Recipes (desktop `recipes`)

    private static func sample(_ cue: GameCue, _ t: Double, _ random: inout Noise) -> Double {
        switch cue {
        case .deal:
            // A card sliding off the deck: a short airy swish.
            return random.next() * pow(sin(Double.pi * t / 0.16), 2) * 0.22
        case .play:
            // A card slapped on the felt: a noise snap over a low thump.
            return random.next() * pluck(t, 0.018) * 0.32 + tone(140, t) * pluck(t, 0.03) * 0.25
        case .tile:
            // A tile or stone knocking on the board: a bright, very short click.
            return (tone(1900, t) * 0.5 + tone(2700, t) * 0.3 + random.next() * 0.2) * pluck(t, 0.012) * 0.4
        case .capture:
            // Cards swept to a player: a rising two-note figure under a swish.
            return notes(t, [520, 780], step: 0.09, length: 0.2, gain: 0.12) + random.next() * pluck(t, 0.05) * 0.08
        case .dice:
            // Dice rattling: three uneven knocks.
            return [0, 0.07, 0.16].enumerated().reduce(0) { sum, item in
                let (index, at) = item
                return sum + (random.next() * 0.6 + tone(900 + Double(index) * 260, t - at) * 0.4) * pluck(t - at, 0.014) * 0.36
            }
        case .turn:
            // Your turn: a soft two-note chime, close to the room's enter cue.
            return notes(t, [660, 880], step: 0.12, length: 0.24, gain: 0.14)
        case .win:
            // A won round: a short major arpeggio.
            return notes(t, [523, 659, 784, 1047], step: 0.1, length: 0.3, gain: 0.12)
        case .end:
            // A round that ended without the viewer winning: two falling notes.
            return notes(t, [587, 440], step: 0.14, length: 0.26, gain: 0.11)
        }
    }
    private static func tone(_ frequency: Double, _ t: Double) -> Double { sin(2 * Double.pi * frequency * t) }
    /// Fast attack, exponential decay.
    private static func pluck(_ t: Double, _ decay: Double) -> Double { t < 0 ? 0 : min(1, t / 0.004) * exp(-t / decay) }
    /// Notes that each ring for `length` seconds, starting `step` seconds apart.
    private static func notes(_ t: Double, _ frequencies: [Double], step: Double, length: Double, gain: Double) -> Double {
        frequencies.enumerated().reduce(0) { sum, item in
            let local = t - Double(item.offset) * step
            guard local >= 0, local <= length else { return sum }
            return sum + (tone(item.element, local) + 0.3 * tone(item.element * 2, local)) * pluck(local, length / 3) * gain
        }
    }
    /// A tiny deterministic noise source, so a cue sounds the same on every device and in tests.
    private struct Noise {
        var value: Int64
        init(seed: Int64) { value = seed }
        mutating func next() -> Double {
            value = (value &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
            return Double(value) / Double(0x3fff_ffff) - 1
        }
    }
}

/// Repeats of the same cue within 90 ms collapse into one (a burst of bot moves), as on desktop.
public struct GameCueGate: Sendable {
    public static let windowMs = 90.0
    private var lastPlayed: [GameCue: Double] = [:]
    public init() {}
    public mutating func admit(_ cue: GameCue, now: Double) -> Bool {
        if let last = lastPlayed[cue], now - last < Self.windowMs { return false }
        lastPlayed[cue] = now
        return true
    }
    public mutating func reset() { lastPlayed = [:] }
}
