import AVFoundation
import LiveKit
import RoomsCore

@MainActor final class NativeRoomCamera: RoomCameraTransport {
    weak var room: Room?
    let isForeground: () -> Bool
    init(room: Room, isForeground: @escaping () -> Bool) { self.room = room; self.isForeground = isForeground }
    var allowed: Bool {
        guard let room, room.connectionState == .connected, isForeground() else { return false }
        let permissions = room.localParticipant.permissions
        return permissions.canPublish && (permissions.canPublishSources.isEmpty || permissions.canPublishSources.contains(Track.Source.camera.rawValue))
    }
    var isFront: Bool {
        let track = room?.localParticipant.trackPublications.values.first(where: { $0.source == .camera })?.track as? LocalVideoTrack
        return (track?.capturer as? CameraCapturer)?.position != .back
    }
    func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
    func setEnabled(_ enabled: Bool) async throws {
        guard let room else { return }
        if !enabled, !room.localParticipant.trackPublications.values.contains(where: { $0.source == .camera }) { return }
        // SDK camera mute disables the track AND stops its capturer; it is not just hidden UI.
        _ = try await room.localParticipant.setCamera(enabled: enabled, captureOptions: CameraCaptureOptions(position: .front, dimensions: .h720_169, fps: 30))
        // iOS 18+ allows video-call apps (voip background mode) to keep the camera in Picture in Picture.
        if enabled, let capturer, capturer.isMultitaskingAccessSupported, !capturer.isMultitaskingAccessEnabled {
            capturer.isMultitaskingAccessEnabled = true
        }
    }
    private var capturer: CameraCapturer? {
        (room?.localParticipant.trackPublications.values.first(where: { $0.source == .camera })?.track as? LocalVideoTrack)?.capturer as? CameraCapturer
    }
    /// True when the running camera may continue while the app is in Picture in Picture.
    var runsInBackground: Bool { capturer?.isMultitaskingAccessEnabled == true }
    func switchPosition() async throws -> Bool {
        guard let track = room?.localParticipant.trackPublications.values.first(where: { $0.source == .camera })?.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { throw RoomsError.invalidResponse }
        _ = try await capturer.switchCameraPosition()
        return capturer.options.position == .front
    }
}
