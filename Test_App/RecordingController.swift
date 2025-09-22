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
        guard let connection = movieOutput.connection(with: .video) else { return }

        if usingWideFrontSensor {
            applyForcedLandscapeIfNeeded(on: connection)
        } else {
            applyPortraitOrientation(on: connection)
        }

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
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

    private func applyPortraitOrientation(on connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    private func applyForcedLandscapeIfNeeded(on connection: AVCaptureConnection) {
        guard usingWideFrontSensor else { return }

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
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

    @available(iOS 18.0, *)
    private func findAndConfigureSmartFramingDevice() -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: .front
        )

        guard let device = discoverySession.devices.first,
              let format = device.formats.first(where: { $0.isSmartFramingSupported }) else {
            return nil
        }

        if device.activeFormat.isSmartFramingSupported {
            return device
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            return device
        } catch {
            return nil
        }
    }

    @available(iOS 18.0, *)
    private func configureSmartFramingMonitor(for device: AVCaptureDevice) {
        guard let monitor = device.smartFramingMonitor else { return }

        if monitor.supportedFramings.contains(.ratio16x9) {
            monitor.enabledFramings = [.ratio16x9]
        } else {
            monitor.enabledFramings = monitor.supportedFramings
        }

        monitor.setDynamicAspectRatio(.aspectRatio16x9)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = 1.0
        } catch {
            print("Unable to set zoom for smart framing: \(error)")
        }
    }

    private func buildCaptureSession(addAudio: Bool) -> Bool {
        guard !isConfigured else { return true }

        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        } else {
            session.sessionPreset = .high
        }

        session.beginConfiguration()
        usingWideFrontSensor = false

        var smartFramingEnabled = false
        let videoDevice: AVCaptureDevice

        if #available(iOS 18.0, *), let smartDevice = findAndConfigureSmartFramingDevice() {
            videoDevice = smartDevice
            smartFramingEnabled = true
        } else if let defaultDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            videoDevice = defaultDevice
        } else {
            session.commitConfiguration()
            return false
        }

        do {
            try videoDevice.lockForConfiguration()
            defer { videoDevice.unlockForConfiguration() }

            var detectedWideSensor = false

            if smartFramingEnabled {
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                detectedWideSensor = true
            } else if let preferredFormat = bestLandscapeFrontFormat(for: videoDevice) {
                videoDevice.activeFormat = preferredFormat
                videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                detectedWideSensor = isNewWideFrontSensorFormat(preferredFormat)
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
                detectedWideSensor = isNewWideFrontSensorFormat(fallback)
            }

            usingWideFrontSensor = smartFramingEnabled || detectedWideSensor
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
        if #available(iOS 18.0, *), smartFramingEnabled {
            configureSmartFramingMonitor(for: videoDevice)
        }
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
