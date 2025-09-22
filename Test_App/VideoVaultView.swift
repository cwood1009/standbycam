import SwiftUI
import AVKit
import AVFoundation
import UIKit

struct VideoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var isProtected: Bool = false
}

enum VideoProtectionStore {
    private static let key = "ProtectedVideoFilenames"

    static func load() -> Set<String> {
        let names = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(names)
    }

    static func save(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func isProtected(url: URL) -> Bool {
        load().contains(url.lastPathComponent)
    }

    static func toggle(url: URL) {
        var set = load()
        let name = url.lastPathComponent
        if set.contains(name) {
            set.remove(name)
        } else {
            set.insert(name)
        }
        save(set)
    }

    static func remove(url: URL) {
        var set = load()
        set.remove(url.lastPathComponent)
        save(set)
    }
}

struct VideoVaultView: View {
    @State private var videos: [VideoItem] = RecordingController.listVideos().map { url in
        .init(url: url, isProtected: VideoProtectionStore.isProtected(url: url))
    }
    @State private var selected: VideoItem? = nil
    @State private var showDeleteAllConfirm = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(videos) { item in
                    Button { selected = item } label: {
                        HStack {
                            Image(systemName: "film")
                            if item.isProtected {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.url.lastPathComponent).lineLimit(1)
                                Text(modifiedDateString(item.url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(fileSizeString(item.url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button {
                            VideoProtectionStore.toggle(url: item.url)
                            refresh()
                        } label: {
                            Label(item.isProtected ? "Unprotect" : "Protect",
                                  systemImage: item.isProtected ? "lock.open" : "lock")
                        }

                        if !item.isProtected {
                            Button(role: .destructive) {
                                RecordingController.deleteVideo(at: item.url)
                                VideoProtectionStore.remove(url: item.url)
                                refresh()
                                if selected == item { selected = nil }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .onDelete(perform: onDelete)
            }
            .navigationTitle("Videos")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showDeleteAllConfirm = true } label: { Image(systemName: "trash") }
                }
            }
            .alert("Delete all videos?", isPresented: $showDeleteAllConfirm) {
                Button("Delete All", role: .destructive) {
                    for video in videos where !video.isProtected {
                        RecordingController.deleteVideo(at: video.url)
                        VideoProtectionStore.remove(url: video.url)
                    }
                    refresh()
                    selected = nil
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently remove all unprotected videos. Protected videos will be kept.")
            }
            .sheet(item: $selected) { item in
                VideoPlayerSheet(url: item.url)
            }
        }
    }

    private func onDelete(at offsets: IndexSet) {
        for index in offsets.sorted().reversed() {
            let item = videos[index]
            guard !item.isProtected else { continue }
            RecordingController.deleteVideo(at: item.url)
            VideoProtectionStore.remove(url: item.url)
        }
        refresh()
    }

    private func refresh() {
        videos = RecordingController.listVideos().map { url in
            .init(url: url, isProtected: VideoProtectionStore.isProtected(url: url))
        }
    }

    private func fileSizeString(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let megabytes = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", megabytes)
    }

    private func modifiedDateString(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct VideoPlayerSheet: View, Identifiable {
    let url: URL
    var id: URL { url }

    @State private var isFullscreen = false
    @State private var player: AVPlayer? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    ZoomablePlayerView(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView().task {
                        player = AVPlayer(url: url)
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isFullscreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(player == nil)
                }
            }
            .fullScreenCover(isPresented: $isFullscreen) {
                if let player {
                    FullScreenZoomPlayer(player: player) {
                        isFullscreen = false
                    }
                    .ignoresSafeArea()
                }
            }
            .onDisappear { player?.pause() }
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.videoGravity = .resizeAspect
    }
}

struct PlayerLayerRepresentable: UIViewRepresentable {
    typealias UIViewType = PlayerLayerView

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.player = player
    }
}

struct ZoomablePlayerView: View {
    let player: AVPlayer

    @State private var isPlaying = false
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                PlayerLayerRepresentable(player: player)
                    .overlay(Color.clear)
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
                    .simultaneousGesture(magnificationGesture(in: proxy.size))
                    .simultaneousGesture(panGesture(in: proxy.size))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { resetZoom() }
                    .onTapGesture { togglePlay() }
                    .onAppear {
                        player.play()
                        isPlaying = true
                    }

                PlayerControlsOverlay(player: player)
            }
            .animation(.easeInOut(duration: 0.18), value: scale)
            .animation(.easeInOut(duration: 0.18), value: offset)
        }
    }

    private func magnificationGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = (lastScale * value).clamped(to: minScale...maxScale)
                scale = newScale
                clampOffsetIfNeeded(in: size)
            }
            .onEnded { _ in
                lastScale = scale
                clampOffsetIfNeeded(in: size, snapIfSmall: true)
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { offset = .zero; return }
                let proposed = CGSize(width: lastOffset.width + value.translation.width,
                                      height: lastOffset.height + value.translation.height)
                offset = clampedOffset(proposed, in: size)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func resetZoom() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    private func clampedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let maxX = (size.width * (scale - 1)) / 2
        let maxY = (size.height * (scale - 1)) / 2
        let x = proposed.width.clamped(to: -maxX...maxX)
        let y = proposed.height.clamped(to: -maxY...maxY)
        return CGSize(width: x, height: y)
    }

    private func clampOffsetIfNeeded(in size: CGSize, snapIfSmall: Bool = false) {
        offset = clampedOffset(offset, in: size)
        if snapIfSmall, scale < 1.02 {
            resetZoom()
        }
    }
}

struct FullScreenZoomPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> ZoomPlayerViewController {
        let controller = ZoomPlayerViewController()
        controller.configure(with: player, onDismiss: onDismiss)
        return controller
    }

    func updateUIViewController(_ uiViewController: ZoomPlayerViewController, context: Context) { }
}

struct FullScreenPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.entersFullScreenWhenPlaybackBegins = false

        let done = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in
            onDismiss()
        })
        controller.navigationItem.rightBarButtonItem = done

        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .fullScreen
        context.coordinator.container = nav
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var container: UINavigationController?
    }
}

final class ZoomPlayerViewController: UIViewController, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let contentView = PlayerLayerView()

    private let closeButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let back10Button = UIButton(type: .system)
    private let fwd10Button = UIButton(type: .system)
    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()

    private var onDismiss: (() -> Void)?
    private var timeObserver: Any?
    private var duration: Double = 0

    func configure(with player: AVPlayer, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        contentView.player = player
    }

    deinit {
        if let observer = timeObserver {
            contentView.player?.removeTimeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.delegate = self
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        scrollView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        [closeButton, playPauseButton, back10Button, fwd10Button].forEach {
            $0.tintColor = .white
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        slider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(slider)

        currentLabel.textColor = .white
        durationLabel.textColor = .white
        currentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        [currentLabel, durationLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)

        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)

        back10Button.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        back10Button.addAction(UIAction { [weak self] _ in self?.jump(by: -10) }, for: .touchUpInside)

        fwd10Button.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        fwd10Button.addAction(UIAction { [weak self] _ in self?.jump(by: 10) }, for: .touchUpInside)

        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.addAction(UIAction { [weak self] _ in self?.sliderChanged() }, for: .valueChanged)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            playPauseButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            back10Button.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            back10Button.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -28),

            fwd10Button.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            fwd10Button.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 28),

            slider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: playPauseButton.topAnchor, constant: -14),

            currentLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            currentLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -6),

            durationLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            durationLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -6)
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        if let item = contentView.player?.currentItem, item.duration.seconds.isFinite {
            duration = item.duration.seconds
        }
        addTimeObserver()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        contentView.player?.play()
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
        contentView.center = CGPoint(
            x: scrollView.contentSize.width * 0.5 + offsetX,
            y: scrollView.contentSize.height * 0.5 + offsetY
        )
    }

    private func addTimeObserver() {
        guard timeObserver == nil, let player = contentView.player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) {
            [weak self] time in
            guard let self else { return }
            let current = time.seconds
            if let duration = player.currentItem?.duration.seconds, duration.isFinite {
                self.duration = duration
            }
            slider.minimumValue = 0
            slider.maximumValue = Float(self.duration > 0 ? self.duration : 1)
            slider.setValue(Float(current), animated: false)
            currentLabel.text = formatTime(current)
            durationLabel.text = formatTime(self.duration)
        }
    }

    private func sliderChanged() {
        let target = Double(slider.value)
        seek(to: target)
    }

    private func togglePlay() {
        guard let player = contentView.player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            player.play()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
    }

    private func jump(by seconds: Double) {
        guard let player = contentView.player else { return }
        let now = player.currentTime().seconds
        seek(to: now + seconds)
    }

    private func seek(to seconds: Double) {
        guard let player = contentView.player else { return }
        let duration = duration
        let clamped = max(0, min(seconds, duration.isFinite ? duration : seconds))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let newScale: CGFloat = scrollView.zoomScale < 2.0 ? 2.0 : 1.0
        let point = gesture.location(in: contentView)
        var rect = CGRect.zero
        rect.size.width = scrollView.bounds.size.width / newScale
        rect.size.height = scrollView.bounds.size.height / newScale
        rect.origin.x = point.x - rect.size.width / 2.0
        rect.origin.y = point.y - rect.size.height / 2.0
        scrollView.zoom(to: rect, animated: true)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct PlayerControlsOverlay: View {
    let player: AVPlayer

    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var isPlaying: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(formatTime(current)).font(.caption).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                Slider(
                    value: $current,
                    in: 0...(duration > 0 ? duration : 0.1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { seek(to: current) }
                    }
                )
                Text(formatTime(duration)).font(.caption).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 28) {
                Button { jump(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .font(.title2)
                .foregroundStyle(.white)

                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .font(.title)
                .foregroundStyle(.white)

                Button { jump(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .font(.title2)
                .foregroundStyle(.white)
            }
            .padding(.top, 6)
        }
        .padding()
        .background(Color.black.opacity(0.35).blur(radius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 24)
        .onAppear(perform: subscribe)
        .onDisappear(perform: teardown)
    }

    private func subscribe() {
        duration = player.currentItem?.duration.seconds ?? 0
        NotificationCenter.default.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: player.currentItem, queue: .main) { _ in
            if let seconds = player.currentItem?.asset.duration.seconds, seconds.isFinite {
                duration = seconds
            }
        }

        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            guard !isScrubbing else { return }
            current = time.seconds
            isPlaying = player.timeControlStatus == .playing
            if let seconds = player.currentItem?.duration.seconds, seconds.isFinite {
                duration = seconds
            }
        }
        timeObserver = observer
    }

    private func teardown() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func jump(by seconds: Double) {
        let now = player.currentTime().seconds
        seek(to: now + seconds)
    }

    private func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = max(0, min(seconds, duration))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        current = clamped
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
