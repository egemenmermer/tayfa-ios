import SwiftUI

/// Cold launch without a reachable server while a session is saved (B5): the person is still
/// signed in, so this offers a retry (also automatic on network return) instead of the login form.
struct RestoreRetryView: View {
    @ObservedObject var model: RoomsModel
    @State private var confirmingSignOut = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("Tayfa").font(.title2.weight(.black)).tracking(5)
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Sunucuya ulaşılamıyor").font(.title3.bold()).multilineTextAlignment(.center)
                Text("Oturumun bu cihazda kayıtlı. Bağlantı gelince otomatik olarak yeniden denenecek.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.restoreProblem { Notice(text: problem) }
            Button {
                Task { await model.retryRestore() }
            } label: {
                HStack { Spacer(); if model.restoreRetrying { ProgressView() }; Text(model.restoreRetrying ? "Bağlanılıyor…" : "Tekrar dene").bold(); Spacer() }.frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.canvas)
            .disabled(model.restoreRetrying).accessibilityIdentifier("restore.retry")
            Button("Çıkış yap", role: .destructive) { confirmingSignOut = true }
                .font(.footnote).frame(minHeight: 44).accessibilityIdentifier("restore.signOut")
            Spacer()
        }
        .padding(28).frame(maxWidth: 480).frame(maxWidth: .infinity)
        .confirmationDialog("Bu cihazda oturum kapatılsın mı?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Çıkış yap", role: .destructive) { Task { await model.logout() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Sunucuya ulaşıldığında oturum orada da kapatılır.")
        }
    }
}
