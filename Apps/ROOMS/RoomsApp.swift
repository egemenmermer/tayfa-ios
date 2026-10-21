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
private struct LoginView: View {
    @ObservedObject var model: RoomsModel
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) { RoundedRectangle(cornerRadius: 4).fill(Palette.accent).frame(width: 13, height: 13); Text("Tayfa").font(.subheadline.weight(.black)).tracking(4) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Aynı oda.\nDaha yakın.").font(.largeTitle.bold()).tracking(-1)
                    Text("Topluluğun, sohbetlerin ve birlikte geçirdiğin zaman.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 32)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tekrar hoş geldin").font(.title3.bold())
                    VStack(spacing: 14) {
                        TextField("E-posta", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("login.email")
                        SecureField("Şifre", text: $password).textContentType(.password).accessibilityIdentifier("login.password")
                    }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    if let error = model.error { Notice(text: error) }
                    Button {
                        let submitted = password; password = ""
                        Task { await model.login(email: email, password: submitted) }
                    } label: { HStack { Spacer(); if model.busy { ProgressView() }; Text(model.busy ? "Giriş yapılıyor…" : "Giriş yap").bold(); Spacer() }.frame(minHeight: 48) }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.canvas)
                        .disabled(model.busy || email.isEmpty || password.isEmpty).accessibilityIdentifier("login.submit")
                }
                Text("Mevcut Tayfa hesabını kullan.").font(.footnote).foregroundStyle(.secondary)
            }.padding(28).padding(.top, 20).frame(maxWidth: 480)
        }.scrollDismissesKeyboard(.interactively).frame(maxWidth: .infinity)
    }
}
struct Notice: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12)).accessibilityAddTraits(.updatesFrequently) }
}
