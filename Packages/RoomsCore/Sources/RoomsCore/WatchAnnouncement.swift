import Foundation

/// Tells the room which screen share this listener watches, matching the desktop
/// `rooms-watch-v1` packet `{ "watching": identity | null }`. Receivers take the viewer
/// from the authenticated LiveKit sender, never from the payload.
public enum WatchAnnouncement {
    public static let topic = "rooms-watch-v1"

    public static func payload(watching: String?) -> Data {
        let value: Any = watching.map { $0 as Any } ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: ["watching": value])) ?? Data(#"{"watching":null}"#.utf8)
    }

    /// `.some(nil)` means "not watching"; `nil` means the packet is not a valid announcement.
    public static func parse(_ data: Data) -> String?? {
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["watching"] else { return nil }
        if value is NSNull { return .some(nil) }
        guard let id = value as? String, !id.isEmpty, id.count <= 128 else { return nil }
        return .some(id)
    }
}
