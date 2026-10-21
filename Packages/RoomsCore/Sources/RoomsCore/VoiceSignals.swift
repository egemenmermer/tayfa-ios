import Foundation

/// A moderator moved this person to another voice room (`rooms-move-v1`, desktop `onMove`).
/// Only the server sends it (no sending participant); the client then joins the target
/// through the normal grant check, so the packet itself grants nothing.
public enum MoveSignal {
    public static let topic = "rooms-move-v1"
    public struct Move: Equatable, Sendable {
        public let channelID: String
        /// The moderator's user id, when the packet names a valid one.
        public let by: String?
    }
    public static func parse(_ data: Data) -> Move? {
        guard data.count <= 512, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = object["channelId"] as? String, valid(channel) else { return nil }
        return Move(channelID: channel, by: (object["by"] as? String).flatMap { valid($0) ? $0 : nil })
    }
    static func valid(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }
}

/// Who watches a screen share, from each viewer's own `rooms-watch-v1` announcement (desktop `viewerSummary`).
public enum ScreenViewers {
    /// `names` are the viewers' display names, with "Sen" for this listener.
    public static func summary(_ names: [String], named: Bool = false) -> String {
        if names.isEmpty { return "Henüz izleyen yok" }
        return named ? "İzleyenler: " + names.joined(separator: ", ") : "\(names.count) kişi izliyor"
    }
}
