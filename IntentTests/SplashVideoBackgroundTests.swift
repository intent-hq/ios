import AVFoundation
import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct SplashVideoBackgroundTests {
    @Test(arguments: [ScenePhase.active, .inactive, .background], [false, true])
    func motionRequiresActiveSceneWithoutReduceMotion(scene: ScenePhase, reduceMotion: Bool) {
        #expect(SplashArtView.shouldAnimate(scenePhase: scene, reduceMotion: reduceMotion, hasAnimation: true)
            == (scene == .active && !reduceMotion))
    }

    @Test func bundledVideoIsPlayableAndSilent() async throws {
        let url = try #require(Bundle.main.url(forResource: "bg_intro_dark", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 0)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func playerStartsSilentPausesAndReleasesOnRemoval() async throws {
        let url = try #require(Bundle.main.url(forResource: "bg_intro_dark", withExtension: "mp4"))
        let view = SplashVideoView(url: url)
        defer { view.stop() }
        await view.loadingTask?.value
        let player = try #require(view.playerLayer.player as? AVQueuePlayer)
        #expect(player.isMuted)
        #expect(player.rate == 0)
        #expect(view.playerLayer.videoGravity == .resizeAspectFill)
        #expect(!player.items().isEmpty)
        view.setPlaying(true)
        #expect(player.rate == 1)
        view.setPlaying(true)
        #expect(view.playerLayer.player === player)
        view.setPlaying(false)
        #expect(player.rate == 0)
        SplashVideoBackground.dismantleUIView(view, coordinator: ())
        #expect(view.playerLayer.player == nil)
        #expect(player.items().isEmpty)
        #expect(player.rate == 0)
    }

    @Test func missingOrBrokenVideoLeavesFallbackVisible() async throws {
        let missing = SplashVideoView(url: nil)
        #expect(missing.playerLayer.player == nil)
        let brokenURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("not a movie".utf8).write(to: brokenURL)
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        let broken = SplashVideoView(url: brokenURL)
        defer { broken.stop() }
        broken.setPlaying(true)
        await broken.loadingTask?.value
        #expect(broken.playerLayer.player == nil)
    }

    @Test func removalDuringLoadingDoesNotCreateAPlayerLater() async throws {
        let url = try #require(Bundle.main.url(forResource: "bg_intro_dark", withExtension: "mp4"))
        let view = SplashVideoView(url: url)
        let loading = view.loadingTask
        view.setPlaying(true)
        view.stop()
        await loading?.value
        #expect(view.playerLayer.player == nil)
    }

    /// Exercises the real SwiftUI owner: loop past the end, stop on scene changes,
    /// and release the player when switching to the light artwork.
    @Test func mountedSplashLoopsPausesAndSwapsAppearance() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(SyntheticBadgeHostScene.resolve(in: scenes))
        let controller = UIHostingController(rootView: splash())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
        try await waitUntil("splash displays video", timeout: .seconds(5)) {
            videoView(in: controller.view)?.playerLayer.isReadyForDisplay == true
        }
        let video = try #require(videoView(in: controller.view))
        let player = try #require(video.playerLayer.player)
        let firstItem = try #require(player.currentItem)
        try await waitUntil("splash loops beyond its first item", timeout: .seconds(5)) {
            player.currentItem !== firstItem && player.currentTime().seconds > 0
        }
        #expect(player.rate == 1)

        controller.rootView = splash(scenePhase: .inactive)
        try await waitUntil("inactive scene displays the first frame") {
            player.rate == 0 && player.currentTime() == .zero && video.playerLayer.isReadyForDisplay
        }
        controller.rootView = splash()
        try await waitUntil("motion resumes") { player.currentTime().seconds > 0 && player.rate == 1 }

        controller.rootView = splash(colorScheme: .light)
        try await waitUntil("light mode releases video") {
            videoView(in: controller.view) == nil && video.playerLayer.player == nil
        }
        #expect(player.rate == 0)
        controller.rootView = splash()
        try await waitUntil("dark mode creates a fresh player", timeout: .seconds(5)) {
            videoView(in: controller.view)?.playerLayer.isReadyForDisplay == true
        }
        #expect(videoView(in: controller.view)?.playerLayer.player !== player)
    }

    private func splash(
        colorScheme: ColorScheme = .dark, scenePhase: ScenePhase = .active
    ) -> some View {
        SplashArtView()
            .environment(\.colorScheme, colorScheme)
            .environment(\.scenePhase, scenePhase)
    }

    private func videoView(in view: UIView) -> SplashVideoView? {
        if let video = view as? SplashVideoView { return video }
        return view.subviews.lazy.compactMap { videoView(in: $0) }.first
    }
}
