import SwiftUI
import AVFoundation
import AVKit
import AVFAudio
import UIKit

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

    func startRecording() {
        ensureSessionReady { [weak self] ready in
            guard let self = self, ready else { return }
            self.sessionQueue.async {
                guard !self.movieOutput.isRecording else { return }

                if let connection = self.movieOutput.connection(with: .video),
                   connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }

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
        }
    }

    // MARK: - Orientation Handling

    private func applyCurrentOrientation() {
        if usingWideFrontSensor {
            applyForcedLandscapeIfNeeded()
            return
        }

        guard let connection = movieOutput.connection(with: .video) else { return }

        if #available(iOS 17.0, *) {
            let orientation = UIDevice.current.orientation
            if orientation.isValidInterfaceOrientation,
               let videoOrientation = videoOrientation(for: orientation) {
                let angle: CGFloat
                switch videoOrientation {
                case .portrait: angle = 90
                case .portraitUpsideDown: angle = 270
                case .landscapeRight: angle = 0
                case .landscapeLeft: angle = 180
                @unknown default: angle = 90
                }

                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        } else if connection.isVideoOrientationSupported {
            let orientation = UIDevice.current.orientation
            if orientation.isValidInterfaceOrientation,
               let videoOrientation = videoOrientation(for: orientation) {
                connection.videoOrientation = videoOrientation
            }
        }

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }

    private func videoOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }

    private func startObservingOrientationChanges() {
        DispatchQueue.main.async {
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
            if let observer = self.orientationObserver {
                NotificationCenter.default.removeObserver(observer)
                self.orientationObserver = nil
            }

            if UIDevice.current.isGeneratingDeviceOrientationNotifications {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
    }

    private func applyForcedLandscapeIfNeeded() {
        guard usingWideFrontSensor, let connection = movieOutput.connection(with: .video) else { return }

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }

    // MARK: - Session Lifecycle

    private func ensureSessionReady(completion: @escaping (Bool) -> Void) {
        if isConfigured {
            DispatchQueue.main.async { completion(true) }
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            self.cameraAuthorized = granted

            guard granted else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let requestMic: (@escaping (Bool) -> Void) -> Void = { done in
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { done($0) }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { done($0) }
                }
            }

            requestMic { micGranted in
                self.micAuthorized = micGranted
                self.sessionQueue.async {
                    self.configureAudioSession(enable: micGranted)
                    let configured = self.buildCaptureSession(addAudio: micGranted)
                    if configured {
                        self.session.startRunning()
                    }
                    DispatchQueue.main.async { completion(configured) }
                }
            }
        }
    }

    private func configureAudioSession(enable: Bool) {
        guard enable else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    private func buildCaptureSession(addAudio: Bool) -> Bool {
        guard !isConfigured else { return true }

        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        session.beginConfiguration()
        usingWideFrontSensor = false

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            session.commitConfiguration()
            return false
        }

        do {
            try videoDevice.lockForConfiguration()

            if let preferredFormat = bestLandscapeFrontFormat(for: videoDevice) {
                videoDevice.activeFormat = preferredFormat
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                usingWideFrontSensor = isNewWideFrontSensorFormat(preferredFormat)
            } else if let fallback = videoDevice.formats
                .filter({ format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let supports30 = format.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate
                    }
                    return supports30 && max(dimensions.width, dimensions.height) >= 3840
                })
                .sorted(by: { lhs, rhs in
                    let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                    let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                    return (lhsDims.width * lhsDims.height) > (rhsDims.width * rhsDims.height)
                })
                .first {
                videoDevice.activeFormat = fallback
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                usingWideFrontSensor = isNewWideFrontSensorFormat(fallback)
            }

            videoDevice.unlockForConfiguration()
        } catch {
            usingWideFrontSensor = false
            session.commitConfiguration()
            return false
        }

        guard let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(videoInput)

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
        return true
    }

    private func teardownSession() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()

        isConfigured = false
        usingWideFrontSensor = false

        if micAuthorized {
            do {
                try AVAudioSession.sharedInstance().setActive(false)
            } catch { }
        }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let error {
            print("Recording error: \(error)")
            try? FileManager.default.removeItem(at: outputFileURL)
        }

        DispatchQueue.main.async { self.isRecording = false }

        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.teardownSession()
            self.stopObservingOrientationChanges()
        }
    }

    // MARK: - Helpers

    private func isNewWideFrontSensorFormat(_ format: AVCaptureDevice.Format) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let candidates: [(Int32, Int32)] = [
            (4032, 2268), // iPhone 17 Pro landscape-native front sensor
            (3840, 2160),
            (3264, 1836)
        ]
        return candidates.contains { candidate in
            candidate.0 == dimensions.width && candidate.1 == dimensions.height
        }
    }

    private func bestLandscapeFrontFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= dimensions.height else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate
            }
        }

        return formats.sorted { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsPixels = Int(lhsDims.width) * Int(lhsDims.height)
            let rhsPixels = Int(rhsDims.width) * Int(rhsDims.height)
            return lhsPixels > rhsPixels
        }.first
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    static func listVideos() -> [URL] {
        let directory = documentsDirectory()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        return contents
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    static func deleteVideo(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAllVideos() {
        for url in listVideos() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
