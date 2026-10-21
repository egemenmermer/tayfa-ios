import LiveKit

/// ReplayKit hands the phone's screen to LiveKit's sample handler, which forwards the frames to
/// the ROOMS app through the shared App Group; the app publishes them as its screen share.
final class SampleHandler: LKSampleHandler, @unchecked Sendable {}
