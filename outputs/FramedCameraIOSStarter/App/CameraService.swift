import AVFoundation
import Combine
import CoreGraphics
import CoreImage
import CoreMotion
import CoreVideo
import Foundation
import Photos
import QuartzCore
import UIKit
import Vision

enum CameraAuthorizationState: Equatable {
    case checking
    case authorized
    case denied
    case restricted
    case unavailable
    case failed(String)
}

enum CaptureFormat: String, CaseIterable, Identifiable, Equatable {
    case heif
    case raw

    var id: String { rawValue }
    var title: String { self == .raw ? "RAW + HEIF" : "HEIF" }
}

struct LensPreset: Identifiable, Equatable {
    let title: String
    let factor: CGFloat

    var id: String { title }

    static let standard: [LensPreset] = [
        LensPreset(title: "0.5×", factor: 0.5),
        LensPreset(title: "1×", factor: 1),
        LensPreset(title: "2×", factor: 2),
        LensPreset(title: "5×", factor: 5)
    ]
}

struct CompositionObservation {
    /// Normalized top-left-origin bounds suitable for SwiftUI overlays.
    let subjectBounds: CGRect?
    let subjectCenter: CGPoint?
    let horizonAngle: CGFloat
    let suggestedAdjustment: String
    let detectedFace: Bool
    let detectedPose: Bool

    static let neutral = CompositionObservation(
        subjectBounds: nil,
        subjectCenter: nil,
        horizonAngle: 0,
        suggestedAdjustment: "Keep the horizon level and leave room around your subject.",
        detectedFace: false,
        detectedPose: false
    )
}

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let processedData: Data
    let rawData: Data?
    let processedFileExtension: String
    let date = Date()
}

final class CameraService: NSObject, ObservableObject {
    @Published private(set) var authorization: CameraAuthorizationState = .checking
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var capturedPhoto: CapturedPhoto?
    @Published private(set) var supportsRaw = false
    @Published private(set) var supportsProRAW = false
    @Published private(set) var hasFlash = false
    @Published private(set) var minimumZoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 1
    @Published private(set) var currentZoomFactor: CGFloat = 1
    @Published private(set) var horizonAngle: CGFloat = 0
    @Published private(set) var compositionObservation = CompositionObservation.neutral
    @Published private(set) var message: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.example.still.camera-session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "com.example.still.vision-analysis", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let motionManager = CMMotionManager()
    private var lastAnalysisTime: CFTimeInterval = 0
    private var activeInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var captureInProgress = false
    private var pendingCaptures: [Int64: PendingCapture] = [:]

    private struct PendingCapture {
        var processedData: Data?
        var rawData: Data?
        let processedFileExtension: String
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        motionManager.stopDeviceMotionUpdates()
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            DispatchQueue.main.async { self.authorization = .checking }
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    DispatchQueue.main.async { self.authorization = .denied }
                    return
                }
                self.configureAndStart()
            }
        case .denied:
            DispatchQueue.main.async { self.authorization = .denied }
        case .restricted:
            DispatchQueue.main.async { self.authorization = .restricted }
        @unknown default:
            DispatchQueue.main.async { self.authorization = .unavailable }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func setZoomFactor(_ requestedFactor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            let factor = min(max(requestedFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = factor
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentZoomFactor = factor }
            } catch {
                DispatchQueue.main.async { self.message = "Zoom could not be changed while the camera is busy." }
            }
        }
    }

    func setExposureBias(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(clamped, completionHandler: nil)
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.message = "Focus is temporarily unavailable." }
            }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, let oldInput = self.activeInput else { return }
            let nextPosition: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back
            guard let device = self.device(for: nextPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.activeInput = newInput
                self.activeDevice = device
                self.cameraPosition = nextPosition
                let defaultZoom = min(max(1, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = defaultZoom
                    device.unlockForConfiguration()
                } catch {
                    // The new camera remains available at its current zoom.
                }
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
            if self.activeDevice === device { self.updateCapabilities(for: device) }
        }
    }

    func capturePhoto(format: CaptureFormat, preferProRAW: Bool, flashMode: AVCaptureDevice.FlashMode) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.captureInProgress else { return }
            self.captureInProgress = true
            DispatchQueue.main.async {
                self.isCapturing = true
                self.message = nil
            }

            let codec: AVVideoCodecType = self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings: AVCapturePhotoSettings
            let wantsRaw = format == .raw && !self.photoOutput.availableRawPhotoPixelFormatTypes.isEmpty

            if wantsRaw, let rawPixelType = self.rawPixelFormat(preferProRAW: preferProRAW) {
                let processedFormat: [String: Any] = [AVVideoCodecKey as String: codec]
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawPixelType, processedFormat: processedFormat)
                settings.isHighResolutionPhotoEnabled = true
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey as String: codec])
                settings.isHighResolutionPhotoEnabled = true
            }

            settings.photoQualityPrioritization = .quality
            if self.activeDevice?.hasFlash == true,
               self.photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            let fileExtension = codec == .hevc ? "heic" : "jpg"
            self.pendingCaptures[settings.uniqueID] = PendingCapture(
                processedData: nil,
                rawData: nil,
                processedFileExtension: fileExtension
            )
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func clearCapturedPhoto() {
        capturedPhoto = nil
    }

    func saveToPhotos(_ photo: CapturedPhoto) async throws {
        let status: PHAuthorizationStatus = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw PhotoSaveError.permissionDenied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let processedOptions = PHAssetResourceCreationOptions()
                processedOptions.originalFilename = "Still-\(photo.id.uuidString).\(photo.processedFileExtension)"
                request.addResource(with: .photo, data: photo.processedData, options: processedOptions)
                if let rawData = photo.rawData {
                    let rawOptions = PHAssetResourceCreationOptions()
                    rawOptions.originalFilename = "Still-\(photo.id.uuidString).dng"
                    rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                    request.addResource(with: .alternatePhoto, data: rawData, options: rawOptions)
                }
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: PhotoSaveError.writeFailed) }
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isConfigured {
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.isRunning = true; self.authorization = .authorized }
                self.startMotionUpdates()
                return
            }

            guard let device = self.device(for: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.authorization = .unavailable }
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.analysisQueue)
            self.photoOutput.maxPhotoQualityPrioritization = .quality

            guard self.session.canAddInput(input),
                  self.session.canAddOutput(self.photoOutput),
                  self.session.canAddOutput(self.videoOutput) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.authorization = .unavailable }
                return
            }

            self.session.addInput(input)
            self.session.addOutput(self.photoOutput)
            self.session.addOutput(self.videoOutput)
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.activeInput = input
            self.activeDevice = device
            self.cameraPosition = .back
            self.isConfigured = true
            self.session.commitConfiguration()
            if self.photoOutput.isAppleProRAWSupported {
                self.photoOutput.isAppleProRAWEnabled = true
            }
            self.updateCapabilities(for: device)
            self.session.startRunning()
            DispatchQueue.main.async {
                self.authorization = .authorized
                self.isRunning = true
            }
            self.startMotionUpdates()
        }
    }

    private func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back,
           let tripleCamera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
            return tripleCamera
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private func rawPixelFormat(preferProRAW: Bool) -> OSType? {
        let available = photoOutput.availableRawPhotoPixelFormatTypes
        if preferProRAW, photoOutput.isAppleProRAWEnabled,
           let proRaw = available.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRaw
        }
        return available.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) ?? available.first
    }

    private func updateCapabilities(for device: AVCaptureDevice) {
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = device.maxAvailableVideoZoomFactor
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let supportsProRAW = photoOutput.isAppleProRAWSupported && rawTypes.contains(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
        let actualZoom = device.videoZoomFactor
        DispatchQueue.main.async {
            self.minimumZoomFactor = minimum
            self.maximumZoomFactor = maximum
            self.currentZoomFactor = actualZoom
            self.hasFlash = device.hasFlash && device.position == .back
            self.supportsRaw = !rawTypes.isEmpty
            self.supportsProRAW = supportsProRAW
        }
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = CGFloat(atan2(motion.gravity.x, -motion.gravity.y))
            self.horizonAngle = abs(roll) < 0.012 ? 0 : roll
        }
    }

    private func analyzePreviewFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= 0.45 else { return }
        lastAnalysisTime = now

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let longSide = max(source.extent.width, source.extent.height)
        guard longSide > 0 else { return }
        let scale = min(1, 640 / longSide)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let frame = ciContext.createCGImage(scaled, from: scaled.extent) else { return }

        let vision = CompositionCoach.analyze(frame: frame)
        DispatchQueue.main.async {
            self.compositionObservation = CompositionObservation(
                subjectBounds: vision.subjectBounds,
                subjectCenter: vision.subjectCenter,
                horizonAngle: self.horizonAngle,
                suggestedAdjustment: vision.suggestedAdjustment,
                detectedFace: vision.detectedFace,
                detectedPose: vision.detectedPose
            )
        }
    }

    @objc private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        DispatchQueue.main.async {
            self.message = error?.localizedDescription ?? "The camera session stopped unexpectedly."
            self.isRunning = false
        }
        if error?.code == .mediaServicesWereReset { start() }
    }

    @objc private func handleInterruptionEnded() {
        start()
    }

    @objc private func handleDidEnterBackground() {
        stop()
    }

    @objc private func handleWillEnterForeground() {
        start()
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            if let error { DispatchQueue.main.async { self.message = error.localizedDescription } }
            return
        }
        let id = photo.resolvedSettings.uniqueID
        sessionQueue.async { [weak self] in
            guard let self, var pending = self.pendingCaptures[id] else { return }
            if photo.isRawPhoto { pending.rawData = data }
            else { pending.processedData = data }
            self.pendingCaptures[id] = pending
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let pending = self.pendingCaptures.removeValue(forKey: resolvedSettings.uniqueID)
            self.captureInProgress = false
            DispatchQueue.main.async {
                self.isCapturing = false
                if let error {
                    self.message = error.localizedDescription
                } else if let processed = pending?.processedData {
                    self.capturedPhoto = CapturedPhoto(
                        processedData: processed,
                        rawData: pending?.rawData,
                        processedFileExtension: pending?.processedFileExtension ?? "heic"
                    )
                } else {
                    self.message = "The photo could not be prepared. Please try again."
                }
            }
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        analyzePreviewFrame(pixelBuffer)
    }
}

enum PhotoSaveError: LocalizedError {
    case permissionDenied
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Allow Still to add photos in iPhone Settings."
        case .writeFailed: return "The photo could not be saved. Please try again."
        }
    }
}
