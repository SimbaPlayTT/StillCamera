import AVFoundation
import Combine
import CoreMotion
import CoreVideo
import Foundation
import ImageIO
import UIKit
import Vision

/// All session/device mutations and photo bookkeeping belong to sessionQueue.
/// Published values are snapshots delivered on the main queue.
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var authorization: CameraAuthorizationState = .checking
    @Published private(set) var phase: SessionState = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var capturedPhoto: CapturedPhoto?
    @Published private(set) var supportsRaw = false
    @Published private(set) var supportsProRAW = false
    @Published private(set) var hasFlash = false
    @Published private(set) var hasTorch = false
    @Published private(set) var torchOn = false
    @Published private(set) var isFrontCamera = false
    @Published private(set) var lenses: [LensPreset] = []
    @Published private(set) var minimumZoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 1
    @Published private(set) var currentZoomFactor: CGFloat = 1
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureRange: ClosedRange<Float> = -2...2
    @Published private(set) var manualExposureSupported = false
    @Published private(set) var exposureLocked = false
    @Published private(set) var exposureIsManual = false
    @Published private(set) var actualISO: Float = 0
    @Published private(set) var actualExposure: Double = 0
    @Published private(set) var horizonAngle: CGFloat = 0
    @Published private(set) var isDeviceSteady = true
    @Published private(set) var imageSize = CGSize(width: 3, height: 4)
    @Published private(set) var compositionObservation = CompositionObservation.neutral
    @Published private(set) var message: String?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "still.camera.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "still.camera.vision", qos: .utility)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let motion = CMMotionManager()
    private var input: AVCaptureDeviceInput?
    private var state: SessionState = .idle
    private var configured = false
    private var wantsRunning = false
    private var appActive = true
    private var zoomMultiplier: CGFloat = 1
    private var observations: [NSKeyValueObservation] = []
    private var pending: PendingCapture?
    private let analysisLock = NSLock()
    private var analysisEnabled = false
    private var guideFrameHandler: ((CVPixelBuffer) -> Void)?
    private var requestedTarget: CGRect?
    private var targetRevision = 0
    // The following fields are only touched on analysisQueue.
    private var lastAnalysis: CFTimeInterval = 0
    private var appliedTargetRevision = -1
    private var trackingRequest: VNTrackObjectRequest?
    private var trackingHandler = VNSequenceRequestHandler()
    private var trackingLost = false

    private struct PendingCapture {
        let id: Int64
        let fileExtension: String
        let aspect: CaptureAspect
        var metadata: PhotoMetadata
        var processed: Data?
        var raw: Data?
        var error: String?
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(runtimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.addObserver(self, selector: #selector(interrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        motion.stopDeviceMotionUpdates()
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: enqueueStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.enqueueStart() }
                else { DispatchQueue.main.async { self?.authorization = .denied } }
            }
        case .denied: DispatchQueue.main.async { self.authorization = .denied }
        case .restricted: DispatchQueue.main.async { self.authorization = .restricted }
        @unknown default: DispatchQueue.main.async { self.authorization = .unavailable }
        }
    }

    private func enqueueStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.startIfWanted()
        }
    }

    /// Completion is called on main only after AVCaptureSession has released the camera.
    func stop(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            self.turnTorchOff()
            if self.session.isRunning { self.session.stopRunning() }
            self.transition(.paused)
            DispatchQueue.main.async {
                self.motion.stopDeviceMotionUpdates()
                completion?()
            }
        }
    }

    func setAnalysisEnabled(_ enabled: Bool) {
        analysisLock.lock()
        analysisEnabled = enabled
        if !enabled { requestedTarget = nil; targetRevision += 1 }
        analysisLock.unlock()
        updateFrameDelivery()
        if !enabled { DispatchQueue.main.async { self.compositionObservation = .neutral } }
    }

    /// The consumer must drop busy frames; it must never retain a queue of camera buffers.
    func setGuideFrameHandler(_ handler: ((CVPixelBuffer) -> Void)?) {
        analysisLock.lock(); guideFrameHandler = handler; analysisLock.unlock()
        updateFrameDelivery()
    }

    private func updateFrameDelivery() {
        analysisLock.lock(); let enabled = analysisEnabled || guideFrameHandler != nil; analysisLock.unlock()
        sessionQueue.async { [weak self] in self?.videoOutput.connection(with: .video)?.isEnabled = enabled }
    }

    func rampGuidedZoom(to displayFactor: CGFloat, completion: @escaping (CGFloat, Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.state == .running, let device = self.input?.device else {
                DispatchQueue.main.async { completion(1, false) }; return
            }
            do {
                try device.lockForConfiguration()
                let value = CameraMath.clamp(displayFactor / self.zoomMultiplier,
                    minimum: device.minAvailableVideoZoomFactor,
                    maximum: min(device.maxAvailableVideoZoomFactor, 4 / self.zoomMultiplier))
                device.cancelVideoZoomRamp()
                device.ramp(toVideoZoomFactor: value, withRate: 4)
                device.unlockForConfiguration()
                self.awaitGuidedReadiness(deadline: CACurrentMediaTime() + 3, completion: completion)
            } catch { DispatchQueue.main.async { completion(1, false) } }
        }
    }

    func checkGuidedReadiness(_ completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.input?.device else { DispatchQueue.main.async { completion(false) }; return }
            let ready = self.state == .running && self.session.isRunning && self.pending == nil &&
                !device.isRampingVideoZoom && !device.isAdjustingFocus && !device.isAdjustingExposure
            DispatchQueue.main.async { completion(ready) }
        }
    }

    private func awaitGuidedReadiness(deadline: CFTimeInterval, completion: @escaping (CGFloat, Bool) -> Void) {
        guard state == .running, let device = input?.device else { DispatchQueue.main.async { completion(1, false) }; return }
        let zoom = device.videoZoomFactor * zoomMultiplier
        if !device.isRampingVideoZoom && !device.isAdjustingFocus && !device.isAdjustingExposure {
            publishCapabilities(); DispatchQueue.main.async { completion(zoom, true) }; return
        }
        if CACurrentMediaTime() >= deadline {
            publishCapabilities(); DispatchQueue.main.async { completion(zoom, false) }; return
        }
        sessionQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.awaitGuidedReadiness(deadline: deadline, completion: completion)
        }
    }

    func trackSubject(in bounds: CGRect?) {
        analysisLock.lock()
        requestedTarget = bounds?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        targetRevision += 1
        analysisLock.unlock()
    }

    func setZoomFactor(_ displayFactor: CGFloat) {
        configureDevice("zoom") { device in
            let value = CameraMath.clamp(displayFactor / self.zoomMultiplier,
                minimum: device.minAvailableVideoZoomFactor,
                maximum: min(device.maxAvailableVideoZoomFactor, 20 / self.zoomMultiplier))
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = value
        }
    }

    func setExposureBias(_ value: Float) {
        configureDevice("exposure") { device in
            guard value.isFinite else { return }
            let bias = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)
        }
    }

    func setManualExposure(iso: Float?, shutterSeconds: Double?) {
        configureDevice("manual exposure") { device in
            if iso == nil && shutterSeconds == nil {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                return
            }
            guard device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            let requestedISO = iso ?? device.iso
            let safeISO = min(max(requestedISO.isFinite ? requestedISO : device.iso, format.minISO), format.maxISO)
            let duration = shutterSeconds ?? CMTimeGetSeconds(device.exposureDuration)
            let seconds = min(max(duration.isFinite ? duration : 1 / 60,
                CMTimeGetSeconds(format.minExposureDuration)), CMTimeGetSeconds(format.maxExposureDuration))
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                iso: safeISO, completionHandler: { [weak self] _ in
                    self?.sessionQueue.async { self?.publishCapabilities() }
                })
        }
    }

    func focus(at point: CGPoint, lock: Bool = false, continuous: Bool = false) {
        configureDevice(lock ? "AE/AF lock" : "focus") { device in
            let safe = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = safe }
            if device.exposureMode != .custom && device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = safe }
            let focusMode: AVCaptureDevice.FocusMode = lock ? .locked : continuous ? .continuousAutoFocus : .autoFocus
            let exposureMode: AVCaptureDevice.ExposureMode = lock ? .locked : .continuousAutoExposure
            if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
            if (device.exposureMode != .custom || lock) && device.isExposureModeSupported(exposureMode) { device.exposureMode = exposureMode }
        }
    }

    func setTorch(_ enabled: Bool) {
        configureDevice("torch") { device in
            guard device.hasTorch else { self.notice("This camera has no continuous light."); return }
            guard !enabled || (device.isTorchAvailable && device.isTorchModeSupported(.on)) else {
                self.notice("Continuous light is temporarily unavailable. Let the iPhone cool down."); return
            }
            if enabled { try device.setTorchModeOn(level: min(0.6, AVCaptureDevice.maxAvailableTorchLevel)) }
            else { device.torchMode = .off }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, self.state.allowsConfiguration, let old = self.input else { return }
            let position: AVCaptureDevice.Position = old.device.position == .back ? .front : .back
            guard let device = self.findDevice(position), let replacement = try? AVCaptureDeviceInput(device: device) else {
                self.notice("That camera is unavailable."); return
            }
            self.transition(.switching)
            self.turnTorchOff()
            self.session.stopRunning()
            self.observations.removeAll()
            self.session.beginConfiguration()
            self.session.removeInput(old)
            if self.session.canAddInput(replacement) {
                self.session.addInput(replacement)
                self.input = replacement
            } else {
                if self.session.canAddInput(old) { self.session.addInput(old) }
                self.notice("Could not switch cameras. The previous camera was restored.")
            }
            self.session.commitConfiguration()
            self.prepareOutputAndDevice()
            self.trackSubject(in: nil)
            self.startIfWanted()
        }
    }

    func capturePhoto(format: CaptureFormat, preferProRAW: Bool, flashMode: AVCaptureDevice.FlashMode,
                      aspect: CaptureAspect = .standard) {
        sessionQueue.async { [weak self] in
            guard let self, self.state.allowsCapture, self.session.isRunning, self.pending == nil,
                  let device = self.input?.device,
                  let connection = self.photoOutput.connection(with: .video), connection.isEnabled,
                  connection.isActive else { return }
            let codec: AVVideoCodecType = self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let processed: [String: Any] = [AVVideoCodecKey: codec]
            let settings: AVCapturePhotoSettings
            if format == .raw {
                let available = self.photoOutput.availableRawPhotoPixelFormatTypes
                let raw = preferProRAW ? available.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
                    ?? available.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) :
                    available.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
                    ?? available.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
                guard let raw else { self.notice("RAW is unavailable on this camera. Choose HEIF / JPEG."); return }
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: processed)
                // RAW processing has different quality constraints from computational HEIF capture.
                settings.photoQualityPrioritization = .speed
            } else {
                settings = AVCapturePhotoSettings(format: processed)
                settings.photoQualityPrioritization = .balanced
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if device.hasFlash && device.isFlashAvailable && device.torchMode == .off &&
                self.photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            } else {
                settings.flashMode = .off
                if flashMode == .on && device.torchMode == .off { self.notice("Flash is unavailable for this capture.") }
            }
            self.pending = PendingCapture(id: settings.uniqueID, fileExtension: codec == .hevc ? "heic" : "jpg",
                aspect: aspect, metadata: PhotoMetadata(date: Date(), lens: device.localizedName,
                    iso: Double(device.iso), exposure: CMTimeGetSeconds(device.exposureDuration)))
            self.transition(.capturing)
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            let captureID = settings.uniqueID
            self.sessionQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.pending?.id == captureID else { return }
                self.pending = nil
                self.turnTorchOff()
                if self.session.isRunning { self.session.stopRunning() }
                self.transition(.failed)
                self.notice("Capture timed out. Your previous photos are safe. Tap Retry to restart the camera.")
            }
        }
    }

    func clearCapturedPhoto() { capturedPhoto = nil }
    func dismissMessage() { message = nil }

    private func configureDevice(_ operation: String, change: @escaping (AVCaptureDevice) throws -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.state.allowsConfiguration, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try change(device)
                self.publishCapabilities()
            } catch {
                self.notice("Could not change \(operation): \(error.localizedDescription)")
            }
        }
    }

    private func startIfWanted() {
        guard wantsRunning, appActive, pending == nil else { return }
        if !configured {
            transition(.configuring)
            do { try configure() }
            catch {
                transition(.failed)
                notice(error.localizedDescription)
                DispatchQueue.main.async { self.authorization = .failed(error.localizedDescription) }
                return
            }
        }
        if !session.isRunning { session.startRunning() }
        transition(session.isRunning ? .running : .failed)
        DispatchQueue.main.async {
            self.authorization = self.session.isRunning ? .authorized : .failed("Camera did not start. Try again.")
            self.startMotion()
        }
    }

    private func configure() throws {
        guard let device = findDevice(.back) else { throw CameraError.noDevice }
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(newInput) else { session.commitConfiguration(); throw CameraError.noDevice }
        session.addInput(newInput)
        guard session.canAddOutput(photoOutput) else {
            session.removeInput(newInput); session.commitConfiguration(); throw CameraError.noDevice
        }
        session.addOutput(photoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        }
        input = newInput
        session.commitConfiguration()
        configured = true
        prepareOutputAndDevice()
    }

    private func findDevice(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera] {
                if let device = AVCaptureDevice.default(type, for: .video, position: position) { return device }
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private func prepareOutputAndDevice() {
        guard let device = input?.device else { return }
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        // Virtual-device zoom starts at its widest constituent. Convert it to wide-camera 1x.
        zoomMultiplier = hasUltraWide ? 1 / (switches.first ?? 2) : 1
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CameraMath.clamp(1 / zoomMultiplier,
                minimum: device.minAvailableVideoZoomFactor, maximum: device.maxAvailableVideoZoomFactor)
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch { notice(error.localizedDescription) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
        else if photoOutput.isAppleProRAWEnabled { photoOutput.isAppleProRAWEnabled = false }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        let balanced = sizes.filter { Int64($0.width) * Int64($0.height) <= 25_000_000 }
        if let size = (balanced.isEmpty ? sizes : balanced).max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) { photoOutput.maxPhotoDimensions = size }
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
        for connection in [photoOutput.connection(with: .video), videoOutput.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front
            }
        }
        analysisLock.lock()
        let deliverFrames = analysisEnabled || guideFrameHandler != nil
        analysisLock.unlock()
        videoOutput.connection(with: .video)?.isEnabled = deliverFrames
        observations = [device.observe(\.isTorchActive, options: [.new]) { [weak self] _, _ in
            self?.sessionQueue.async { self?.publishCapabilities() }
        }, device.observe(\.isTorchAvailable, options: [.new]) { [weak self] _, _ in
            self?.sessionQueue.async { self?.publishCapabilities() }
        }, device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self] _, _ in
            self?.sessionQueue.async { self?.publishCapabilities() }
        }]
        publishCapabilities()
        CameraDiagnostics.shared.record("Configured \(device.localizedName); RAW=\(!photoOutput.availableRawPhotoPixelFormatTypes.isEmpty); zoom multiplier=\(zoomMultiplier)")
    }

    private func publishCapabilities() {
        guard let device = input?.device else { return }
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = min(device.maxAvailableVideoZoomFactor, 20 / zoomMultiplier)
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let presets = CameraMath.displayedPresets(switchFactors: switches, multiplier: zoomMultiplier, minimum: minimum, maximum: maximum)
        let zoom = device.videoZoomFactor * zoomMultiplier
        let minZoom = minimum * zoomMultiplier, maxZoom = maximum * zoomMultiplier
        let raw = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let pro = photoOutput.isAppleProRAWEnabled && photoOutput.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        let flash = device.hasFlash && device.isFlashAvailable
        let torch = device.hasTorch && device.isTorchAvailable
        let activeTorch = device.isTorchActive
        let front = device.position == .front
        let bias = device.exposureTargetBias
        let biasRange = max(-3, device.minExposureTargetBias)...min(3, device.maxExposureTargetBias)
        let manual = device.isExposureModeSupported(.custom)
        let locked = device.exposureMode == .locked
        let custom = device.exposureMode == .custom
        let iso = device.iso, duration = CMTimeGetSeconds(device.exposureDuration)
        DispatchQueue.main.async {
            self.minimumZoomFactor = minZoom; self.maximumZoomFactor = maxZoom
            self.currentZoomFactor = zoom; self.lenses = presets
            self.supportsRaw = raw; self.supportsProRAW = pro
            self.hasFlash = flash; self.hasTorch = torch; self.torchOn = activeTorch
            self.isFrontCamera = front; self.exposureBias = bias; self.exposureRange = biasRange
            self.manualExposureSupported = manual; self.exposureLocked = locked
            self.exposureIsManual = custom; self.actualISO = iso; self.actualExposure = duration
        }
    }

    private func transition(_ next: SessionState) {
        state = next
        let running = session.isRunning
        CameraDiagnostics.shared.record("Session \(next.rawValue)")
        DispatchQueue.main.async { self.phase = next; self.isRunning = running; self.isCapturing = next == .capturing }
    }

    private func notice(_ text: String) {
        CameraDiagnostics.shared.record(text)
        DispatchQueue.main.async { self.message = text }
    }

    private func turnTorchOff() {
        guard let device = input?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        } catch { CameraDiagnostics.shared.record("Torch shutdown: \(error.localizedDescription)") }
        DispatchQueue.main.async { self.torchOn = false }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let roll = CameraMath.horizon(gravityX: data.gravity.x, gravityY: data.gravity.y)
            let next: CGFloat = abs(roll) < 0.015 ? 0 : roll
            if let self {
                if abs(self.horizonAngle - next) > 0.006 { self.horizonAngle = next }
                let r = data.rotationRate, a = data.userAcceleration
                let steady = r.x * r.x + r.y * r.y + r.z * r.z < 0.0144 &&
                    a.x * a.x + a.y * a.y + a.z * a.z < 0.0064
                if self.isDeviceSteady != steady { self.isDeviceSteady = steady }
            }
        }
    }

    @objc private func background() {
        sessionQueue.async {
            self.appActive = false; self.turnTorchOff()
            if self.session.isRunning { self.session.stopRunning() }
            self.transition(.paused)
            DispatchQueue.main.async { self.motion.stopDeviceMotionUpdates() }
        }
    }
    @objc private func foreground() { sessionQueue.async { self.appActive = true; self.startIfWanted() } }
    @objc private func interrupted(_ notification: Notification) {
        sessionQueue.async { self.turnTorchOff(); self.transition(.interrupted); self.notice("Camera interrupted. It will resume when available.") }
    }
    @objc private func interruptionEnded() { sessionQueue.async { self.startIfWanted() } }
    @objc private func runtimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        sessionQueue.async {
            self.pending = nil
            self.transition(.failed)
            self.notice(error?.localizedDescription ?? "Camera stopped unexpectedly. Tap Retry.")
            if error?.code == .mediaServicesWereReset { self.startIfWanted() }
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let raw = photo.isRawPhoto
        let id = photo.resolvedSettings.uniqueID
        let metadata = photo.metadata
        sessionQueue.async {
            guard self.pending?.id == id else { return }
            if let error { self.pending?.error = error.localizedDescription }
            if raw { self.pending?.raw = data } else {
                self.pending?.processed = data
                if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                    if let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let iso = values.first {
                        self.pending?.metadata.iso = iso.doubleValue
                    }
                    if let lens = exif[kCGImagePropertyExifLensModel as String] as? String { self.pending?.metadata.lens = lens }
                    self.pending?.metadata.focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double ?? 0
                    if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                        self.pending?.metadata.exposure = exposure
                    }
                }
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async {
            guard self.pending?.id == resolvedSettings.uniqueID else { return }
            let capture = self.pending
            self.pending = nil
            self.transition(self.session.isRunning ? .running : .paused)
            if let detail = error?.localizedDescription ?? capture?.error { self.notice(detail) }
            else if let capture, let data = capture.processed {
                let result = CapturedPhoto(processedData: data, rawData: capture.raw,
                    processedFileExtension: capture.fileExtension, metadata: capture.metadata, aspect: capture.aspect)
                DispatchQueue.main.async { self.capturedPhoto = result }
            } else { self.notice("The photo could not be processed. Please try again.") }
            self.publishCapabilities()
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        analysisLock.lock()
        let enabled = analysisEnabled, target = requestedTarget, revision = targetRevision, guideHandler = guideFrameHandler
        analysisLock.unlock()
        if let guideHandler, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) { guideHandler(buffer) }
        guard enabled else { return }
        let interval: Double = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState != .nominal ? 1.4 : 0.6
        let now = CACurrentMediaTime()
        guard now - lastAnalysis >= interval, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        autoreleasepool {
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if appliedTargetRevision != revision {
                appliedTargetRevision = revision
                trackingHandler = VNSequenceRequestHandler()
                trackingLost = false
                trackingRequest = target.flatMap { rect in
                    guard rect.width > 0.02, rect.height > 0.02 else { return nil }
                    return VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(
                        boundingBox: CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)))
                }
            }
            var result: VisionComposition
            if let request = trackingRequest {
                do {
                    try trackingHandler.perform([request], on: buffer, orientation: .up)
                    if let tracked = request.results?.first as? VNDetectedObjectObservation, tracked.confidence > 0.4 {
                        request.inputObservation = tracked
                        let box = tracked.boundingBox
                        let bounds = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                        result = CompositionCoach.observation(bounds: bounds, face: false, pose: false)
                    } else {
                        trackingRequest = nil
                        trackingLost = target != nil
                        result = VisionComposition(subjectBounds: nil, subjectCenter: nil,
                            suggestedAdjustment: "Subject lost. Select it again.", detectedFace: false, detectedPose: false)
                    }
                } catch {
                    trackingRequest = nil
                    return
                }
            } else if trackingLost {
                result = VisionComposition(subjectBounds: nil, subjectCenter: nil,
                    suggestedAdjustment: "Subject lost. Select it again.", detectedFace: false, detectedPose: false)
            } else {
                result = CompositionCoach.analyze(pixelBuffer: buffer)
                if let rect = result.subjectBounds {
                    trackingRequest = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(
                        boundingBox: CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)))
                }
            }
            DispatchQueue.main.async {
                self.imageSize = size
                self.compositionObservation = CompositionObservation(subjectBounds: result.subjectBounds,
                    subjectCenter: result.subjectCenter, horizonAngle: self.horizonAngle,
                    suggestedAdjustment: result.suggestedAdjustment, detectedFace: result.detectedFace, detectedPose: result.detectedPose)
            }
        }
    }
}

private enum CameraError: LocalizedError {
    case noDevice
    var errorDescription: String? { "A compatible camera could not be configured. Close other camera apps and try again." }
}
