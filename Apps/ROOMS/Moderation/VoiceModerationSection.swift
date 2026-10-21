import SwiftUI
import RoomsCore

/// What the participant sheet needs to offer moderation in the joined voice room.
struct VoiceModerationContext {
    let api: APIClient
    let me: String
    let serverID: String
    let room: VoiceRoom
    /// The community's other voice rooms.
    let otherRooms: [VoiceRoom]
}

/// Desktop `VoiceMemberMenu`: rights are read fresh when the sheet opens and only allowed actions show.
@MainActor final class VoiceModerationModel: ObservableObject {
    @Published private(set) var rights: VoiceModerationRights?
    @Published private(set) var loading = true
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var done: String?
    let context: VoiceModerationContext
    init(context: VoiceModerationContext) { self.context = context }
    func load() async {
        // Unknown rights hide moderation; the services still check every action.
        rights = try? await context.api.voiceModerationRights(serverID: context.serverID, userID: context.me, channelIDs: [context.room.id] + context.otherRooms.map(\.id))
        loading = false
    }
    var targets: [VoiceRoom] { rights?.moveTargets(from: context.room.id, among: context.otherRooms) ?? [] }
    func run(_ action: VoiceModerationAction, on person: RoomPerson) async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            switch action {
            case .move, .disconnect: try await context.api.moderateVoice(channelID: context.room.id, userID: person.id, action: action)
            case .kick: try await context.api.removeMember(serverID: context.serverID, userID: person.id)
            case .ban: try await context.api.banMember(serverID: context.serverID, userID: person.id)
            }
            switch action {
            case .move(let target): done = "\(person.name), \(context.otherRooms.first { $0.id == target }?.name ?? "diğer") odasına taşındı."
            case .disconnect: done = "\(person.name) sesten çıkarıldı."
            case .kick: done = "\(person.name) topluluktan çıkarıldı."
            case .ban: done = "\(person.name) yasaklandı."
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct VoiceModerationSection: View {
    @StateObject private var moderation: VoiceModerationModel
    let person: RoomPerson
    @State private var confirming: VoiceModerationAction?
    init(context: VoiceModerationContext, person: RoomPerson) {
        _moderation = StateObject(wrappedValue: VoiceModerationModel(context: context)); self.person = person
    }
    var body: some View {
        Group {
            if moderation.loading { Section { HStack(spacing: 10) { ProgressView(); Text("Yönetim yetkilerin okunuyor…").foregroundStyle(.secondary) } } }
            else if let rights = moderation.rights, rights.any, rights.applies(to: person.id, me: moderation.context.me) {
                Section {
                    if let done = moderation.done { Label(done, systemImage: "checkmark.circle").foregroundStyle(.green) }
                    else {
                        if !moderation.targets.isEmpty {
                            Menu {
                                ForEach(moderation.targets) { room in Button(room.name) { Task { await moderation.run(.move(to: room.id), on: person) } } }
                            } label: { Label("Başka odaya taşı", systemImage: "arrow.right.circle") }
                        }
                        if rights.canMove(from: moderation.context.room.id) { Button("Sesten çıkar", systemImage: "phone.down", role: .destructive) { confirming = .disconnect } }
                        if rights.kick { Button("Topluluktan çıkar", systemImage: "person.badge.minus", role: .destructive) { confirming = .kick } }
                        if rights.ban { Button("Yasakla", systemImage: "hand.raised", role: .destructive) { confirming = .ban } }
                    }
                    if let error = moderation.error { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Yönetim") } footer: { Text("Taşınan kişi yeni odaya kendi bağlantısıyla katılır.") }
                    .disabled(moderation.busy)
            }
        }
        .task { await moderation.load() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming { Button(confirmTitle, role: .destructive) { Task { await moderation.run(action, on: person) } } }
            Button("Vazgeç", role: .cancel) { confirming = nil }
        } message: { Text(confirmBody) }
    }
    private var confirmTitle: String {
        switch confirming { case .kick: "Topluluktan çıkar"; case .ban: "Yasakla"; default: "Sesten çıkar" }
    }
    private var confirmBody: String {
        switch confirming {
        case .kick: "\(person.name) topluluktan çıkarılacak. Yeni bir davetle geri dönebilir."
        case .ban: "\(person.name) topluluktan çıkarılıp yasaklanacak. Yasak kaldırılana kadar geri dönemez."
        default: "\(person.name) ses odasından çıkarılacak. İsterse yeniden katılabilir."
        }
    }
}
