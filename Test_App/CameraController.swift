import AVFoundation
import Photos

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
private let session = AVCaptureSession()
private var photoOutput = AVCapturePhotoOutput()
private var deviceInput: AVCaptureDeviceInput?

@Published var isTorchOn: Bool = false
@Published var maxZoomFactor: CGFloat = 5.0

func configure() {
Task { @MainActor in
let status = await AVCaptureDevice.requestAccess(for: .video)
guard status else { return }
setupSession()
}
}

private func setupSession() {
session.beginConfiguration()
session.sessionPreset = .photo

// default camera: back wide angle
guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
do {
let input = try AVCaptureDeviceInput(device: device)
if session.canAddInput(input) { session.addInput(input); deviceInput = input }
} catch { print("Camera input error: \(error)") }

if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
updateMaxZoom()

session.commitConfiguration()
session.startRunning()
}

func switchCamera() {
guard let currentInput = deviceInput else { return }
let newPosition: AVCaptureDevice.Position = (currentInput.device.position == .back) ? .front : .back
guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else { return }
do {
let newInput = try AVCaptureDeviceInput(device: newDevice)
session.beginConfiguration()
session.removeInput(currentInput)
if session.canAddInput(newInput) { session.addInput(newInput); deviceInput = newInput }
session.commitConfiguration()
updateMaxZoom()
} catch { print("Switch camera error: \(error)") }
}

func toggleTorch() {
guard let device = deviceInput?.device, device.hasTorch else { return }
do {
try device.lockForConfiguration()
device.torchMode = device.torchMode == .on ? .off : .on
isTorchOn = (device.torchMode == .on)
device.unlockForConfiguration()
} catch { print("Torch error: \(error)") }
}

func setZoom(factor: CGFloat) {
guard let device = deviceInput?.device else { return }
let clamped = min(max(1.0, factor), device.activeFormat.videoMaxZoomFactor)
do {
try device.lockForConfiguration()
device.videoZoomFactor = clamped
device.unlockForConfiguration()
} catch { print("Zoom error: \(error)") }
}

func capturePhoto() {
let settings = AVCapturePhotoSettings()
if deviceInput?.device.isFlashAvailable == true { settings.flashMode = .auto }
photoOutput.capturePhoto(with: settings, delegate: self)
}

private func updateMaxZoom() {
if let device = deviceInput?.device { maxZoomFactor = min(10.0, device.activeFormat.videoMaxZoomFactor) }
}

// MARK: - AVCapturePhotoCaptureDelegate
func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
if let error = error { print("Capture error: \(error)"); return }
guard let data = photo.fileDataRepresentation() else { return }
saveToLibrary(data: data)
}

private func saveToLibrary(data: Data) {
PHPhotoLibrary.requestAuthorization { status in
guard status == .authorized || status == .limited else { return }
PHPhotoLibrary.shared().performChanges({
PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
}, completionHandler: { success, error in
if let error = error { print("Save error: \(error)") }
if success { print("Saved to Photos") }
})
}
}
}
