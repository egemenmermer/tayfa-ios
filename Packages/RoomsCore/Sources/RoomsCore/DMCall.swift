import Foundation

// One-to-one calls from a DM (desktop `packages/shared-contracts/src/dm-call.ts`). Signaling is
// polled from Access; media is a LiveKit room `rooms-dm-call-<id>` with microphone and camera only.

public enum DMCallMode: String, Codable, Sendable { case audio, video }
public enum DMCallState: String, Codable, Sendable { case ringing, accepted, ended }
public enum DMCallReason: String, Codable, Sendable {
    case rejected, cancelled, ended, missed, disconnected, accessLost = "access-lost"
}
public enum DMCallAction: String, Sendable { case accept, reject, end }

public struct DMCallSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let dmId: String
    public let callerId: String
    public let calleeId: String
    public let callerName: String
    public let calleeName: String
    public let mode: DMCallMode
    public let state: DMCallState
    public let reason: DMCallReason?
    /// Epoch milliseconds (server clock).
    public let createdAt: Double
    public let acceptedAt: Double?
    public let expiresAt: Double
    public init(id: String, dmId: String, callerId: String, calleeId: String, callerName: String, calleeName: String, mode: DMCallMode, state: DMCallState,
                reason: DMCallReason? = nil, createdAt: Double, acceptedAt: Double? = nil, expiresAt: Double) {
        self.id = id; self.dmId = dmId; self.callerId = callerId; self.calleeId = calleeId; self.callerName = callerName; self.calleeName = calleeName
        self.mode = mode; self.state = state; self.reason = reason; self.createdAt = createdAt; self.acceptedAt = acceptedAt; self.expiresAt = expiresAt
    }
    /// The service's public shape, checked as strictly as the desktop schema.
    public func validated() throws -> DMCallSession {
        guard UUID(uuidString: id) != nil, [dmId, callerId, calleeId].allSatisfy({ MoveSignal.valid($0) }),
              callerName.count <= 128, calleeName.count <= 128,
              createdAt.isFinite, expiresAt.isFinite, acceptedAt?.isFinite ?? true else { throw DMCallError(code: "DM_CALL_INVALID") }
        return self
    }
    public func incoming(for userID: String) -> Bool { calleeId == userID }
    /// The other person of the call, seen from `userID`.
    public func peer(for userID: String) -> (id: String, name: String) {
        incoming(for: userID) ? (callerId, callerName) : (calleeId, calleeName)
    }
    public var ringing: Bool { state == .ringing }
    public var active: Bool { state != .ended }
    /// The line shown when a call ends without this person ending it (desktop `refreshDmCall`).
    public static func endMessage(_ reason: DMCallReason?) -> String {
        switch reason {
        case .rejected: "Arama reddedildi."
        case .missed: "Arama yanıtlanmadı."
        case .accessLost: "Özel görüşme erişimi sona erdi."
        case .disconnected: "Karşı tarafın arama bağlantısı kesildi."
        default: "Görüşme sona erdi."
        }
    }
}

/// A refused call request, with the desktop's Turkish text (`dm-call-http.ts`).
public struct DMCallError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "DM_CALL_BUSY": "Bu kişi başka bir aramada. Daha sonra tekrar dene."
        case "DM_CALL_FRIEND_REQUIRED": "Özel arama için önce arkadaş olmalısınız."
        case "DM_CALL_ACCESS_DENIED": "Bu özel görüşmeye erişimin yok."
        case "DM_CALL_NOT_FOUND", "DM_CALL_ENDED": "Arama sona erdi."
        case "DM_CALL_ACCEPT_REQUIRED": "Arama henüz kabul edilmedi."
        case "AUTH_REQUIRED": "Oturumunun süresi doldu. Yeniden giriş yap."
        case "DM_CALL_UNSUPPORTED": "Bu sunucuda özel arama servisi etkin değil."
        case "DM_CALL_INVALID": "Arama sunucusu geçersiz yanıt verdi."
        case "DM_CALL_GRANT_INVALID": "Arama medya izni geçersiz."
        case "DM_CALL_REJECTED": "Arama isteği reddedildi."
        case "RATE_LIMITED": "Çok fazla işlem yapıldı. Biraz bekleyip yeniden dene."
        default: "Arama sunucusuna ulaşılamıyor. Yeniden dene."
        }
    }
}

public enum DMCallPolling {
    /// Desktop polls every 3 s while signed in.
    public static let interval: TimeInterval = 3
    /// Wait after `failures` failed polls in a row: 6, 12, 24, 48, then 60 s (desktop `nextPollAt`).
    public static func backoff(failures: Int) -> TimeInterval { min(60, 3 * pow(2, Double(min(max(failures, 0), 5)))) }
}

/// A soft two-note ring that loops while a call rings; generated, no bundled asset.
public enum DMCallRingTone {
    public static func samples() -> [Int16] {
        let rate = Double(RoomCueTone.sampleRate), count = Int(rate * 2.4)
        return (0..<count).map { index in
            let t = Double(index) / rate
            // Two short rings, then silence until the loop starts again.
            guard t < 1.1, t.truncatingRemainder(dividingBy: 0.55) < 0.4 else { return 0 }
            let phase = t.truncatingRemainder(dividingBy: 0.55) / 0.4
            let envelope = pow(sin(Double.pi * phase), 2)
            let tone = sin(2 * Double.pi * 660 * t) * 0.6 + sin(2 * Double.pi * 880 * t) * 0.4
            return Int16((tone * envelope * 0.16 * 32767).rounded())
        }
    }
    public static func wav() -> Data { RoomCueTone.wav(samples: samples()) }
}
