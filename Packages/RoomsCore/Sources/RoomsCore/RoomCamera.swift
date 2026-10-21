import Foundation

public struct CameraSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case off, requesting, starting, on, stopping, switching }
    public var phase: Phase = .off
    public var front = true
    public var error: String?
    public init() {}
    public var isOn: Bool { phase == .on || phase == .switching }
    public var busy: Bool { phase == .requesting || phase == .starting || phase == .stopping || phase == .switching }
}

@MainActor public protocol RoomCameraTransport: AnyObject {
    var allowed: Bool { get }
    var isFront: Bool { get }
    func requestPermission() async -> Bool
    func setEnabled(_ enabled: Bool) async throws
    func switchPosition() async throws -> Bool
}

/// One immutable transport per room. SDK mutations serialize; permissions do not block teardown.
@MainActor public final class RoomCameraSession {
    public private(set) var snapshot = CameraSnapshot()
    public var onChange: ((CameraSnapshot) -> Void)?
    public var onUnsafeStop: (() -> Void)?
    private let transport: any RoomCameraTransport
    private var epoch = OperationEpoch()
    private var pending: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var foreground = true
    private var closed = false
    private let timeout: Duration
    public init(transport: any RoomCameraTransport, timeout: Duration = .seconds(25)) { self.transport = transport; self.timeout = timeout }
    private func publish() { onChange?(snapshot) }
    public func toggle() async {
        if snapshot.phase != .off { await stop(); return }
        guard !closed, foreground else { return }
        guard transport.allowed else { snapshot.error = "Bu odada kamera açma yetkin yok."; publish(); return }
        let ticket = epoch.advance(); snapshot.phase = .requesting; snapshot.error = nil; publish()
        deadline?.cancel()
        deadline = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, epoch.owns(ticket) else { return }
            if snapshot.phase == .starting { closed = true; onUnsafeStop?() }
            await stop(error: "Kamera açılamadı. Tekrar dene.")
        }
        let permitted = await transport.requestPermission()
        guard epoch.owns(ticket), !closed, foreground else { return }
        guard permitted else { deadline?.cancel(); snapshot.phase = .off; snapshot.error = "Kamera izni yok. Dinlemeye ve yayın izlemeye devam edebilirsin; Ayarlar’dan kamera erişimini aç."; publish(); return }
        guard transport.allowed else { deadline?.cancel(); snapshot.phase = .off; snapshot.error = "Bu odada kamera açma yetkin yok."; publish(); return }
        snapshot.phase = .starting; publish()
        let previous = pending
        let task = Task { [weak self] in
            await previous?.value
            guard let self, epoch.owns(ticket), !closed, foreground, transport.allowed else { return }
            do {
                try await transport.setEnabled(true)
                guard epoch.owns(ticket), !closed, foreground, transport.allowed else {
                    do { try await transport.setEnabled(false) } catch { onUnsafeStop?() }
                    return
                }
                snapshot.phase = .on; snapshot.front = transport.isFront; snapshot.error = nil
            } catch {
                // A publish failure can still leave a running local capturer.
                do { try await transport.setEnabled(false) } catch { onUnsafeStop?() }
                guard epoch.owns(ticket) else { return }
                snapshot.phase = .off; snapshot.error = "Kamera açılamadı. Ses bağlantın devam ediyor. Tekrar dene."
            }
            if epoch.owns(ticket) { deadline?.cancel(); publish() }
        }
        pending = task; await task.value
    }
    public func stop(error: String? = nil) async {
        let ticket = epoch.advance(); deadline?.cancel()
        snapshot.phase = .stopping; snapshot.error = error; publish()
        let previous = pending
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await transport.setEnabled(false) }
            catch { onUnsafeStop?() }
            if epoch.owns(ticket) { snapshot.phase = .off; publish() }
        }
        pending = task; await task.value
    }
    public func switchPosition() async {
        guard snapshot.phase == .on, !closed, foreground else { return }
        let ticket = epoch.advance(); snapshot.phase = .switching; publish()
        let previous = pending
        let task = Task { [weak self] in
            await previous?.value
            guard let self, epoch.owns(ticket), !closed, foreground else { return }
            do { let front = try await transport.switchPosition(); if epoch.owns(ticket) { snapshot.front = front; snapshot.phase = .on; snapshot.error = nil; publish() } }
            catch { if epoch.owns(ticket) { snapshot.phase = .on; snapshot.error = "Kamera değiştirilemedi. Mevcut kamera açık."; publish() } }
        }
        pending = task; await task.value
    }
    /// Leaving the foreground stops the camera unless a video-call Picture in Picture keeps the call
    /// visible and iOS granted multitasking camera access. New starts still require the foreground.
    public func setForeground(_ value: Bool, keepRunning: Bool = false) async {
        foreground = value
        if !value, !keepRunning { await stop() }
    }
    public func revoke() async { await stop(error: "Kamera iznin değişti. Yayın kapatıldı.") }
    public func invalidate() { closed = true; epoch.advance(); deadline?.cancel() }
    public func shutdown() async { invalidate(); await stop() }
}

public enum CameraSubscriptionPolicy {
    public static func wants(participantID: String, visible: Set<String>, foreground: Bool) -> Bool { foreground && visible.contains(participantID) }
    public static func canPublish(enabled: Bool, sources: Set<String>) -> Bool { enabled && (sources.isEmpty || sources.contains("camera")) }
}
