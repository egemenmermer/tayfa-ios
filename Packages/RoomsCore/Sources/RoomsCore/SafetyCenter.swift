import Foundation

/// Shared safety state for the chat views: who this account blocked and where it may moderate.
/// The app attaches a client factory once; nothing is cached across accounts.
@MainActor public final class SafetyCenter: ObservableObject {
    public static let shared = SafetyCenter()
    @Published public private(set) var blocked: Set<String> = []
    @Published public private(set) var moderatingChannels: Set<String> = []
    private var makeClient: (() -> APIClient?)?
    private var owner = ""
    private var loadingBlocked = false
    private var loaded = false
    private var moderationKeys: [String: UInt64] = [:]
    private var inflight: Set<String> = []
    public init() {}

    /// `makeClient` returns the current signed-in client, or nil while signed out.
    public func attach(_ makeClient: @escaping () -> APIClient?) { self.makeClient = makeClient }

    /// Forgets everything when the signed-in account changes. An empty id (unknown) changes nothing.
    public func use(userID: String) {
        guard !userID.isEmpty, userID != owner else { return }
        reset(owner: userID)
        Task { await refreshBlocked() }
    }
    private func reset(owner: String) {
        self.owner = owner; blocked = []; moderatingChannels = []; moderationKeys = [:]; inflight = []; loaded = false
    }
    public func isBlocked(_ userID: String) -> Bool { blocked.contains(userID) }

    /// Reads the block list once per account; a failure keeps what is known and a later call retries.
    public func refreshBlocked() async {
        guard !loadingBlocked, let api = makeClient?() else { return }
        loadingBlocked = true; defer { loadingBlocked = false }
        guard let state = try? await api.blockState() else { return }
        if state.userID != owner { reset(owner: state.userID) }
        blocked = state.blocked; loaded = true
    }
    /// Loads the block list the first time a screen needs it.
    public func ensureLoaded() async { if !loaded { await refreshBlocked() } }
    /// Blocks through Stoat, then hides the person locally; a failed call changes nothing and rethrows.
    public func block(_ id: String) async throws {
        guard let api = makeClient?() else { throw RoomsError.expired }
        try await api.block(id: id); blocked.insert(id)
    }
    public func unblock(_ id: String) async throws {
        guard let api = makeClient?() else { throw RoomsError.expired }
        try await api.unblock(id: id); blocked.remove(id)
    }
    public func reportMessage(_ id: String, reason: SafetyReportReason, context: String) async throws {
        guard let api = makeClient?() else { throw RoomsError.expired }
        try await api.reportMessage(id: id, reason: reason, context: context)
    }
    public func reportUser(_ id: String, reason: SafetyReportReason, context: String) async throws {
        guard let api = makeClient?() else { throw RoomsError.expired }
        try await api.reportUser(id: id, reason: reason, context: context)
    }

    public func canModerate(_ channelID: String) -> Bool { moderatingChannels.contains(channelID) }
    /// Looks up delete rights once per channel and permission generation; a failure grants nothing.
    public func refreshModeration(channelID: String, generation: UInt64) async {
        let user = owner
        guard !user.isEmpty, moderationKeys[channelID] != generation, !inflight.contains(channelID), let api = makeClient?() else { return }
        inflight.insert(channelID); defer { inflight.remove(channelID) }
        let allowed = (try? await api.canManageMessages(channelID: channelID, userID: user)) ?? false
        guard owner == user else { return }
        moderationKeys[channelID] = generation
        if allowed { moderatingChannels.insert(channelID) } else { moderatingChannels.remove(channelID) }
    }
}
