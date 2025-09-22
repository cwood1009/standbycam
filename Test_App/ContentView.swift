// MARK: - ContentView.swift
import SwiftUI
import AVFoundation
import Photos
import AVKit
import AVFAudio
import Foundation
import LocalAuthentication
import UIKit

// MARK: - Simple URL Identifiable
extension URL: @retroactive Identifiable {
    public var id: URL { self }
}

// MARK: - Vault Auth
enum VaultAuthError: Error {
    case faceIDNotAvailable
    case authFailed
}

struct VaultAuth {
    static func authenticate(completion: @escaping (Result<Void, VaultAuthError>) -> Void) {
        let ctx = LAContext()
        ctx.localizedReason = "Unlock Vault"
        ctx.localizedFallbackTitle = "" // hides “Enter Passcode”

        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            completion(.failure(.faceIDNotAvailable)); return
        }
        if #available(iOS 11.0, *), ctx.biometryType != .faceID {
            completion(.failure(.faceIDNotAvailable)); return
        }

        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Vault") { success, _ in
            DispatchQueue.main.async { success ? completion(.success(())) : completion(.failure(.authFailed)) }
        }
    }
}

// MARK: - Recording Controller (lazy session; no camera unless recording)
final class RecordingController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var isRecording = false

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "standbycam.session.queue")

    private var isConfigured = false
    private var cameraAuthorized = false
    private var micAuthorized = false

    private var orientationObserver: NSObjectProtocol?
    private var usingWideFrontSensor = false

    // Intentionally no eager configure call. We build/start only when recording.

    // PUBLIC API
    func startRecording() {
        ensureSessionReady { [weak self] ready in
            guard let self = self, ready else { return }
            self.sessionQueue.async {
                guard !self.movieOutput.isRecording else { return }

                if let conn = self.movieOutput.connection(with: .video) {
                    if conn.isVideoMirroringSupported { conn.isVideoMirrored = true } // mirror front cam like selfie
                }

                // Follow device orientation for all devices
                self.applyCurrentOrientation()
                self.startObservingOrientationChanges()

                let url = Self.documentsDirectory()
                    .appendingPathComponent("standbycam_\(Int(Date().timeIntervalSince1970)).mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async { self.isRecording = true }
            }
        }
    }

    func stopRecording() {
        sessionQueue.async {
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
            self.stopObservingOrientationChanges()
            // isRecording flips to false in delegate
        }
    }

    // MARK: - Orientation Handling
    private func videoOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight   // front camera mirroring alignment
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }

    private func applyCurrentOrientation() {
        guard let conn = movieOutput.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            // Prefer explicit rotation angle if supported
            let orientation = UIDevice.current.orientation
            if orientation.isValidInterfaceOrientation {
                if let vo = videoOrientation(for: orientation) {
                    // Map to degrees for rotation angle
                    let angle: CGFloat
                    switch vo {
                    case .portrait: angle = 90
                    case .portraitUpsideDown: angle = 270
                    case .landscapeRight: angle = 0
                    case .landscapeLeft: angle = 180
                    @unknown default: angle = 90
                    }
                    if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
                }
            }
        } else if conn.isVideoOrientationSupported {
            let orientation = UIDevice.current.orientation
            if orientation.isValidInterfaceOrientation, let vo = videoOrientation(for: orientation) {
                conn.videoOrientation = vo
            }
        }
        if conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
    }

    private func startObservingOrientationChanges() {
        DispatchQueue.main.async {
            // Avoid double-begin if already generating
            if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
            self.orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.sessionQueue.async { self.applyCurrentOrientation() }
            }
        }
    }

    private func stopObservingOrientationChanges() {
        DispatchQueue.main.async {
            if let obs = self.orientationObserver {
                NotificationCenter.default.removeObserver(obs)
                self.orientationObserver = nil
            }
            if UIDevice.current.isGeneratingDeviceOrientationNotifications {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
    }

    /// Heuristic for identifying the new wide front sensor formats that require a fixed landscape lock.
    /// Replace the dimensions below with the exact known formats for your target device(s).
    /// This is intentionally conservative so most devices continue to follow device orientation.
    private func isNewWideFrontSensorFormat(_ format: AVCaptureDevice.Format) -> Bool {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        // TODO: Update these to the exact dimensions of the new wide front sensor formats you want to lock.
        // Examples shown as placeholders; keep this list tight to avoid affecting other devices.
        let candidates: [(Int32, Int32)] = [
            (3840, 2160), // 4K landscape-native
            (3264, 1836)  // example wide aspect (placeholder)
        ]
        return candidates.contains { $0.0 == dims.width && $0.1 == dims.height }
    }

    private func bestLandscapeFrontFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        // Prefer formats that are landscape-native (width >= height) and high resolution (~4K)
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports30 = format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate }
            return supports30 && Int(dims.width) >= Int(dims.height) && max(dims.width, dims.height) >= 3840
        }
        if let top = candidates.sorted(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let pa = Int(da.width) * Int(da.height)
            let pb = Int(db.width) * Int(db.height)
            return pa > pb
        }).first {
            return top
        }
        // Fallback: any landscape-native high-res >= 1080p
        let fallback = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports30 = format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate }
            return supports30 && Int(dims.width) >= Int(dims.height) && max(dims.width, dims.height) >= 1920
        }.sorted { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let pa = Int(da.width) * Int(da.height)
            let pb = Int(db.width) * Int(db.height)
            return pa > pb
        }.first
        return fallback
    }

    private func applyForcedLandscapeIfNeeded() {
        guard usingWideFrontSensor, let conn = movieOutput.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            // Force landscape-right angle (0°) if supported
            if conn.isVideoRotationAngleSupported(0) {
                conn.videoRotationAngle = 0
            }
        } else if conn.isVideoOrientationSupported {
            // For front camera, landscapeRight typically aligns with 0°
            conn.videoOrientation = .landscapeRight
        }
        if conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
    }

    // FILE HELPERS
    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    static func listVideos() -> [URL] {
        let dir = documentsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    // INTERNALS
    /// Request permissions and lazily build/start the session only when needed.
    private func ensureSessionReady(completion: @escaping (Bool) -> Void) {
        if isConfigured {
            completion(true); return
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] camGranted in
            guard let self = self else { completion(false); return }
            self.cameraAuthorized = camGranted
            guard camGranted else { completion(false); return }

            let askMic: (@escaping (Bool)->Void) -> Void = { done in
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { done($0) }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { done($0) }
                }
            }

            askMic { micGranted in
                self.micAuthorized = micGranted
                self.sessionQueue.async {
                    self.configureAudioSession(enable: micGranted)
                    self.buildCaptureSession(addAudio: micGranted)
                    self.session.startRunning()
                    completion(true)
                }
            }
        }
    }

    private func configureAudioSession(enable: Bool) {
        guard enable else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try audio.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    private func buildCaptureSession(addAudio: Bool) {
        guard !isConfigured else { return }

        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        session.beginConfiguration()

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            session.commitConfiguration(); return
        }
        // Prefer a high-quality format if available, but do not force landscape behavior
        var selectedFormat: AVCaptureDevice.Format?
        if let wide = bestLandscapeFrontFormat(for: videoDevice) {
            selectedFormat = wide
        }
        usingWideFrontSensor = false

        do {
            try videoDevice.lockForConfiguration()
            if let fmt = selectedFormat {
                videoDevice.activeFormat = fmt
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            } else {
                // Previous best-effort: prefer ~4K 30fps format if available
                if let best = videoDevice.formats
                    .filter({ format in
                        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let supports30 = format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate }
                        return supports30 && max(dims.width, dims.height) >= 3840
                    })
                    .sorted(by: { a, b in
                        let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                        let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                        return (da.width * da.height) > (db.width * db.height)
                    })
                    .first
                {
                    videoDevice.activeFormat = best
                    videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                }
            }
            videoDevice.unlockForConfiguration()
        } catch {
            usingWideFrontSensor = false
        }

        guard let videoInput = try? AVCaptureDeviceInput(device: videoDevice), session.canAddInput(videoInput) else {
            session.commitConfiguration(); return
        }
        session.addInput(videoInput)

        // Optional audio input
        if addAudio,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()
        isConfigured = true
    }

    /// Completely stop and tear down the session so the green dot disappears.
    private func teardownSession() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        isConfigured = false

        if micAuthorized {
            do { try AVAudioSession.sharedInstance().setActive(false) } catch { }
        }
    }

    // DELEGATE
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let error = error {
            print("Recording error: \(error)")
            try? FileManager.default.removeItem(at: outputFileURL)
        }
        DispatchQueue.main.async { self.isRecording = false }

        // Stop and fully release the camera/mic immediately after recording
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.teardownSession()
            self.stopObservingOrientationChanges()
        }
    }

    // MARK: - Static helpers (for Vault view)
    static func deleteVideo(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAllVideos() {
        for u in listVideos() { try? FileManager.default.removeItem(at: u) }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var recorder = RecordingController()
    @State private var bgImage: UIImage? = nil
    @State private var use24h = false
    @State private var showDate = true
    @Environment(\.scenePhase) var scenePhase
    @State private var showVault = false

    var body: some View {
        ZStack {
            FancyBackground(image: bgImage)

            // Time pinned to top
            ClockView(use24h: use24h, showDate: showDate, isRecording: recorder.isRecording)
                .padding(.horizontal, 0)
                .padding(.top, 80)
                .safeAreaPadding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Tiny REC HUD (kept empty for now; you can add a red dot if desired)
            if recorder.isRecording {
                HStack(spacing: 1) { }
                    .padding(1)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.red.opacity(0.01), lineWidth: 0.1))
                    .padding(.top, 22)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // Five-tap = open vault
        .onTapGesture(count: 5) {
            VaultAuth.authenticate { result in
                switch result {
                case .success: showVault = true
                case .failure: showVault = false
                }
            }
        }
        // Single tap = toggle recording
        .onTapGesture {
            recorder.isRecording ? recorder.stopRecording() : recorder.startRecording()
        }
        // Use single-parameter onChange signature
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                // Wipe sensitive state, sign out, blank the screen, etc.
                exit(0)
            }
        }
        // NOTE: No eager camera/mic setup on appear (prevents green dot when idle)
        //.onAppear { /* no configureSession */ }

        .sheet(isPresented: $showVault) {
            VideoVaultView()
                .presentationDragIndicator(.hidden)
        }
        .statusBar(hidden: true)
    }
}

// MARK: - Vault list / player

struct VideoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var isProtected: Bool = false
}

fileprivate enum VideoProtectionStore {
    private static let key = "ProtectedVideoFilenames"

    static func load() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr)
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
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
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
                            Label(item.isProtected ? "Unprotect" : "Protect", systemImage: item.isProtected ? "lock.open" : "lock")
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
                    // Delete only unprotected videos
                    for v in videos where !v.isProtected {
                        RecordingController.deleteVideo(at: v.url)
                        VideoProtectionStore.remove(url: v.url)
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
        for i in offsets.sorted().reversed() {
            let item = videos[i]
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
        let b = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let mb = Double(b) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    private func modifiedDateString(_ url: URL) -> String {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

import AVKit

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
                        self.player = AVPlayer(url: url)
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFullscreen = true
                    } label: {
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

// A UIView that hosts an AVPlayerLayer
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
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
    typealias UIViewType = PlayerLayerView   // 👈 explicit

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.player = player
    }
}

struct ZoomablePlayerView: View {
    let player: AVPlayer

    // Playback
    @State private var isPlaying = false

    // Zoom / Pan state
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
                    .overlay(Color.clear) // keeps gestures
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
                    // Use simultaneousGesture so SwiftUI accepts both
                    .simultaneousGesture(magnificationGesture(in: proxy.size))
                    .simultaneousGesture(panGesture(in: proxy.size))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { resetZoom() }
                    .onTapGesture { togglePlay() }
                    .onAppear {
                        player.play()
                        isPlaying = true
                    }

                // Scrubber + ±10s + play/pause
                PlayerControlsOverlay(player: player)
            }
            .animation(.easeInOut(duration: 0.18), value: scale)
            .animation(.easeInOut(duration: 0.18), value: offset)
        }
    }

    // MARK: - Gestures

    private func magnificationGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let new = (lastScale * value).clamped(to: minScale...maxScale)
                scale = new
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

    // MARK: - Helpers

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
        // Clamp pan so blank space doesn't show
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

// Handy clamp
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}


struct FullScreenZoomPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> ZoomPlayerViewController {
        let vc = ZoomPlayerViewController()
        vc.configure(with: player, onDismiss: onDismiss)
        return vc
    }
    func updateUIViewController(_ uiViewController: ZoomPlayerViewController, context: Context) { }
}




struct FullScreenPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false // already full-screen
        vc.exitsFullScreenWhenPlaybackEnds = false

        // simple “Done” button
        let done = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in
            onDismiss()
        })
        vc.navigationItem.rightBarButtonItem = done

        // Embed in a nav controller to show the close button
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        context.coordinator.container = nav
        return vc
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
        if let obs = timeObserver { contentView.player?.removeTimeObserver(obs) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Scroll/zoom container
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
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        scrollView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        // Controls styling
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

        // Buttons
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)

        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)

        back10Button.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        back10Button.addAction(UIAction { [weak self] _ in self?.jump(by: -10) }, for: .touchUpInside)

        fwd10Button.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        fwd10Button.addAction(UIAction { [weak self] _ in self?.jump(by: 10) }, for: .touchUpInside)

        // Slider
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.addAction(UIAction { [weak self] _ in self?.sliderChanged() }, for: .valueChanged)

        // Layout controls
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            // Bottom transport
            playPauseButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            back10Button.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            back10Button.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -28),

            fwd10Button.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            fwd10Button.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 28),

            // Scrubber row above transport
            slider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: playPauseButton.topAnchor, constant: -14),

            currentLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            currentLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -6),

            durationLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            durationLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -6),
        ])

        // Gestures: double-tap zoom toggle
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        // Periodic updates
        if let item = contentView.player?.currentItem {
            if item.duration.seconds.isFinite { duration = item.duration.seconds }
        }
        addTimeObserver()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        contentView.player?.play()
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    }

    // MARK: - UIScrollViewDelegate
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
        contentView.center = CGPoint(x: scrollView.contentSize.width * 0.5 + offsetX,
                                     y: scrollView.contentSize.height * 0.5 + offsetY)
    }

    // MARK: - Controls
    private func addTimeObserver() {
        guard timeObserver == nil, let player = contentView.player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self else { return }
            let cur = t.seconds
            if let d = player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            self.slider.minimumValue = 0
            self.slider.maximumValue = Float(self.duration > 0 ? self.duration : 1)
            self.slider.setValue(Float(cur), animated: false)
            self.currentLabel.text = self.formatTime(cur)
            self.durationLabel.text = self.formatTime(self.duration)
        }
    }

    private func sliderChanged() {
        let target = Double(slider.value)
        seek(to: target)
    }

    private func togglePlay() {
        guard let p = contentView.player else { return }
        if p.timeControlStatus == .playing {
            p.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            p.play()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
    }

    private func jump(by seconds: Double) {
        guard let p = contentView.player else { return }
        let now = p.currentTime().seconds
        seek(to: now + seconds)
    }

    private func seek(to seconds: Double) {
        guard let p = contentView.player else { return }
        let d = duration
        let clamped = max(0, min(seconds, d.isFinite ? d : seconds))
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        let newScale: CGFloat = scrollView.zoomScale < 2.0 ? 2.0 : 1.0
        // Zoom about the tap point
        let point = gr.location(in: contentView)
        var rect = CGRect.zero
        rect.size.width = scrollView.bounds.size.width / newScale
        rect.size.height = scrollView.bounds.size.height / newScale
        rect.origin.x = point.x - rect.size.width / 2.0
        rect.origin.y = point.y - rect.size.height / 2.0
        scrollView.zoom(to: rect, animated: true)
    }

    // MARK: - Utils
    private func formatTime(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let total = Int(s.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
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
            // Scrubber
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

            // Transport
            HStack(spacing: 22) {
                Button { jump(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .buttonStyle(.plain)

                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44, weight: .semibold))
                }
                .buttonStyle(.plain)

                Button { jump(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.2)], startPoint: .bottom, endPoint: .top)
                .ignoresSafeArea(edges: .bottom)
        )
        .foregroundStyle(.white)
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    // MARK: - Internals
    private func setup() {
        // Duration
        if let d = player.currentItem?.asset.duration.seconds, d.isFinite {
            duration = d
        } else {
            // Try to load duration once ready
            NotificationCenter.default.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: player.currentItem, queue: .main) { _ in
                if let d = player.currentItem?.asset.duration.seconds, d.isFinite { duration = d }
            }
        }

        // Periodic time observer
        let obs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            guard !isScrubbing else { return }
            current = time.seconds
            isPlaying = player.timeControlStatus == .playing
            if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        }
        timeObserver = obs
    }

    private func teardown() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
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
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        current = clamped
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let total = Int(s.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}


// MARK: - Background
struct FancyBackground: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let ui = image {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .saturation(1.2)
                    .brightness(-0.05)
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.55), .black.opacity(0.85)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        RadialGradient(
                            colors: [.clear, .black.opacity(0.5)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 800
                        )
                        .blendMode(.multiply)
                    )
                    .ignoresSafeArea()
            } else {
                // TRUE BLACK
                Color.black.ignoresSafeArea()
            }
        }
    }
}

// MARK: - Clock
struct ClockView: View {
    var use24h: Bool
    var showDate: Bool
    var isRecording: Bool

    private func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = use24h ? "HH:mm" : "h:mm"
        return df.string(from: date)
    }

    private func ampmString(_ date: Date) -> String {
        guard !use24h else { return "" }
        let df = DateFormatter()
        df.locale = .current
        return df.string(from: date)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date

            VStack(spacing: 5) {
                // MAIN TIME — tall + narrow
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(timeString(now))
                        .tallSF(size: 280,
                                weight: .light,
                                rounded: false,
                                xScale: 0.95,
                                yScale: 1.56,
                                kerning: -8)

                    if !use24h {
                        Text(ampmString(now))
                            .tallSF(size: 54,
                                    weight: .semibold,
                                    rounded: true,
                                    xScale: 0.92,
                                    yScale: 1.08,
                                    kerning: -1)
                            .foregroundStyle(.white.opacity(0.50)) // dimmer AM/PM
                            .baselineOffset(6)
                    }
                }

                // DATE under the time
                if showDate {
                    Text(now.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(isRecording ? 0.45 : 0.62)) // dim idle; dimmer when recording
                        .animation(.easeInOut(duration: 0.3), value: isRecording)
                }
            }
            .padding(.horizontal, 0)
        }
    }
}

// MARK: - Helpers to ensure narrow look on all iOS versions
struct CompressedIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.fontWidth(.compressed)
        } else {
            content
        }
    }
}

// Tall, Skinny SF Style (slightly dimmed for StandBy look)
struct TallSFStyle: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let useRounded: Bool
    let xScale: CGFloat   // < 1.0 = narrower
    let yScale: CGFloat   // > 1.0 = taller
    let kerning: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight, design: useRounded ? .rounded : .default))
            .modifier(CompressedIfAvailable())
            .kerning(kerning)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.50)) // global dim
            .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
            .minimumScaleFactor(0.2)
            .lineLimit(1)
            .scaleEffect(x: xScale, y: yScale, anchor: .center)
            .modifier(NarrowFallback())
            .drawingGroup()
    }
}

extension View {
    func tallSF(size: CGFloat,
                weight: Font.Weight = .black,
                rounded: Bool = true,
                xScale: CGFloat = 0.88,
                yScale: CGFloat = 1.12,
                kerning: CGFloat = -6) -> some View {
        self.modifier(TallSFStyle(size: size,
                                  weight: weight,
                                  useRounded: rounded,
                                  xScale: xScale,
                                  yScale: yScale,
                                  kerning: kerning))
    }
}

struct NarrowFallback: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
        } else {
            content
                .scaleEffect(x: 0.86, y: 1.0, anchor: .center)
                .allowsTightening(true)
        }
    }
}
