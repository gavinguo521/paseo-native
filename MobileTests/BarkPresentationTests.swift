import SwiftUI
import Testing
import UIKit
@testable import PaseoKit
@testable import Paseo

@Suite(.serialized) @MainActor struct BarkPresentationTests {
    @Test func barkRemainsPresentedAcrossFormUpdatesAndOnlyClosesItsOwnSheet() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let model = try SidebarTestFixture.model(projects: 1)
        let host = try #require(model.hosts.first)
        let state = PresentationState()
        let controller = UIHostingController(rootView: SettingsFixture(state: state, model: model))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        state.showSettings = true
        try await waitUntil { controller.presentedViewController?.view.window != nil }
        let settings = try #require(controller.presentedViewController)
        // Settings is a scrolling Form. Its rows can be recycled while the
        // nested sheet appears, so presentation must belong to the page.
        for _ in 0..<2 {
            state.barkHost = host
            try await waitUntil { settings.presentedViewController?.view.window != nil }
            let bark = try #require(settings.presentedViewController)
            // This isolated host has no connection: status loading completes
            // with an error, which must stay on the configuration page.
            host.label += " 更新"
            if let scrollView = scrollView(in: settings.view) {
                scrollView.setContentOffset(CGPoint(x: 0, y: max(0, scrollView.contentSize.height - scrollView.bounds.height)), animated: false)
            }
            try await Task.sleep(for: .seconds(1))
            #expect(controller.presentedViewController === settings)
            #expect(settings.presentedViewController === bark)
            #expect(state.showSettings)
            #expect(state.barkHost === host)
            #expect(bark.view.window != nil)

            state.barkHost = nil
            try await waitUntil { settings.presentedViewController == nil }
            #expect(controller.presentedViewController === settings)
            #expect(state.showSettings)
        }
        state.showSettings = false
        try await waitUntil { controller.presentedViewController == nil }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition(), "Expected presentation transition did not finish")
        // Wait for the actual UIKit transition before changing another sheet.
        try await Task.sleep(for: .milliseconds(500))
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}

@MainActor @Observable private final class PresentationState {
    var showSettings = false
    var barkHost: HostStore?
}

private struct SettingsFixture: View {
    @Bindable var state: PresentationState
    let model: AppModel

    var body: some View {
        Color.clear
            .sheet(isPresented: $state.showSettings) {
                PreferencesView(configuringBarkHost: $state.barkHost).environment(model)
            }
    }
}
