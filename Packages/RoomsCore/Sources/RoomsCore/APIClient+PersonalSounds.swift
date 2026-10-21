import Foundation

// MARK: Personal entrance and leave sounds (Access `/v1/personal-sounds/*`; desktop `electron/community.ts`)
// Uploads stay on desktop in V1; the phone reads the profile, assigns, deletes and plays clips.
extension APIClient {
    public func personalSoundProfile() async throws -> PersonalSoundProfile {
        try PersonalSoundProfile.parse(await personalSoundRequest("me"))
    }
    /// Sets both events at once; `nil` is the classic cue.
    public func assignPersonalSounds(_ value: PersonalSoundAssign) async throws -> PersonalSoundProfile {
        guard value.valid else { throw PersonalSoundError(code: "PERSONAL_SOUND_NOT_FOUND") }
        return try PersonalSoundProfile.parse(await personalSoundRequest("me/assign", method: "PUT", body: value.json))
    }
    public func removePersonalSound(_ soundID: String) async throws -> PersonalSoundProfile {
        guard PersonalSoundID.isUpload(soundID) else { throw PersonalSoundError(code: "PERSONAL_SOUND_NOT_FOUND") }
        return try PersonalSoundProfile.parse(await personalSoundRequest("me/sounds/\(soundID)", method: "DELETE"))
    }
    /// The account's own upload or a preset as canonical WAV, for settings previews.
    public func personalSoundPreview(_ soundID: String) async throws -> Data {
        guard PersonalSoundID.isValid(soundID) else { throw PersonalSoundError(code: "PERSONAL_SOUND_NOT_FOUND") }
        return try await personalSoundRequest("me/sounds/\(soundID)", audio: true)
    }
    /// Another participant's sound, authorized by the shared voice channel (Stoat channel id).
    public func personalSoundClip(channel: String, user: String, sound: String) async throws -> Data {
        guard PersonalSoundID.isValid(sound) else { throw PersonalSoundError(code: "PERSONAL_SOUND_NOT_FOUND") }
        return try await personalSoundRequest("\(try EndpointPolicy.id(channel))/\(try EndpointPolicy.id(user))/\(sound)", audio: true)
    }

    private func personalSoundRequest(_ path: String, method: String = "GET", body: JSONValue? = nil, audio: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard let url = URL(string: "/rooms-access/v1/personal-sounds/\(path)", relativeTo: origin)?.absoluteURL, url.host == origin.host else { throw RoomsError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body) }
        let limit = audio ? PersonalSoundLimits.maxClipBytes : 65_536
        let status: Int, data: Data
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw RoomsError.invalidResponse }
            status = http.statusCode
            // Error bodies are small JSON; only a successful clip may use the full clip budget.
            let cap = (200..<300).contains(status) ? limit : 8192
            guard http.expectedContentLength <= Int64(cap) else { throw PersonalSoundError(code: "PERSONAL_SOUND_TOO_LARGE") }
            var buffer = Data(); buffer.reserveCapacity(min(cap, max(0, Int(http.expectedContentLength))))
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > cap { throw PersonalSoundError(code: "PERSONAL_SOUND_TOO_LARGE") }
            }
            data = buffer
        } catch let error as PersonalSoundError { throw error }
        catch let error as RoomsError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw RoomsError.unavailable }
        try Task.checkCancellation()
        switch status {
        case 200..<300:
            if audio, !Self.isWav(data) { throw PersonalSoundError(code: "PERSONAL_SOUND_INVALID_AUDIO") }
            return data
        case 401: throw RoomsError.expired
        case 429: throw RoomsError.rateLimited
        default:
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"].string ?? ""
            if PersonalSoundError.codes.contains(code) { throw PersonalSoundError(code: code) }
            // An access service without these routes answers with the framework's own 404.
            if status == 404 { throw PersonalSoundError(code: "PERSONAL_SOUNDS_MISSING") }
            if status == 501 { throw PersonalSoundError(code: "PERSONAL_SOUNDS_NOT_CONFIGURED") }
            if status == 403 { throw RoomsError.denied }
            throw PersonalSoundError(code: "PERSONAL_SOUNDS_UNAVAILABLE")
        }
    }
    /// A RIFF/WAVE container; `AVAudioPlayer` validates the rest.
    static func isWav(_ data: Data) -> Bool {
        data.count > 44 && data.prefix(4) == Data("RIFF".utf8) && data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
    }
}
