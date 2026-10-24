import SwiftUI
import LiveKit
import RoomsCore

enum Palette {
    static let canvas = Color(red: 0.078, green: 0.082, blue: 0.094)
    static let rail = Color(red: 0.063, green: 0.067, blue: 0.078)
    static let raised = Color(red: 0.141, green: 0.149, blue: 0.176)
    static let separator = Color.white.opacity(0.06)
    static let surface = Color(red: 0.106, green: 0.114, blue: 0.133)
    static let accent = Color(red: 0.545, green: 0.514, blue: 1)
}

/// Quiet pointer-down feedback; disabled and Reduce Motion states never scale.
struct RoomControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    var selected = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? Color.red : selected ? Palette.accent : Color.primary)
            .background(selected ? Palette.accent.opacity(0.16) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Palette.accent.opacity(0.4) : Color.white.opacity(0.1)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.1 : 0.14), value: configuration.isPressed)
    }
}
@main struct RoomsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RoomsModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView(model: model).tint(Palette.accent).preferredColorScheme(.dark)
                .task { await model.restore() }
                .onChange(of: phase) { _, phase in model.setForeground(phase != .background); model.chat.setInteractive(phase == .active) }
        }
    }
}
private struct RootView: View {
    @ObservedObject var model: RoomsModel
    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            if model.restoring { VStack(spacing: 18) { Text("Tayfa").font(.title2.weight(.black)).tracking(5); ProgressView("Oturum açılıyor…") } }
            else if model.user == nil { LoginView(model: model) }
            else { CommunityShell(model: model, chat: model.chat, media: model.media); DMCallHost(calls: model.calls, model: model) }
        }
    }
}
/// Drives sign-in: email and password, then a TOTP or recovery code for accounts with MFA, then an
/// optional invitation. Signed in through `RoomsModel.restore()` so the model's private session
/// state is set by its own code path (token is saved to the vault first).
@MainActor private final class SignInFlow: ObservableObject {
    enum Stage: Equatable { case credentials, mfa(ticket: String, methods: [MFAMethod]) }
    @Published private(set) var stage = Stage.credentials
    @Published private(set) var busy = false
    @Published var error: String?
    private var attempt = 0

    static var origin: URL? {
        try? EndpointPolicy.origin(Bundle.main.object(forInfoDictionaryKey: "ROOMSAPIOrigin") as? String ?? "")
    }
    func restart() { attempt += 1; stage = .credentials; error = nil; busy = false }
    func submitPassword(email: String, password: String, invite: String, model: RoomsModel) async {
        guard !busy else { return }
        guard let origin = Self.origin else { error = RoomsError.invalidEndpoint.localizedDescription; return }
        busy = true; error = nil; model.error = nil; attempt += 1; let mine = attempt
        defer { if attempt == mine { busy = false } }
        do {
            let step = try await APIClient.loginStep(origin: origin, email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            guard attempt == mine else { return }
            switch step {
            case .success(let token): await finish(token: token, origin: origin, invite: invite, model: model)
            case .mfa(let ticket, let methods): stage = .mfa(ticket: ticket, methods: methods)
            }
        } catch { if attempt == mine { self.error = error.localizedDescription } }
    }
    func submitCode(_ response: MFAResponse, ticket: String, invite: String, model: RoomsModel) async {
        guard !busy else { return }
        guard let origin = Self.origin else { error = RoomsError.invalidEndpoint.localizedDescription; return }
        busy = true; error = nil; model.error = nil; attempt += 1; let mine = attempt
        defer { if attempt == mine { busy = false } }
        do {
            let token = try await APIClient.completeMFA(origin: origin, ticket: ticket, response: response)
            guard attempt == mine else { return }
            await finish(token: token, origin: origin, invite: invite, model: model)
        } catch { if attempt == mine { self.error = error.localizedDescription } }
    }
    private func finish(token: String, origin: URL, invite: String, model: RoomsModel) async {
        do { try SessionVault.save(token, origin: origin) } catch { self.error = error.localizedDescription; return }
        // The invitation is redeemed before the session list loads, so the community is in the first list.
        var inviteFailure: String?
        if !invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let code = try InviteInput.code(from: invite, origin: origin)
                _ = try await APIClient(origin: origin, token: token).redeemInvite(code: code)
            } catch { inviteFailure = "Davete katılınamadı: \(error.localizedDescription)" }
        }
        await model.restore()
        if let inviteFailure, model.user != nil { model.error = inviteFailure }
        if model.user == nil { error = model.error }
    }
}
private struct LoginView: View {
    @ObservedObject var model: RoomsModel
    @StateObject private var flow = SignInFlow()
    @State private var email = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var showingInvite = false
    @State private var code = ""
    @State private var useRecovery = false
    @FocusState private var codeFocused: Bool
    private var mfa: (ticket: String, methods: [MFAMethod])? { if case .mfa(let t, let m) = flow.stage { (t, m) } else { nil } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) { RoundedRectangle(cornerRadius: 4).fill(Palette.accent).frame(width: 13, height: 13); Text("Tayfa").font(.subheadline.weight(.black)).tracking(4) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Aynı oda.\nDaha yakın.").font(.largeTitle.bold()).tracking(-1)
                    Text("Topluluğun, sohbetlerin ve birlikte geçirdiğin zaman.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 32)
                if let mfa { verification(mfa) } else { credentials }
            }.padding(28).padding(.top, 20).frame(maxWidth: 480)
        }.scrollDismissesKeyboard(.interactively).frame(maxWidth: .infinity)
    }
    private var shownError: String? { flow.error ?? model.error }
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tekrar hoş geldin").font(.title3.bold())
            VStack(spacing: 14) {
                TextField("E-posta", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("login.email")
                SecureField("Şifre", text: $password).textContentType(.password).accessibilityIdentifier("login.password")
            }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            if showingInvite || !invite.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Davet bağlantısı veya kodu", text: $invite).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("login.invite")
                    Text("Giriş yaptıktan sonra bu davetle topluluğa katılırsın.").font(.footnote).foregroundStyle(.secondary)
                }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            } else {
                Button("Davet kodu gir") { showingInvite = true }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("login.inviteToggle")
            }
            if let error = shownError { Notice(text: error) }
            Button { Task { await flow.submitPassword(email: email, password: password, invite: invite, model: model) } } label: {
                HStack { Spacer(); if flow.busy { ProgressView() }; Text(flow.busy ? "Giriş yapılıyor…" : "Giriş yap").bold(); Spacer() }.frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.canvas)
            .disabled(flow.busy || email.isEmpty || password.isEmpty).accessibilityIdentifier("login.submit")
            Text("Mevcut Tayfa hesabını kullan.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func verification(_ step: (ticket: String, methods: [MFAMethod])) -> some View {
        let canTotp = step.methods.contains(.totp), canRecovery = step.methods.contains(.recovery)
        let recovery = useRecovery || !canTotp
        return VStack(alignment: .leading, spacing: 16) {
            Text("Ek doğrulama").font(.title3.bold())
            Text(recovery ? "Hesabını kurtarma kodlarından birini girerek doğrula. Her kod bir kez kullanılır." : "Doğrulama uygulamandaki 6 haneli kodu gir.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(recovery ? "Kurtarma kodu" : "Doğrulama kodu", text: $code)
                .textContentType(recovery ? nil : .oneTimeCode).keyboardType(recovery ? .asciiCapable : .numberPad)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($codeFocused)
                .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("login.code")
                .onSubmit { submitCode(step.ticket, recovery: recovery) }
            if let error = shownError { Notice(text: error) }
            Button { submitCode(step.ticket, recovery: recovery) } label: {
                HStack { Spacer(); if flow.busy { ProgressView() }; Text(flow.busy ? "Doğrulanıyor…" : "Doğrula").bold(); Spacer() }.frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.canvas)
            .disabled(flow.busy || code.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("login.codeSubmit")
            if canTotp && canRecovery {
                Button(recovery ? "Doğrulama uygulaması kodunu kullan" : "Kurtarma kodu kullan") { useRecovery.toggle(); code = ""; flow.error = nil }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("login.codeMode")
            }
            Button("Geri dön") { code = ""; useRecovery = false; flow.restart() }.font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44).accessibilityIdentifier("login.codeBack")
        }.onAppear { codeFocused = true }
    }
    private func submitCode(_ ticket: String, recovery: Bool) {
        let typed = code
        Task { await flow.submitCode(recovery ? .recovery(typed) : .totp(typed), ticket: ticket, invite: invite, model: model) }
    }
}
/// "Davet kodu gir" for a signed-in person: joins the community and refreshes the list.
/// Presented from the community shell (see merge note); it needs no model state beyond `retryList()`.
struct InviteCodeSheet: View {
    @ObservedObject var model: RoomsModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var joined: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Davet bağlantısı veya kodu", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("invite.field")
                } footer: { Text("Bir arkadaşının gönderdiği tayfa bağlantısını ya da kodu yapıştır.") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if let joined { Section { Label(joined, systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
                Section {
                    Button { Task { await join() } } label: { HStack { if busy { ProgressView() }; Text(busy ? "Katılınıyor…" : "Katıl").bold() } }
                        .disabled(busy || joined != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("invite.join")
                }
            }
            .navigationTitle("Davet kodu gir").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(joined == nil ? "Vazgeç" : "Kapat") { dismiss() } } }
        }
    }
    private func join() async {
        guard !busy, let origin = SignInFlow.origin else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let code = try InviteInput.code(from: text, origin: origin)
            guard let token = try SessionVault.read(origin: origin) else { throw InviteError.sessionExpired }
            let result = try await APIClient(origin: origin, token: token).redeemInvite(code: code)
            joined = result.communityName.map { "\($0) topluluğuna katıldın." } ?? "Topluluğa katıldın."
            model.retryList()
        } catch let failure as InviteError { self.error = failure.localizedDescription }
        catch is CancellationError {}
        catch { self.error = RoomsError.unavailable.localizedDescription }
    }
}
struct Notice: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12)).accessibilityAddTraits(.updatesFrequently) }
}
