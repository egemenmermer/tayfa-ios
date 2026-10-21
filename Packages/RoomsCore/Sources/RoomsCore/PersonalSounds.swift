import Foundation

// MARK: Personal entrance and leave sounds ("Giriş sesi"; desktop `shared-contracts/src/personal-sounds.ts`)
//
// The access service stamps the sound a person chose onto their LiveKit token as server-owned
// participant attributes. Listeners read the attribute of the participant that joined or left and
// play that sound locally; nothing travels through the microphone or a data channel.

/// LiveKit participant attributes set by the access service; absent means the classic cue.
public enum PersonalSoundAttribute {
    public static let enter = "rooms.sound.enter"
    public static let leave = "rooms.sound.leave"
    public static func key(_ event: RoomCue) -> String { event == .enter ? enter : leave }
}

public enum PersonalSoundLimits {
    public static let sampleRate = 48_000
    /// Longest stored clip after trimming, plus the server's tolerance for encoder rounding.
    public static let maxDurationSec = 4.0
    public static let acceptDurationSec = 4.05
    public static let maxSounds = 6
    public static let maxPresets = 32
    /// Canonical mono PCM16 WAV at `acceptDurationSec`: 44 + ceil(4.05 × 48000) × 2.
    public static let maxClipBytes = 388_844
    public static let maxNameLength = 40
}

/// Listener-side anti-spam policy; the numbers mirror desktop `PERSONAL_SOUND_POLICY` exactly.
public struct PersonalSoundPolicy: Equatable, Sendable {
    /// A departure waits this long; the same person returning inside it silences both events.
    public var leaveHoldMs: Double = 1_500
    /// Returning within this window after leaving plays the classic cue instead of the personal one.
    public var rejoinClassicMs: Double = 30_000
    /// Leaving within this window after joining plays the classic cue.
    public var shortStayClassicMs: Double = 10_000
    /// At most one personal sound per person and event in this window.
    public var perPersonCooldownMs: Double = 120_000
    /// At most one personal sound per listener in this window; longer than the longest clip.
    public var roomWindowMs: Double = 5_000
    /// Classic cues closer together than this collapse into one.
    public var classicCoalesceMs: Double = 400
    /// A personal sound that is not ready this long after the event is dropped for the classic cue.
    public var readyDeadlineMs: Double = 1_500
    /// Playback gain before the listener's effects level.
    public var personalGain = 0.45
    public var classicGain = 0.55
    public init() {}
    public static let standard = PersonalSoundPolicy()
}

/// Sound ids: uploads are UUIDs (zod 4 `uuid()`), presets `p.<name>`. Clients accept any
/// well-formed preset id, so new server presets need no client update.
public enum PersonalSoundID {
    public static func isValid(_ value: String) -> Bool { isUpload(value) || isPreset(value) }
    /// `^p\.[a-z0-9-]{1,32}$`
    public static func isPreset(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 3, bytes.count <= 34, bytes[0] == UInt8(ascii: "p"), bytes[1] == UInt8(ascii: ".") else { return false }
        return bytes.dropFirst(2).allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
    }
    /// RFC 9562 versions 1–8 with the RFC variant, or the nil and max UUIDs (zod 4 `z.string().uuid()`).
    public static func isUpload(_ value: String) -> Bool {
        if value == "00000000-0000-0000-0000-000000000000" || value == "ffffffff-ffff-ffff-ffff-ffffffffffff" { return true }
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        func hex(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) || (0x41...0x46).contains(byte) }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) { guard byte == UInt8(ascii: "-") else { return false } }
            else { guard hex(byte) else { return false } }
        }
        return (0x31...0x38).contains(bytes[14]) && Array("89abAB".utf8).contains(bytes[19])
    }
}

/// A participant's chosen sounds, read from their LiveKit attributes; malformed ids are dropped.
public struct ParticipantSounds: Equatable, Sendable {
    public var enter: String?
    public var leave: String?
    public init(enter: String? = nil, leave: String? = nil) {
        self.enter = enter.flatMap { PersonalSoundID.isValid($0) ? $0 : nil }
        self.leave = leave.flatMap { PersonalSoundID.isValid($0) ? $0 : nil }
    }
    public init(attributes: [String: String]) {
        self.init(enter: attributes[PersonalSoundAttribute.enter], leave: attributes[PersonalSoundAttribute.leave])
    }
    public subscript(event: RoomCue) -> String? { event == .enter ? enter : leave }
    public var isEmpty: Bool { enter == nil && leave == nil }
}

/// One sound in a profile: an own upload (`sounds`) or a server preset (`presets`).
public struct PersonalSoundItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let durationSec: Double
    public init(id: String, name: String, durationSec: Double) { self.id = id; self.name = name; self.durationSec = durationSec }
    /// zod `.max()` counts UTF-16 code units, as here.
    func valid(preset: Bool) -> Bool {
        (preset ? PersonalSoundID.isPreset(id) : PersonalSoundID.isUpload(id))
            && !name.isEmpty && name.utf16.count <= PersonalSoundLimits.maxNameLength
            && durationSec.isFinite && durationSec > 0 && durationSec <= PersonalSoundLimits.acceptDurationSec
    }
}

/// The chosen sounds; `nil` means the classic ROOMS cue. Both keys are always sent, `null` included.
public struct PersonalSoundAssign: Codable, Equatable, Sendable {
    public var enter: String?
    public var leave: String?
    public init(enter: String? = nil, leave: String? = nil) { self.enter = enter; self.leave = leave }
    public subscript(event: RoomCue) -> String? {
        get { event == .enter ? enter : leave }
        set { if event == .enter { enter = newValue } else { leave = newValue } }
    }
    public var valid: Bool { [enter, leave].allSatisfy { $0.map(PersonalSoundID.isValid) ?? true } }
    private enum CodingKeys: String, CodingKey { case enter, leave }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enter = try container.decodeIfPresent(String.self, forKey: .enter)
        leave = try container.decodeIfPresent(String.self, forKey: .leave)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let enter { try container.encode(enter, forKey: .enter) } else { try container.encodeNil(forKey: .enter) }
        if let leave { try container.encode(leave, forKey: .leave) } else { try container.encodeNil(forKey: .leave) }
    }
    var json: JSONValue { .object(["enter": enter.map(JSONValue.string) ?? .null, "leave": leave.map(JSONValue.string) ?? .null]) }
}

/// `GET /v1/personal-sounds/me`: the person's choice, own uploads and the server presets.
public struct PersonalSoundProfile: Codable, Equatable, Sendable {
    public var assign: PersonalSoundAssign
    public var sounds: [PersonalSoundItem]
    public var presets: [PersonalSoundItem]
    /// False when the instance administrator turned uploads off.
    public var uploads: Bool
    public init(assign: PersonalSoundAssign = .init(), sounds: [PersonalSoundItem] = [], presets: [PersonalSoundItem] = [], uploads: Bool = true) {
        self.assign = assign; self.sounds = sounds; self.presets = presets; self.uploads = uploads
    }
    /// Decodes and checks the contract's limits, so a malformed reply never reaches the screen.
    public static func parse(_ data: Data) throws -> PersonalSoundProfile {
        guard let value = try? JSONDecoder().decode(PersonalSoundProfile.self, from: data),
              value.assign.valid, value.sounds.count <= PersonalSoundLimits.maxSounds,
              value.presets.count <= PersonalSoundLimits.maxPresets,
              value.sounds.allSatisfy({ $0.valid(preset: false) }), value.presets.allSatisfy({ $0.valid(preset: true) })
        else { throw PersonalSoundError(code: "PERSONAL_SOUNDS_INVALID") }
        return value
    }
    public func item(_ id: String?) -> PersonalSoundItem? {
        guard let id else { return nil }
        return sounds.first { $0.id == id } ?? presets.first { $0.id == id }
    }
}

/// A refused personal-sound request, with the desktop's Turkish text.
public struct PersonalSoundError: Error, LocalizedError, Equatable, Sendable {
    public static let codes: Set<String> = [
        "PERSONAL_SOUNDS_NOT_CONFIGURED", "PERSONAL_SOUND_UPLOADS_DISABLED", "PERSONAL_SOUND_INVALID_AUDIO",
        "PERSONAL_SOUND_SILENT", "PERSONAL_SOUND_LIBRARY_FULL", "PERSONAL_SOUND_STORAGE_LIMIT", "PERSONAL_SOUND_NOT_FOUND",
    ]
    public let code: String
    public init(code: String) { self.code = code }
    /// The server lacks the routes (older access service) or has the feature turned off.
    public var unsupported: Bool { code == "PERSONAL_SOUNDS_NOT_CONFIGURED" || code == "PERSONAL_SOUNDS_MISSING" }
    public var errorDescription: String? {
        switch code {
        case "PERSONAL_SOUNDS_NOT_CONFIGURED": "Bu sunucuda giriş sesleri henüz açılmadı."
        case "PERSONAL_SOUNDS_MISSING": "Bu sunucu giriş seslerini henüz desteklemiyor."
        case "PERSONAL_SOUND_UPLOADS_DISABLED": "Sunucu yöneticisi ses yüklemeyi kapattı. Tayfa seslerinden birini seçebilirsin."
        case "PERSONAL_SOUND_INVALID_AUDIO": "Ses dosyası okunamadı. En fazla 4 saniyelik bir kesit seç."
        case "PERSONAL_SOUND_SILENT": "Seçtiğin kesit neredeyse sessiz. Başka bir bölüm seç."
        case "PERSONAL_SOUND_LIBRARY_FULL": "En fazla \(PersonalSoundLimits.maxSounds) ses saklayabilirsin. Önce birini sil."
        case "PERSONAL_SOUND_STORAGE_LIMIT": "Sunucudaki ses alanı doldu. Yöneticiye haber ver."
        case "PERSONAL_SOUND_NOT_FOUND": "Bu ses artık yok."
        case "PERSONAL_SOUND_TOO_LARGE": "Ses dosyası çok büyük."
        default: "Giriş sesleri alınamadı. Yeniden dene."
        }
    }
}

/// Recent clips by sound id, so a room's sounds are fetched once. Failures are remembered for a
/// minute and concurrent requests for one clip share a single download. Cleared on account change.
/// Port of desktop `personal-sound-cache.ts`, including the background warm-up.
public actor PersonalSoundCache {
    /// One clip to warm up and how to download it.
    public struct Request: Sendable {
        public let id: String
        public let fetch: @Sendable () async throws -> Data
        public init(_ id: String, fetch: @escaping @Sendable () async throws -> Data) { self.id = id; self.fetch = fetch }
    }
    public nonisolated let capacity: Int
    public nonisolated let failureTTL: TimeInterval
    /// Pause before each background download, so warming a full room never bursts the Access service.
    public nonisolated let prefetchGap: Duration
    /// Entries warming never claims, so the clips being played do not evict the warm set or each other.
    public static let prefetchReserve = 8
    /// The most clips ``prefetch(_:)`` keeps warm (desktop `entries - prefetchReserve`).
    public nonisolated var prefetchLimit: Int { max(0, capacity - Self.prefetchReserve) }
    private let clock: @Sendable () -> TimeInterval
    private var entries: [String: Data] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var failures: [String: TimeInterval] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var queue: [Request] = []
    private var draining: Task<Void, Never>?
    private var generation = 0
    public init(capacity: Int = 24, failureTTL: TimeInterval = 60, prefetchGap: Duration = .milliseconds(300),
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(1, capacity); self.failureTTL = failureTTL; self.prefetchGap = prefetchGap; self.clock = clock
    }
    public func cached(_ id: String) -> Data? {
        guard let data = entries[id] else { return nil }
        touch(id); return data
    }
    /// The clip, from memory or `fetch`; nil while a recent attempt failed or after ``clear()``.
    /// `retry` (an explicit tap) tries again even inside the failure window.
    public func clip(_ id: String, retry: Bool = false, fetch: @escaping @Sendable () async throws -> Data) async -> Data? {
        if let data = cached(id) { return data }
        if let failed = failures[id] {
            if !retry, clock() - failed < failureTTL { return nil }
            failures[id] = nil
        }
        if let task = inFlight[id] { return await task.value }
        let ticket = generation
        let task = Task<Data?, Never> { try? await fetch() }
        inFlight[id] = task
        let data = await task.value
        guard generation == ticket else { return nil }
        if inFlight[id] == task { inFlight[id] = nil }
        if let data { store(id, data) } else { failures[id] = clock() }
        return data
    }
    /// Whether warming `id` would download now: not in memory, not downloading, no failure in the window.
    public func wants(_ id: String) -> Bool {
        guard entries[id] == nil, inFlight[id] == nil else { return false }
        guard let failed = failures[id] else { return true }
        return clock() - failed >= failureTTL
    }
    /// Background warm-up of the first ``prefetchLimit`` requests, one download at a time. Their clips
    /// already in memory become the most recent, so one-off clips are evicted first. The list replaces
    /// whatever is still queued; an empty list stops warming.
    public func prefetch(_ requests: [Request]) {
        let list = requests.prefix(prefetchLimit)
        for request in list where entries[request.id] != nil { touch(request.id) }
        queue = list.filter { wants($0.id) }
        guard draining == nil, !queue.isEmpty else { return }
        let ticket = generation
        draining = Task { await self.drain(ticket) }
    }
    private func drain(_ ticket: Int) async {
        while generation == ticket {
            if prefetchGap > .zero { try? await Task.sleep(for: prefetchGap) }
            guard generation == ticket, !queue.isEmpty else { break }
            let request = queue.removeFirst()
            if wants(request.id) { _ = await clip(request.id, fetch: request.fetch) }
        }
        if generation == ticket { draining = nil }
    }
    public func clear() {
        generation &+= 1
        for task in inFlight.values { task.cancel() }
        draining?.cancel(); draining = nil; queue = []
        inFlight = [:]; entries = [:]; order = []; failures = [:]
    }
    var count: Int { entries.count }
    /// Waits until background warming has nothing left to do (tests).
    func warmed() async { await draining?.value }
    private func store(_ id: String, _ data: Data) {
        entries[id] = data; touch(id)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }
    private func touch(_ id: String) { order.removeAll { $0 == id }; order.append(id) }
}

/// Which leave sounds of the people present to warm up: one request per distinct sound, at most
/// `limit` of them, picked in roster (join) order so the set stays put while the room does and a
/// newcomer never pushes out the clips of the people already there.
public enum PersonalSoundPrefetch {
    public struct Item: Equatable, Sendable {
        public let actor: String
        public let sound: String
        public init(actor: String, sound: String) { self.actor = actor; self.sound = sound }
    }
    public static func plan(_ roster: [(actor: String, sounds: ParticipantSounds)], limit: Int, allow: (String) -> Bool) -> [Item] {
        var items: [Item] = [], sounds = Set<String>(), actors = Set<String>()
        for (actor, chosen) in roster where items.count < limit {
            guard actors.insert(actor).inserted, !actor.hasPrefix("rooms-music-"), let sound = chosen.leave,
                  !sounds.contains(sound), allow(actor) else { continue }
            sounds.insert(sound); items.append(Item(actor: actor, sound: sound))
        }
        return items
    }
}

/// The runtime's classic-cue window: stand-ins for personal clips (late, failed, or another clip still
/// playing) and the classic cues the policy approved share one `classicCoalesceMs`, so a burst still
/// sounds once.
public struct ClassicCueGate: Sendable {
    public let windowMs: Double
    private var lastAt = -Double.infinity
    public init(windowMs: Double = PersonalSoundPolicy.standard.classicCoalesceMs) { self.windowMs = windowMs }
    /// Whether a classic cue may sound at `now` (milliseconds); an admitted one opens a new window.
    public mutating func admit(now: Double) -> Bool {
        guard now - lastAt >= windowMs else { return false }
        lastAt = now
        return true
    }
    public mutating func reset() { lastAt = -.infinity }
}
