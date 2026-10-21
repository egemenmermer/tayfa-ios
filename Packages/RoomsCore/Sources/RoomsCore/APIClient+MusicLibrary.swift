import Foundation

// MARK: DJ history and shared playlists (Access `/v1/music/:channel/history|playlists`)
extension APIClient {
    public func musicHistory(channel: String) async throws -> [MusicHistorySession] {
        let data = try await musicRequest(channel: channel, suffix: "/history", body: nil, timeout: 15)
        guard let sessions = try? JSONDecoder().decode([MusicHistorySession].self, from: data), sessions.count <= 30 else { throw RoomsError.invalidResponse }
        return sessions
    }
    /// The community's playlists, shared by every room of it.
    public func musicPlaylists(channel: String) async throws -> [SharedPlaylist] {
        try playlists(await musicRequest(channel: channel, suffix: "/playlists", body: nil, timeout: 20))
    }
    /// Applies one change and returns the updated catalog. Imports can take a while (desktop waits 70 s).
    public func changeMusicPlaylist(channel: String, _ change: PlaylistChange) async throws -> [SharedPlaylist] {
        try playlists(await musicRequest(channel: channel, suffix: "/playlists", body: change.json, timeout: 70))
    }
    private func playlists(_ data: Data) throws -> [SharedPlaylist] {
        guard let lists = try? JSONDecoder().decode([SharedPlaylist].self, from: data), lists.count <= 50 else { throw RoomsError.invalidResponse }
        return lists
    }
}
