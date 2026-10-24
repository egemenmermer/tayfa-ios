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
    /// Lives above the login form so a request (and the password typed with it) survives MFA/login screen changes.
    @StateObject private var signup = SignupFlow()
    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            if model.restoring { VStack(spacing: 18) { Text("Tayfa").font(.title2.weight(.black)).tracking(5); ProgressView("Oturum açılıyor…") } }
            else if model.user == nil, model.restoreProblem != nil { RestoreRetryView(model: model) }
            else if model.user == nil, signup.pending != nil, !signup.hidden { SignupPendingView(model: model, signup: signup) }
            else if model.user == nil { LoginView(model: model, signup: signup) }
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
    @ObservedObject var signup: SignupFlow
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
                if let mfa { verification(mfa) } else if signup.showingForm { SignupFormView(model: model, signup: signup) } else { credentials }
            }.padding(28).padding(.top, 20).frame(maxWidth: 480)
        }.scrollDismissesKeyboard(.interactively).frame(maxWidth: .infinity)
        .task { await signup.load() }
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
            if let pending = signup.pending {
                Button("\(pending.username) adına gönderilmiş bir kayıt isteğin var. İsteği göster") { signup.hidden = false }
                    .font(.subheadline).multilineTextAlignment(.leading).frame(minHeight: 44).accessibilityIdentifier("login.showSignup")
            } else {
                HStack(spacing: 4) {
                    Text("Hesabın yok mu?").foregroundStyle(.secondary)
                    Button("Kayıt ol") { flow.error = nil; model.error = nil; signup.openForm() }.bold().accessibilityIdentifier("login.signup")
                }.font(.subheadline).frame(minHeight: 44)
            }
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

// MARK: Sign-up (desktop `signup-state.ts`, `SignupPending.tsx`, ConnectionPane "Kayıt ol")

/// Approved sign-up and invitation registration while signed out. The request record lives in the Keychain
/// (`PendingSignupBroker`); the password only in memory. On approval the account is created and signed in through
/// `RoomsModel.restore()`, like `SignInFlow`.
@MainActor final class SignupFlow: ObservableObject {
    @Published private(set) var pending: PendingSignupSnapshot?
    /// "Giriş ekranına dön": the request keeps going and can be shown again.
    @Published var hidden = false
    @Published private(set) var showingForm = false
    @Published private(set) var checking = false
    @Published var error: String?
    private let broker: PendingSignupBroker?
    private var failures = 0

    init() {
        broker = SignInFlow.origin.map { origin in
            PendingSignupBroker(origin: origin, store: KeychainSignupStore(service: "com.egemenmermer.rooms.mobile.session"), service: APIClient(origin: origin))
        }
    }
    func load() async { if let broker { pending = await broker.snapshot() } }
    func openForm() { showingForm = true; error = nil }
    func closeForm() { showingForm = false; error = nil }

    func request(email: String, password: String, username: String) async throws {
        guard let broker else { throw RoomsError.invalidEndpoint }
        pending = try await broker.request(email: email, password: password, username: username)
        hidden = false; showingForm = false; error = nil; failures = 0
    }
    /// Asks once; signs in when the account was created.
    func check(model: RoomsModel) async {
        guard let broker, !checking else { return }
        checking = true; error = nil; defer { checking = false }
        await apply(await broker.check(), model: model)
        failures = pending?.error != nil && pending?.ready == false ? failures + 1 : 0
    }
    func complete(email: String, password: String, model: RoomsModel) async {
        guard let broker, !checking else { return }
        checking = true; error = nil; defer { checking = false }
        do { await apply(try await broker.complete(email: email, password: password), model: model) }
        catch { pending = await broker.snapshot(); self.error = (error as? LocalizedError)?.errorDescription ?? RoomsError.unavailable.localizedDescription }
    }
    func cancel() async {
        guard let broker else { return }
        await broker.cancel(); pending = nil; error = nil
    }
    /// "Yeni istek gönder": forget the closed request and open the form.
    func startOver() async { await cancel(); hidden = false; showingForm = true }

    /// Polls while the waiting screen is in the foreground: 30 s, doubling after failures (desktop `SIGNUP_POLL_MS`).
    func poll(model: RoomsModel) async {
        await check(model: model)
        while !Task.isCancelled, pending?.phase.waiting == true {
            try? await Task.sleep(for: .seconds(SignupPollSchedule.delay(afterFailures: failures)))
            guard !Task.isCancelled else { return }
            await check(model: model)
        }
    }

    private func apply(_ progress: SignupProgress, model: RoomsModel) async {
        switch progress {
        case .none: pending = nil
        case .waiting(let snapshot): pending = snapshot
        case .registered(let token, let email):
            pending = nil
            await signIn(token: token, email: email, model: model)
        }
    }
    /// The account exists: keep the session like a sign-in and load it.
    func signIn(token: String, email: String, model: RoomsModel) async {
        showingForm = false
        guard let origin = SignInFlow.origin else { return }
        do { try SessionVault.save(token, origin: origin) } catch {
            model.error = "Hesabın oluştu ama oturum açılamadı. \(email) ile giriş yap."; return
        }
        model.error = nil
        await model.restore()
        if model.user == nil, model.restoreProblem == nil { model.error = "Hesabın oluştu ama oturum açılamadı. \(email) ile giriş yap." }
    }
}

/// "Kayıt ol": with an invitation link the account is created right away; without one the request goes to an admin.
private struct SignupFormView: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var signup: SignupFlow
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var available: Bool?
    @State private var availabilityError: String?
    @State private var busy = false
    @State private var error: String?
    private var hasInvite: Bool { !invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var validEmail: String? { SignupInput.email(email) }
    private var validName: String? { SignupInput.username(username) }
    private var ready: Bool {
        !busy && validEmail != nil && validName != nil && SignupInput.password(password) && (hasInvite || available == true || availabilityError != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kayıt ol").font(.title3.bold())
            VStack(alignment: .leading, spacing: 14) {
                TextField("E-posta", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("signup.email")
                TextField("Kullanıcı adı", text: $username).textContentType(.nickname).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("signup.username")
                SecureField("Şifre (en az 8 karakter)", text: $password).textContentType(.newPassword).accessibilityIdentifier("signup.password")
            }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            if !username.isEmpty, validName == nil {
                Text(SignupError.invalidUsername.localizedDescription).font(.footnote).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Davet bağlantısı (isteğe bağlı)", text: $invite).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("signup.invite")
                Text(inviteHelp).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            if let error { Notice(text: error) }
            Button { Task { await submit() } } label: {
                HStack { Spacer(); if busy { ProgressView() }; Text(buttonTitle).bold(); Spacer() }.frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.canvas)
            .disabled(!ready).accessibilityIdentifier("signup.submit")
            Text("Şifren onay beklerken bu cihazda saklanmaz.").font(.footnote).foregroundStyle(.secondary)
            Button("Giriş ekranına dön") { signup.closeForm() }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("signup.back")
        }
        .task { await checkAvailability() }
    }
    private var buttonTitle: String {
        if busy { return hasInvite ? "Hesap oluşturuluyor…" : "İstek gönderiliyor…" }
        return hasInvite ? "Hesap oluştur ve katıl" : "Kayıt isteği gönder"
    }
    private var inviteHelp: String {
        if hasInvite { return "Hesabın hemen oluşur ve davetin topluluğuna katılırsın." }
        if let availabilityError { return availabilityError }
        switch available {
        case .none: return "Sunucu kontrol ediliyor…"
        case .some(true): return "Davet bağlantın yoksa isteğin topluluk yöneticisine gider. Bir yönetici onaylayınca hesabın oluşur ve topluluğa katılırsın."
        case .some(false): return SignupError.notOffered.localizedDescription
        }
    }
    private func checkAvailability() async {
        guard let origin = SignInFlow.origin else { availabilityError = RoomsError.invalidEndpoint.localizedDescription; return }
        do { available = try await APIClient(origin: origin).signupAvailable(); availabilityError = nil }
        catch is CancellationError {}
        // The request itself answers with the real reason; a failed check does not block it.
        catch { availabilityError = "Sunucu şu anda kontrol edilemedi. Yine de istek gönderebilir ya da davet bağlantını yapıştırabilirsin." }
    }
    private func submit() async {
        guard ready, let email = validEmail, let name = validName else { return }
        guard let origin = SignInFlow.origin else { error = RoomsError.invalidEndpoint.localizedDescription; return }
        busy = true; error = nil; model.error = nil
        defer { busy = false }
        do {
            if hasInvite {
                let code = try InviteInput.code(from: invite, origin: origin)
                let token = try await APIClient(origin: origin).register(email: email, password: password, username: name, inviteCode: code)
                await signup.signIn(token: token, email: email, model: model)
                if model.user == nil { error = model.error }
            } else {
                try await signup.request(email: email, password: password, username: name)
            }
            password = ""
        } catch is CancellationError {}
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? RoomsError.unavailable.localizedDescription }
    }
}

/// The request this phone sent, while signed out: waiting, approved (create the account), rejected, expired and closed.
/// Every state can be left with "Giriş ekranına dön".
private struct SignupPendingView: View {
    @ObservedObject var model: RoomsModel
    @ObservedObject var signup: SignupFlow
    @Environment(\.scenePhase) private var phase
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        ScrollView {
            if let pending = signup.pending {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) { RoundedRectangle(cornerRadius: 4).fill(Palette.accent).frame(width: 13, height: 13); Text("Tayfa").font(.subheadline.weight(.black)).tracking(4) }
                    content(pending).padding(.top, 24)
                    if let error = signup.error ?? pending.error { Notice(text: error) }
                    if !pending.persisted {
                        Notice(text: pending.ready
                               ? "Bu cihaz onay bağlantını saklayamıyor. Uygulamayı kapatmadan hesabını oluştur; yoksa yeni bir istek göndermen gerekir."
                               : "Bu cihaz isteğini saklayamıyor. Onay gelene kadar uygulamayı açık bırak; kapatırsan istek unutulur ve yeniden göndermen gerekir.")
                    }
                    Button("Giriş ekranına dön") { signup.hidden = true }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("signup.pendingBack")
                }.padding(28).padding(.top, 20).frame(maxWidth: 480).onAppear { if email.isEmpty { email = pending.email } }
            }
        }
        .scrollDismissesKeyboard(.interactively).frame(maxWidth: .infinity)
        // Polls only while the app is in the foreground; a return to the foreground asks right away.
        .task(id: phase == .active) { if phase == .active { await signup.poll(model: model) } }
    }
    @ViewBuilder private func content(_ pending: PendingSignupSnapshot) -> some View {
        if pending.ready {
            heading("person.crop.circle.badge.checkmark", "Onaylandın")
            if signup.checking {
                HStack(spacing: 10) { ProgressView(); Text("Hesabın oluşturuluyor…") }.accessibilityElement(children: .combine)
            } else if !pending.passwordKnown {
                Text("Topluluk yöneticisi isteğini onayladı. Hesabını oluşturmak ve topluluğa katılmak için şifreni gir. Şifren bu cihazda saklanmaz.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 14) {
                    TextField("E-posta", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Şifre (en az 8 karakter)", text: $password).textContentType(.newPassword).accessibilityIdentifier("signup.completePassword")
                }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                primary("Hesabı oluştur ve katıl", enabled: SignupInput.password(password) && SignupInput.email(email) != nil) {
                    let typed = password; password = ""
                    await signup.complete(email: email, password: typed, model: model)
                }
            }
            secondary("İsteği bırak") { await signup.cancel() }
        } else {
            switch pending.phase {
            case .rejected:
                heading("person.crop.circle.badge.xmark", "Kayıt isteğin reddedildi")
                paragraph("Topluluk yöneticisi bu isteği onaylamadı. Hesap oluşturulmadı. Bir yanlışlık olduğunu düşünüyorsan topluluktan birinden davet bağlantısı iste.")
                primary("Tamam", enabled: true) { await signup.cancel() }
            case .expired, .issued, .closed:
                heading("clock.badge.xmark", pending.phase == .expired ? "İsteğinin süresi doldu" : pending.phase == .closed ? "İsteğin kapandı" : "Bağlantı kullanılamıyor")
                paragraph(pending.phase == .expired
                     ? "14 gün içinde kimse karar vermediği için isteğin kapandı. İstersen yeni bir istek gönderebilirsin."
                     : pending.phase == .closed
                     ? "Sunucu bu isteği artık tanımıyor; geri çekilmiş, süresi dolmuş ya da sunucudan silinmiş olabilir. Yeni bir istek gönderebilirsin."
                     : "Onay bağlantısı bu cihazda değil ya da zaten kullanıldı. Hesabın oluştuysa giriş ekranından giriş yap; değilse yeni bir istek gönder ya da topluluktan davet bağlantısı iste.")
                primary("Yeni istek gönder", enabled: true) { await signup.startOver() }
            default:
                heading("clock", "Onay bekliyor")
                paragraph(pending.persisted
                     ? "\(pending.username), isteğin topluluk yöneticisine iletildi. Onaylanınca hesabın oluşturulur ve topluluğa katılırsın. Bu ekran kendiliğinden yenilenir; uygulamayı kapatırsan onaydan sonra şifreni yeniden girmen yeterli."
                     : "\(pending.username), isteğin topluluk yöneticisine iletildi. Onaylanınca hesabın oluşturulur ve topluluğa katılırsın. Bu ekran kendiliğinden yenilenir.")
                if let time = requested(pending.createdAt) { Text("İstek zamanı: \(time)").font(.footnote).foregroundStyle(.secondary) }
                primary(signup.checking ? "Kontrol ediliyor…" : "Durumu yenile", enabled: !signup.checking) { await signup.check(model: model) }
                secondary("İsteği geri çek") { await signup.cancel() }
            }
        }
    }
    private func heading(_ symbol: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(Palette.accent).accessibilityHidden(true)
            Text(title).font(.title2.bold())
        }
    }
    private func paragraph(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func primary(_ title: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { HStack { Spacer(); Text(title).bold(); Spacer() }.frame(minHeight: 48) }
            .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.canvas).disabled(!enabled)
    }
    private func secondary(_ title: String, action: @escaping () async -> Void) -> some View {
        Button(role: .destructive) { Task { await action() } } label: { HStack { Spacer(); Text(title); Spacer() }.frame(minHeight: 44) }
            .buttonStyle(.bordered).disabled(signup.checking)
    }
    private func requested(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
