import AVKit
import LiveKit
import UIKit

/// Keeps the room's main video in a movable video-call Picture in Picture window when the app leaves
/// the foreground. It starts automatically from the inline call and stops when there is no video.
@MainActor final class CallPictureInPicture: NSObject {
    private(set) var isActive = false
    var onActiveChange: ((Bool) -> Void)?
    private var controller: AVPictureInPictureController?
    private let callController = AVPictureInPictureVideoCallViewController()
    private let videoView = VideoView()
    private var anchor: UIView?

    override init() {
        super.init()
        videoView.renderMode = .sampleBuffer
        videoView.layoutMode = .fit
        videoView.translatesAutoresizingMaskIntoConstraints = false
        callController.view.backgroundColor = .black
        callController.view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: callController.view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: callController.view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: callController.view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: callController.view.bottomAnchor),
        ])
    }

    /// `track` is nil when nothing should be shown; a running window then closes.
    func update(track: VideoTrack?, mirrored: Bool, landscape: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if videoView.track !== track { videoView.track = track }
        videoView.mirrorMode = mirrored ? .mirror : .off
        callController.preferredContentSize = landscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        if track != nil { install() }
        controller?.canStartPictureInPictureAutomaticallyFromInline = track != nil
        if track == nil, controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }

    func teardown() {
        update(track: nil, mirrored: false, landscape: false)
        controller?.delegate = nil
        controller = nil
        anchor?.removeFromSuperview()
        anchor = nil
        setActive(false)
    }

    private func install() {
        guard controller == nil,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        // The source view only anchors the system transition; the call UI itself stays unchanged.
        let anchor = UIView(frame: CGRect(x: 0, y: window.bounds.maxY - 2, width: 2, height: 2))
        anchor.isUserInteractionEnabled = false
        anchor.backgroundColor = .black
        window.addSubview(anchor)
        self.anchor = anchor
        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: anchor, contentViewController: callController)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
    }

    private func setActive(_ value: Bool) {
        guard isActive != value else { return }
        isActive = value
        onActiveChange?(value)
    }
}

extension CallPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { setActive(true) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { setActive(false) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { setActive(false) }
    }
}
