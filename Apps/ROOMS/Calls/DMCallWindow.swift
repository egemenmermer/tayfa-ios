import UIKit
import SwiftUI

/// Shows the call screen in its own window above the app, so an incoming call is seen even over sheets
/// and the full-screen voice room. System alerts and the keyboard still sit above it.
@MainActor final class DMCallPresenter: ObservableObject {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    func show<Content: View>(_ content: Content) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        // A keyboard left open would cover the answer buttons.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        previousKey = scene.keyWindow
        window.makeKeyAndVisible()
        self.window = window
    }
    func hide() {
        guard let window else { return }
        window.isHidden = true; self.window = nil
        previousKey?.makeKey()
    }
}

/// Mounted once at the root: follows the call model and shows or hides the call window.
struct DMCallHost: View {
    @ObservedObject var calls: DMCallModel
    let model: RoomsModel
    @StateObject private var presenter = DMCallPresenter()
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: calls.call != nil && calls.expanded, initial: true) { _, visible in
                if visible { presenter.show(DMCallScreen(calls: calls, media: model.media, model: model)) } else { presenter.hide() }
            }
            .onDisappear { presenter.hide() }
    }
}
