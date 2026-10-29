import Foundation

/// Polls posted into a text channel by the desktop (`apps/desktop/src/chat-poll.ts`, F07).
///
/// The poll lives in the activity room of the channel the message was posted in (room id = the message's channel id).
/// The message only carries a readable sentence and a 12-character id token at its very end:
/// `📊 Anket: <question> — Tayfa’nın yeni sürümünde oy ver. #Ab3dEf6hIj9k`.
/// Question, options and votes always come from the room snapshot, never from the message text.
public enum ChatPoll {
    public static let idLength = 12
    private static let mark = "📊 "

    /// The poll id a message refers to, or nil for every other message (quotes, edits with extra text, look-alikes).
    /// Same rule as desktop `chatPollId`: the whole trimmed content matches `^📊 [\s\S]+ #([A-Za-z0-9]{12})$`.
    public static func pollID(in content: String) -> String? {
        let scalars = Array(content.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        let prefix = Array(mark.unicodeScalars), tail = 2 + idLength   // " #" + id
        guard scalars.count >= prefix.count + 1 + tail, Array(scalars.prefix(prefix.count)) == prefix else { return nil }
        let end = scalars.count - tail
        guard scalars[end] == " ", scalars[end + 1] == "#" else { return nil }
        let id = scalars[(end + 2)...]
        guard id.allSatisfy(isAlphanumeric) else { return nil }
        var text = String.UnicodeScalarView(); text.append(contentsOf: id)
        return String(text)
    }

    /// The readable part of a poll message, shown while the poll itself cannot be loaded (desktop `chatPollFallback`).
    public static func fallback(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pollID(in: trimmed) != nil else { return trimmed }
        return String(String(trimmed.dropFirst(1)).dropLast(idLength + 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isValidID(_ id: String) -> Bool { id.unicodeScalars.count == idLength && id.unicodeScalars.allSatisfy(isAlphanumeric) }

    /// The `poll.vote` request body for the activity room of the message's channel. Nil when the id is malformed.
    public static func voteRequest(pollID: String, optionID: String, commandID: UUID, expectedRevision: Int) -> JSONValue? {
        guard isValidID(pollID), !optionID.isEmpty, optionID.utf8.count <= 64 else { return nil }
        return ActivityCommand.envelope(.pollVote(pollID: pollID, optionID: optionID), commandID: commandID, expectedRevision: expectedRevision)
    }
    /// The `poll.close` request body (creator or a participant who can control the room).
    public static func closeRequest(pollID: String, commandID: UUID, expectedRevision: Int) -> JSONValue? {
        guard isValidID(pollID) else { return nil }
        return ActivityCommand.envelope(.pollClose(pollID: pollID), commandID: commandID, expectedRevision: expectedRevision)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }
}

/// What the card shows for one poll, computed from the room snapshot.
public struct ChatPollSummary: Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String, label: String
        public let count: Int
        /// Rounded share of all voters; 0 while nobody voted.
        public let percent: Int
        public let mine: Bool
    }
    public let pollID: String
    public let question: String
    public let options: [Option]
    public let voters: Int
    public let myVote: String?
    public let closed: Bool
    public let canClose: Bool
    public let createdBy: String

    public init(_ poll: ActivityPoll, room: ActivityRoom, me: String?) {
        let voters = poll.votes.count, mine = me.flatMap { poll.votes[$0] }
        pollID = poll.id; question = poll.question; self.voters = voters; myVote = mine; closed = poll.closed; createdBy = poll.createdBy
        canClose = !poll.closed && room.closes(poll, me)
        options = poll.options.map { option in
            let count = poll.count(option.id)
            return Option(id: option.id, label: option.label, count: count, percent: voters == 0 ? 0 : Int((Double(count) / Double(voters) * 100).rounded()), mine: mine == option.id)
        }
    }
    /// Desktop `result`: the leading option(s) of a closed poll, or "Henüz oy yok".
    public var result: String {
        let top = options.map(\.count).max() ?? 0
        guard top > 0 else { return "Henüz oy yok" }
        return options.filter { $0.count == top }.map { "\($0.label) · \($0.count) oy" }.joined(separator: " / ")
    }
    public func canVote(_ optionID: String) -> Bool { !closed && options.contains { $0.id == optionID } }
}

/// The card's state: loading, the poll, not found, or a load error with the service's text.
public enum ChatPollPhase: Equatable, Sendable {
    case loading
    case live(ChatPollSummary)
    case notFound
    case failed(String)

    /// A snapshot of another room is never shown; a room without the id is "not found"; no room yet is loading or failed.
    public static func resolve(room: ActivityRoom?, channelID: String, pollID: String, me: String?, failure: String?) -> ChatPollPhase {
        guard let room, room.roomId == channelID else { return failure.map(ChatPollPhase.failed) ?? .loading }
        guard let poll = (room.polls ?? []).first(where: { $0.id == pollID }) else { return .notFound }
        return .live(ChatPollSummary(poll, room: room, me: me))
    }
}
