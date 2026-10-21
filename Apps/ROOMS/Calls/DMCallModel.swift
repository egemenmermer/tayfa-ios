import UIKit
import Combine
import AVFoundation
import LiveKit
import RoomsCore

/// One-to-one DM calls (desktop `dm-call.ts` and `DmCallRuntime.tsx`). Access signaling is polled every
/// 3 s while the app is open, and during a call also in the background, because the service ends an
/// accepted call after 35 s without a poll. Media uses the shared `RoomMedia` connection: like desktop,
/// a call takes over the voice connection, so the voice room is left first. There is no call push, so an
/// incoming call rings only while ROOMS is open.
@MainActor final class DMCallModel: ObservableObject {
    @Published private(set) var call: DMCallSession?
    @Published private(set) var busy = false
    /// The last action failure or end-of-call line; shown until dismissed or the next call.
    @Published var error: String?
    @Published private(set) var connected = false
    @Published private(set) var signalingError: String?
    /// The full call screen; otherwise an active call shows as a dock above the tabs.
    @Published var expanded = false
    private(set) var me: String?
    private var api: APIClient?
    private var media: RoomMedia?
    private var leaveVoice: (() async -> Void)?
    private var voiceBusy: () -> Bool = { false }
    private var account = ""
    private var epoch = 0
    private var consent: (callID: String, camera: Bool)?
    private var connecting: Task<Void, Never>?
    private var stopped: Set<String> = []
    private var failures = 0
    private var nextPoll = Date.distantPast
    private var polling: Task<Void, Never>?
    private var pollInFlight = false
    private var foreground = true
    private var observers: Set<AnyCancellable> = []
    private let ringer = DMCallRinger()

    var incoming: Bool { if let call, let me { return call.incoming(for: me) }; return false }
    var peer: (id: String, name: String)? { if let call, let me { return call.peer(for: me) }; return nil }
    /// Why a new call cannot start now (desktop `dmCallUnavailable`), or nil.
    var unavailableReason: String? {
        if me == nil { return "Önce giriş yap." }
        if let signalingError { return signalingError }
        if busy || connecting != nil { return "Arama işlemi sürüyor." }
        if call?.active == true { return "Önce mevcut özel görüşmeyi bitir." }
        if voiceBusy() { return "Ses bağlantısı değişiyor. Biraz bekle." }
        return nil
    }
    /// A ringing or accepted call keeps voice rooms closed, as on desktop.
    var voiceBlockReason: String? { busy || connecting != nil || call?.active == true ? "Önce özel görüşmeyi bitir." : nil }

    func attach(media: RoomMedia, leaveVoice: @escaping () async -> Void, voiceBusy: @escaping () -> Bool) {
        self.media = media; self.leaveVoice = leaveVoice; self.voiceBusy = voiceBusy
        // A call whose media dropped for good is over (desktop ends it on a media error).
        media.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.mediaChanged() }.store(in: &observers)
    }
    func configure(api: APIClient, userID: String, account: String) {
        self.api = api; me = userID
        if account != self.account {
            self.account = account; epoch += 1
            stopped = []; failures = 0; nextPoll = .distantPast; signalingError = nil
        }
        startPolling()
    }
    /// Sign-out or account change: ends any call and forgets this account.
    func reset() async {
        polling?.cancel(); polling = nil
        // Signing out must not wait for the network; the service ends an unseen call by itself.
        await end(waitForSignal: false)
        stopped = []; failures = 0; nextPoll = .distantPast; signalingError = nil; error = nil
        api = nil; me = nil; account = ""
    }
    func setForeground(_ value: Bool) {
        foreground = value; updateRinger()
        if value { startPolling() }
        else if call?.active != true { polling?.cancel(); polling = nil }
    }

    func start(dmID: String, mode: DMCallMode) async {
        if let reason = unavailableReason { error = reason; return }
        guard let api else { return }
        epoch += 1; let generation = epoch
        busy = true; error = nil
        do {
            let fresh = try await api.dmCallStart(dmID: dmID, mode: mode)
            if generation != epoch { _ = try? await api.dmCallRespond(callID: fresh.id, action: .end); return }
            consent = (fresh.id, mode == .video); call = fresh; connected = false; expanded = true
        } catch { if generation == epoch { self.error = failure(error) } }
        if generation == epoch { busy = false }
    }
    func accept(camera: Bool) async {
        guard let call, call.ringing, incoming, !busy, connecting == nil, let api else { return }
        if voiceBusy() { error = "Ses bağlantısı değişiyor. Biraz bekle."; return }
        let generation = epoch
        busy = true; error = nil; ringer.stop()
        do {
            let next = try await api.dmCallRespond(callID: call.id, action: .accept)
            guard generation == epoch else { return }
            consent = (next.id, camera); self.call = next; expanded = true
            await connectAccepted()
        } catch { if generation == epoch { self.error = failure(error) } }
        if generation == epoch { busy = false }
    }
    /// An accepted call this phone has not joined yet (accepted elsewhere, or after a restart).
    func joinAccepted(camera: Bool = false) async {
        guard let call, call.state == .accepted, connecting == nil, !busy else { return }
        if voiceBusy() { error = "Ses bağlantısı değişiyor. Biraz bekle."; return }
        consent = (call.id, camera)
        await connectAccepted()
    }
    /// Rejects, cancels or hangs up (desktop `endDmCall`).
    func end(_ action: DMCallAction = .end, waitForSignal: Bool = true) async {
        let current = call, wasConnected = connected, pending = connecting
        epoch += 1; consent = nil
        if let current { stopped.insert(current.id) }
        call = nil; busy = true; connected = false; error = nil; expanded = false; ringer.stop()
        let signal: Task<Void, Never>? = current.map { call in Task { [api] in _ = try? await api?.dmCallRespond(callID: call.id, action: action) } }
        if wasConnected || pending != nil { await media?.disconnect() }
        await pending?.value
        if waitForSignal { await signal?.value }
        busy = false
    }

    private func connectAccepted() async {
        guard let call, call.state == .accepted, consent?.callID == call.id, !connected, connecting == nil, let api, let media else { return }
        let generation = epoch, camera = consent?.camera ?? false, callID = call.id
        let valid = { [weak self] () -> Bool in self.map { generation == $0.epoch && $0.call?.id == callID && $0.call?.state == .accepted } ?? false }
        busy = true
        let work = Task { [weak self] in
            do {
                await self?.leaveVoice?()
                guard valid() else { return }
                let grant = try await api.dmCallGrant(callID: callID)
                guard valid() else { return }
                // The voice room's automatic rejoin must not pull the connection back into a room.
                media.onInterruptionRecovery = nil
                try await media.connect(grant: grant)
                guard valid(), let self else { await media.disconnect(); return }
                self.connected = true
                // Starting or accepting is the microphone consent; the camera is each person's own choice.
                if media.muted { await media.toggleMicrophone(remember: false) }
                if camera, valid(), !media.camera.isOn, !media.camera.busy { await media.toggleCamera() }
            } catch {
                guard valid(), let self else { return }
                _ = try? await api.dmCallRespond(callID: callID, action: .end)
                await media.disconnect()
                self.consent = nil; self.stopped.insert(callID); self.call = nil; self.connected = false; self.expanded = false
                self.error = self.failure(error)
            }
        }
        connecting = work
        await work.value
        if connecting == work { connecting = nil }
        if generation == epoch { busy = false }
    }
    private func mediaChanged() {
        guard connected, connecting == nil, let media, media.room == nil else { return }
        connected = false  // handled once, however many changes follow
        Task { [weak self] in await self?.end(); self?.error = "Medya bağlantısı kesildi. Yeni bir arama başlatabilirsin." }
    }

    private var shouldPoll: Bool { api != nil && (foreground || call?.active == true) }
    private func startPolling() {
        guard polling == nil, api != nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled, let self, self.shouldPoll {
                await self.refresh()
                try? await Task.sleep(for: .seconds(DMCallPolling.interval))
            }
            // Stopped by itself (background without a call): the next foreground starts it again.
            if !Task.isCancelled { self?.polling = nil }
        }
    }
    private func refresh() async {
        guard let api, !pollInFlight, Date() >= nextPoll else { return }
        pollInFlight = true; defer { pollInFlight = false }
        let generation = epoch, owner = account
        do {
            let fresh = try await api.dmCallPoll()
            guard generation == epoch, owner == account else { return }
            failures = 0; nextPoll = .distantPast; signalingError = nil
            guard let fresh, fresh.active else {
                if let previous = call, fresh == nil || previous.id == fresh?.id {
                    let message = DMCallSession.endMessage(fresh?.reason)
                    await end()
                    error = message
                }
                return
            }
            if stopped.contains(fresh.id) { return }
            if let previous = call, previous.id != fresh.id { await end() }
            let arriving = call?.id != fresh.id
            call = fresh
            if arriving, fresh.ringing, incoming { expanded = true; error = nil }
            updateRinger()
            await connectAccepted()
        } catch {
            guard generation == epoch, owner == account else { return }
            // An idle background failure is not a user action; back off like desktop.
            failures += 1; nextPoll = Date().addingTimeInterval(DMCallPolling.backoff(failures: failures))
            signalingError = failure(error)
        }
    }
    private func updateRinger() {
        // An open microphone in a voice room would carry the tone to the room: then only haptics.
        if foreground, call?.ringing == true, incoming { ringer.start(tone: !(media?.connected == true && media?.muted == false)) } else { ringer.stop() }
    }
    private func failure(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.range(of: "token|jwt|https?:|wss?:", options: [.regularExpression, .caseInsensitive]) != nil ? "Arama bağlantısı kurulamadı. Yeniden dene." : text
    }
}

/// The incoming-call ring: a generated tone in the current audio session (it follows the ring/silent
/// switch outside a voice room) and a haptic pulse with every ring.
@MainActor final class DMCallRinger {
    private var player: AVAudioPlayer?
    private var pulses: Task<Void, Never>?
    func start(tone: Bool) {
        if !tone { player?.stop(); player = nil }
        else if player == nil, let player = try? AVAudioPlayer(data: DMCallRingTone.wav()) {
            player.numberOfLoops = -1; player.volume = 0.9; player.play(); self.player = player
        }
        guard pulses == nil else { return }
        pulses = Task {
            let generator = UINotificationFeedbackGenerator()
            while !Task.isCancelled {
                generator.notificationOccurred(.warning)
                try? await Task.sleep(for: .seconds(2.4))
            }
        }
    }
    func stop() { player?.stop(); player = nil; pulses?.cancel(); pulses = nil }
}
