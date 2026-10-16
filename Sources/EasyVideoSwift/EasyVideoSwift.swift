import SwiftUI
@preconcurrency import AVFoundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 一个开箱即用的视频播放器。
///
/// 视频文件需要加入宿主 App target，以便被打包到 App Bundle 中。
/// 播放器容器与视频画面未覆盖的区域均保持透明，不会绘制默认底色。
///
///     Video("intro.mp4")
///     Video("intro", loop: true)
///     Video("intro", pingPong: true)
public struct Video: View {
    /// 视频播放完成后的行为。
    public enum PlaybackMode: Sendable {
        /// 播放一次后停在最后一帧。
        case once
        /// 播放到最后一帧后从头开始循环。
        case loop
        /// 正向播放到最后一帧，再反向播放到第一帧并持续循环。
        case pingPong
    }

    @StateObject private var playback: VideoPlaybackController

    /// 创建一个视频播放器。
    ///
    /// - Parameters:
    ///   - resourceName: 视频文件名，可以带或不带扩展名。
    ///   - loop: 是否从头循环播放。`once` 为 `true` 时优先使用一次播放。
    ///   - once: 是否只播放一次。默认情况下视频也只播放一次。
    ///   - pingPong: 是否启用来回播放模式。启用后会自动循环。
    ///   - autoplay: View 出现后是否自动播放。
    public init(
        _ resourceName: String,
        loop: Bool = false,
        once: Bool = false,
        pingPong: Bool = false,
        autoplay: Bool = true
    ) {
        let mode: PlaybackMode
        if once {
            mode = .once
        } else if pingPong {
            mode = .pingPong
        } else if loop {
            mode = .loop
        } else {
            mode = .once
        }

        _playback = StateObject(
            wrappedValue: VideoPlaybackController(
                resourceName: resourceName,
                mode: mode,
                autoplay: autoplay
            )
        )
    }

    /// 使用明确播放模式创建视频播放器。
    public init(
        _ resourceName: String,
        mode: PlaybackMode,
        autoplay: Bool = true
    ) {
        _playback = StateObject(
            wrappedValue: VideoPlaybackController(
                resourceName: resourceName,
                mode: mode,
                autoplay: autoplay
            )
        )
    }

    public var body: some View {
        Group {
            if let player = playback.player {
                TransparentVideoSurface(player: player)
            } else {
                Text(playback.errorMessage ?? "无法加载视频")
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .onAppear {
            playback.start()
        }
        .onDisappear {
            playback.stop()
        }
    }
}

@MainActor
private final class VideoPlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?

    private let mode: Video.PlaybackMode
    private let autoplay: Bool
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var isReversing = false

    init(resourceName: String, mode: Video.PlaybackMode, autoplay: Bool) {
        self.mode = mode
        self.autoplay = autoplay

        guard let url = VideoResourceLocator.url(for: resourceName) else {
            errorMessage = "找不到视频资源：\(resourceName)"
            return
        }

        player = AVPlayer(url: url)
        observePlaybackEnd()
    }

    func start() {
        guard autoplay, let player else { return }

        if mode == .pingPong {
            installTimeObserverIfNeeded()
        }
        player.play()
    }

    func stop() {
        player?.pause()
        removeTimeObserver()
        isReversing = false
    }

    private func observePlaybackEnd() {
        guard let item = player?.currentItem else { return }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnd()
            }
        }
    }

    private func handlePlaybackEnd() {
        guard let player else { return }

        switch mode {
        case .once:
            player.pause()
        case .loop:
            player.seek(to: .zero) { [weak player] _ in
                Task { @MainActor [weak player] in
                    player?.play()
                }
            }
        case .pingPong:
            beginReversePlayback()
        }
    }

    private func beginReversePlayback() {
        guard let player,
              let item = player.currentItem,
              item.duration.isNumeric,
              item.duration.seconds > 0 else {
            return
        }

        isReversing = true
        let end = max(0, item.duration.seconds - 0.001)
        let endTime = CMTime(seconds: end, preferredTimescale: 600)

        player.seek(to: endTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            Task { @MainActor [weak player] in
                player?.playImmediately(atRate: -1)
            }
        }
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil, let player else { return }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.checkReverseBoundary(time)
            }
        }
    }

    private func checkReverseBoundary(_ time: CMTime) {
        guard isReversing, time.isNumeric, time.seconds <= 0.05, let player else { return }

        isReversing = false
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            Task { @MainActor [weak player] in
                player?.playImmediately(atRate: 1)
            }
        }
    }

    private func removeTimeObserver() {
        guard let timeObserver, let player else { return }
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }
}

#if os(macOS)
private struct TransparentVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> TransparentPlayerView {
        TransparentPlayerView(player: player)
    }

    func updateNSView(_ nsView: TransparentPlayerView, context: Context) {
        nsView.player = player
    }
}

private final class TransparentPlayerView: NSView {
    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }

    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("TransparentPlayerView 的 layer 必须是 AVPlayerLayer")
        }
        return playerLayer
    }

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer = AVPlayerLayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
    }

    required init?(coder: NSCoder) {
        nil
    }
}
#else
private struct TransparentVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TransparentPlayerView {
        TransparentPlayerView(player: player)
    }

    func updateUIView(_ uiView: TransparentPlayerView, context: Context) {
        uiView.player = player
    }
}

private final class TransparentPlayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }

    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("TransparentPlayerView 的 layer 必须是 AVPlayerLayer")
        }
        return playerLayer
    }

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
    }

    required init?(coder: NSCoder) {
        nil
    }
}
#endif

private enum VideoResourceLocator {
    static func url(for resourceName: String) -> URL? {
        if let fileURL = URL(string: resourceName), fileURL.isFileURL {
            return fileURL
        }

        let path = resourceName as NSString
        let extensionName = path.pathExtension
        let baseName = path.deletingPathExtension

        if !extensionName.isEmpty,
           let url = Bundle.main.url(forResource: baseName, withExtension: extensionName) {
            return url
        }

        if extensionName.isEmpty,
           let url = Bundle.main.url(forResource: resourceName, withExtension: nil) {
            return url
        }

        for candidateExtension in ["mp4", "mov", "m4v"] {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: candidateExtension) {
                return url
            }
        }

        return nil
    }
}
