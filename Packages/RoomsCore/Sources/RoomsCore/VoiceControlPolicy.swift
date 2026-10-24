import Foundation

/// Which voice controls stay usable in which connection state, kept free of the LiveKit SDK so it can be tested.
public enum VoiceControlPolicy {
    /// Muting only needs a room object: it is a local action and must work while LiveKit is reconnecting, so a
    /// person on a bad network can still go quiet. Turning the microphone on needs a live connection.
    public static func canToggleMicrophone(muted: Bool, hasRoom: Bool, connected: Bool, busy: Bool, audioBlocked: Bool) -> Bool {
        guard hasRoom, !busy, !audioBlocked else { return false }
        return muted ? connected : true
    }
}

/// The deafen choice that follows a person from one voice room to the next (moderator move, room switch, rejoin),
/// the way the microphone choice does. A DM call always starts with sound: nobody is told they are deafened there.
public struct HearingCarry: Equatable, Sendable {
    public private(set) var deafened = false
    public init(deafened: Bool = false) { self.deafened = deafened }
    /// Called whenever the person (or a safety action such as a lost headset) changes the state.
    public mutating func record(_ deafened: Bool) { self.deafened = deafened }
    /// The state the next connection starts in. A voice room restores it; anything else clears it.
    public mutating func resolve(voiceRoom: Bool) -> Bool {
        if !voiceRoom { deafened = false }
        return deafened
    }
    /// Sign-out or account change.
    public mutating func reset() { deafened = false }
}

/// Where a screen share failed, for an honest message instead of always blaming the permission.
public enum ScreenShareStage: Sendable { case lease, publish }

public enum ScreenShareFailure {
    public static func message(stage: ScreenShareStage, error: Error) -> String {
        switch stage {
        case .lease:
            switch error as? RoomsError {
            case .denied?: return "Bu odada ekran paylaşma iznin yok. Odadaki yöneticiden izin iste."
            case .expired?: return "Oturum sona erdi. Yeniden giriş yapıp ekranı tekrar paylaş."
            case .rateLimited?: return "Çok fazla deneme yapıldı. Biraz bekleyip ekranı tekrar paylaş."
            default: return "Ekran paylaşımı için sunucuyla bağlantı kurulamadı. Bağlantını kontrol edip tekrar dene."
            }
        case .publish:
            return "Ekran yayını başlatılamadı. Yayın uzantısı ya da bağlantı sorunu olabilir; tekrar dene."
        }
    }
}
