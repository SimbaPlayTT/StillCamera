import ARKit
import AVFoundation
import Combine
import CoreImage
import CoreMotion
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum GuidePhase: Equatable { case starting, scanning, locked, framing, lost, empty, capturing, failed, stopped }

struct GuideSnapshot {
    var phase: GuidePhase = .starting
    var instruction = "Starting guide"
    var detail = "Keep your phone steady"
    var corners: [CGPoint] = []
    var progress: Double = 0
    var zoom: CGFloat = 1
    var tracking = "Visual tracking"
    var trusted = false
    var canScan: Bool { ![GuidePhase.starting, .framing, .capturing, .stopped].contains(phase) }
    var canCapture: Bool { phase == .locked && trusted }
}

/// Exactly one camera owner: ARKit for depth anchoring, AVCaptureSession for the visual fallback.
/// Frame processing, the frozen plan, anchors and capture gate all live on queue.
final class GuideSession: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var snapshot = GuideSnapshot()
    @Published private(set) var photo: CapturedPhoto?
    @Published private(set) var aspect: CaptureAspect
    let camera = CameraService()
    let arSession = ARSession()
    let usesWorldCamera: Bool
    private let queue = DispatchQueue(label: "still.guide", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "still.guide.frames", qos: .userInitiated)
    private let bufferLock = NSLock()
    private var bufferBusy = false
    private let vision = GuideVision()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let motion = CMMotionManager()
    private var subscriptions = Set<AnyCancellable>()
    private var running = false
    private var generation = 0
    private var intent: GuideIntent
    private var viewport = CGSize.zero
    private var imageSize = CGSize(width: 3, height: 4)
    private var plan: GuidePlan?
    private var corners: [SIMD3<Float>] = []
    private var worldAnchor: ARAnchor?
    private var anchorCorners: [SIMD3<Float>] = []
    private var anchorSubject: SIMD3<Float>?
    private var worldSubject: SIMD3<Float>?
    private var trackingBox: CGRect?
    private var scanPending = true
    private var manualRegion: CGRect?
    private var lost = false
    private var gate = GuideCaptureGate()
    private var shotPending = false
    private var captureTicket: UUID?
    private var zoomPrepared = false
    private var zooming = false
    private var zoom: CGFloat = 1
    private var desiredZoom: CGFloat = 1
    private var fallbackZoom: CGFloat = 1
    private var lastFrame: CFTimeInterval = 0
    private var lastProcessed: CFTimeInterval = 0
    private var roll: CGFloat = 0
    private var deviceSteady = true
    private var autoCapture: Bool
    private let autoZoom: Bool
    private let dwell: Double
    private let captureFormat: CaptureFormat
    private let preferProRAW: Bool

    static var worldTrackingAvailable: Bool {
        DepthSession.supported && ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
    }

    init(intent: GuideIntent, preferDepth: Bool, autoZoom: Bool, autoCapture: Bool, dwell: Double,
         format: CaptureFormat, preferProRAW: Bool) {
        self.intent = intent; self.aspect = intent.aspect
        self.autoZoom = autoZoom; self.autoCapture = autoCapture
        self.dwell = dwell.isFinite ? min(max(dwell, 0.6), 3) : 0.8
        self.captureFormat = format; self.preferProRAW = preferProRAW
        usesWorldCamera = preferDepth && Self.worldTrackingAvailable && format != .raw
        super.init()
        arSession.delegate = self; arSession.delegateQueue = frameQueue
        camera.$capturedPhoto.compactMap { $0 }.sink { [weak self] photo in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.shotPending, self.captureTicket != nil else { return }
                self.captureTicket = nil
                DispatchQueue.main.async { self.photo = photo }
            }
        }.store(in: &subscriptions)
        camera.$message.compactMap { $0 }.sink { [weak self] message in
            self?.queue.async { self?.fail(message) }
        }.store(in: &subscriptions)
        camera.$horizonAngle.sink { [weak self] value in self?.queue.async { self?.roll = value } }.store(in: &subscriptions)
        camera.$isDeviceSteady.sink { [weak self] value in self?.queue.async { self?.deviceSteady = value } }.store(in: &subscriptions)
        camera.$currentZoomFactor.sink { [weak self] value in self?.queue.async { self?.fallbackZoom = value } }.store(in: &subscriptions)
    }

    deinit { motion.stopDeviceMotionUpdates() }

    func attachPreview(_ view: ARSCNView) {
        view.session = arSession
        arSession.delegate = self
        arSession.delegateQueue = frameQueue
    }

    func start(viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        queue.async {
            self.viewport = viewport
            guard !self.running else { return }
            self.running = true; self.generation += 1
            self.resetPlan(); self.scanPending = true
            self.publish(.scanning, "Finding a frame", detail: "Reading shapes, subjects and space")
            if self.usesWorldCamera {
                guard let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing else {
                    self.fail("High-resolution AR capture is unavailable. Turn off LiDAR anchoring in Settings."); return
                }
                let configuration = ARWorldTrackingConfiguration()
                configuration.videoFormat = format
                configuration.isAutoFocusEnabled = true
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                    configuration.frameSemantics = .smoothedSceneDepth
                } else { configuration.frameSemantics = .sceneDepth }
                self.arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                DispatchQueue.main.async { self.startMotion() }
            } else {
                self.camera.setGuideFrameHandler { [weak self] buffer in self?.offer(buffer) }
                self.camera.start()
            }
            self.watchFrames(generation: self.generation)
        }
    }

    /// Completion runs after the active owner releases the camera.
    func stop(completion: (() -> Void)? = nil) {
        motion.stopDeviceMotionUpdates()
        queue.async {
            self.running = false; self.generation += 1; self.gate.reset()
            self.arSession.pause()
            self.camera.setGuideFrameHandler(nil)
            self.publish(.stopped, "Guide paused", detail: "")
            self.camera.stop(completion: completion)
        }
    }

    func rescan(style: GuideStyle? = nil, selectDetail: Bool = false) {
        queue.async {
            guard self.running, !self.shotPending, !self.zooming else { return }
            if let style {
                self.intent = GuideIntent(style: style)
                DispatchQueue.main.async { self.aspect = self.intent.aspect }
            }
            self.resetPlan(); self.manualRegion = nil
            let instruction = selectDetail ? "Draw around a detail" : "Finding a new frame"
            let detail = selectDetail ? "Release to lock your selection" : "The previous target has been released"
            if !self.usesWorldCamera && abs(self.fallbackZoom - 1) > 0.05 {
                self.zooming = true
                let token = self.generation
                self.camera.rampGuidedZoom(to: 1) { [weak self] _, _ in
                    self?.queue.async {
                        guard let self, self.running, self.generation == token else { return }
                        self.zooming = false; self.scanPending = !selectDetail
                        self.publish(selectDetail ? .empty : .scanning, instruction, detail: detail)
                    }
                }
            } else { self.scanPending = !selectDetail }
            self.publish(self.zooming ? .framing : selectDetail ? .empty : .scanning,
                self.zooming ? "Resetting zoom" : instruction, detail: detail)
        }
    }

    func select(region: CGRect) {
        queue.async {
            guard self.running, !self.shotPending, !self.zooming else { return }
            // A manual selection is made in the unzoomed viewfinder after rescan.
            guard self.zoom <= 1.01 && (!self.usesWorldCamera ? self.fallbackZoom <= 1.05 : true) else { return }
            let pixels = CGRect(x: region.minX * self.viewport.width, y: region.minY * self.viewport.height,
                                width: region.width * self.viewport.width, height: region.height * self.viewport.height)
            let bounds = CameraMath.imageRect(pixels, imageSize: self.imageSize, viewSize: self.viewport)
            guard bounds.width > 0.03, bounds.height > 0.03 else { return }
            self.resetPlan(); self.manualRegion = bounds; self.scanPending = true
            self.publish(.scanning, "Locking your selection", detail: "")
        }
    }

    func setAutoCapture(_ enabled: Bool) {
        queue.async { self.autoCapture = enabled; self.gate.reset() }
    }

    func captureNow() {
        queue.async {
            guard self.running, self.plan != nil, !self.lost, !self.zooming, !self.shotPending else { return }
            self.takePhoto(automatic: false)
        }
    }

    private func resetPlan() {
        if let worldAnchor { arSession.remove(anchor: worldAnchor) }
        worldAnchor = nil; corners = []; anchorCorners = []; anchorSubject = nil; worldSubject = nil
        captureTicket = nil; plan = nil; trackingBox = nil
        gate.reset(); lost = false; zoomPrepared = false; zooming = false
        zoom = 1; desiredZoom = 1; lastProcessed = 0
    }

    /// At most one camera buffer can be retained by the guide. All excess frames are dropped.
    private func offer(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, frame: ARFrame? = nil) {
        bufferLock.lock()
        guard !bufferBusy else { bufferLock.unlock(); return }
        bufferBusy = true; bufferLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.bufferLock.lock(); self.bufferBusy = false; self.bufferLock.unlock() }
            self.process(buffer, orientation: orientation, arFrame: frame)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        offer(frame.capturedImage, orientation: .right, frame: frame)
    }

    private func process(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, arFrame: ARFrame?) {
        guard running, !shotPending, viewport.width > 0 else { return }
        let now = CACurrentMediaTime()
        lastFrame = now
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical { gate.reset(); publish(.lost, "Let your iPhone cool down", detail: "Capture is paused"); return }
        let constrained = thermal == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled
        let interval: Double = constrained ? 0.14 : corners.count == 4 ? 1 / 30 : 0.05
        guard now - lastProcessed >= interval, !zooming else { return }
        lastProcessed = now
        autoreleasepool {
            if let arFrame {
                guard case .normal = arFrame.camera.trackingState else {
                    gate.reset(); publish(.lost, "Move slowly to recover tracking", detail: "The target has not been moved"); return
                }
            }
            do {
                if scanPending {
                    guard let upright = vision.upright(buffer, orientation: orientation) else { return }
                    imageSize = CGSize(width: CVPixelBufferGetWidth(upright), height: CVPixelBufferGetHeight(upright))
                    let subjects: [GuideSubject]
                    if let manualRegion { subjects = [GuideSubject(bounds: manualRegion, confidence: 1, kind: .salient)] }
                    else { subjects = try vision.detect(upright) }
                    scanPending = false
                    guard let selected = GuidePlanner.choose(subjects: subjects, imageAspect: imageSize.width / imageSize.height, intent: intent) else {
                        plan = nil; publish(.empty, "Choose a clearer subject", detail: "Rescan, or select a detail yourself"); return
                    }
                    plan = selected; trackingBox = selected.subject.bounds
                    vision.lock(selected.subject.bounds)
                    if let arFrame { anchor(selected.crop, subject: selected.subject.bounds, frame: arFrame) }
                }
                guard let plan, !lost else { return }
                let points: [CGPoint]
                var trusted = true
                if let arFrame, corners.count == 4 {
                    if let anchor = worldAnchor {
                        let pose = arFrame.anchors.first(where: { $0.identifier == anchor.identifier })?.transform ?? anchor.transform
                        corners = anchorCorners.map { point in
                            let value = pose * SIMD4<Float>(point, 1)
                            return SIMD3<Float>(value.x, value.y, value.z)
                        }
                        if let anchorSubject {
                            let value = pose * SIMD4<Float>(anchorSubject, 1)
                            worldSubject = SIMD3<Float>(value.x, value.y, value.z)
                        }
                    }
                    let inverse = simd_inverse(arFrame.camera.transform)
                    trusted = corners.allSatisfy { (inverse * SIMD4<Float>($0, 1)).z < -0.05 }
                    points = corners.map {
                        let p = arFrame.camera.projectPoint($0, orientation: .portrait, viewportSize: viewport)
                        return CGPoint(x: p.x / viewport.width, y: p.y / viewport.height)
                    }
                    // A nearer occluder must never trigger a photo of a different subject.
                    if let worldSubject {
                        let projected = arFrame.camera.projectPoint(worldSubject, orientation: .portrait, viewportSize: viewport)
                        let point = CGPoint(x: projected.x / viewport.width, y: projected.y / viewport.height)
                        let local = inverse * SIMD4<Float>(worldSubject, 1)
                        let expected = -local.z
                        if let observed = depth(at: point, frame: arFrame) {
                            if expected - observed > max(0.35, expected * 0.2) { trusted = false }
                        } else { trusted = false }
                    }
                } else {
                    guard let upright = vision.upright(buffer, orientation: orientation) else { return }
                    guard let tracked = try vision.track(upright) else { loseTarget(); return }
                    trackingBox = tracked
                    let crop = plan.crop(tracking: tracked)
                    let pixels = CameraMath.viewRect(crop, imageSize: imageSize, viewSize: viewport)
                    let rect = CGRect(x: pixels.minX / viewport.width, y: pixels.minY / viewport.height,
                                      width: pixels.width / viewport.width, height: pixels.height / viewport.height)
                    points = rectanglePoints(rect)
                }
                guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { loseTarget(); return }
                let bounds = boundingRect(points)
                let center = midpoint(points)
                trusted = trusted && center.x > -0.2 && center.x < 1.2 && center.y > -0.2 && center.y < 1.2
                let centered = abs(center.x - 0.5) < 0.045 && abs(center.y - 0.5) < 0.045 && abs(roll) < 0.055
                if centered, trusted, autoZoom, !zoomPrepared {
                    zoomPrepared = true
                    desiredZoom = GuidePlanner.zoomToFill(bounds)
                    gate.reset()
                    if usesWorldCamera { zoom = 1 }
                    else if desiredZoom > 1.04 { prepareVisualZoom(factor: desiredZoom); return }
                }
                if usesWorldCamera && zoomPrepared {
                    zoom += min(max(desiredZoom - zoom, 0), 0.16)
                }
                let displayed = usesWorldCamera ? points.map { GuidePlanner.zoomed($0, by: zoom) } : points
                let target = midpoint(displayed)
                let framing = usesWorldCamera && desiredZoom - zoom > 0.015
                let hardwareReady: Bool
                if usesWorldCamera, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
                    hardwareReady = !device.isAdjustingFocus && !device.isAdjustingExposure
                } else { hardwareReady = true }
                let result = gate.update(time: now, point: target, trusted: trusted, level: roll,
                    ready: hardwareReady && deviceSteady && !framing && (!autoZoom || zoomPrepared), dwell: dwell,
                    scale: sqrt(max(0, bounds.width * bounds.height)))
                let cue = !trusted ? "Keep the target in sight" : framing ? "Setting the frame" :
                    result.progress > 0 ? (autoCapture ? "Hold steady · taking photo" : "Ready to shoot") :
                    GuidePlanner.instruction(target: target, level: roll)
                publish(framing ? .framing : .locked, cue, detail: plan.title, points: displayed,
                        progress: autoCapture ? result.progress : 0, trusted: trusted)
                if result.fire && autoCapture { takePhoto(automatic: true) }
                // With manual capture enabled, don't consume the one-shot gate until the shutter is pressed.
                if result.fire && !autoCapture { gate.reset() }
            } catch { loseTarget() }
        }
    }

    private func anchor(_ crop: CGRect, subject: CGRect, frame: ARFrame) {
        let pixels = CameraMath.viewRect(crop, imageSize: imageSize, viewSize: viewport)
        let rect = CGRect(x: pixels.minX / viewport.width, y: pixels.minY / viewport.height,
                          width: pixels.width / viewport.width, height: pixels.height / viewport.height)
        let subjectPixels = CameraMath.viewRect(subject, imageSize: imageSize, viewSize: viewport)
        let center = CGPoint(x: subjectPixels.midX / viewport.width, y: subjectPixels.midY / viewport.height)
        guard let distance = depth(at: center, frame: frame) else { return } // Honest visual fallback on distant/unmapped surfaces.
        guard let plane = GuideWorldGeometry.cameraFacingPlane(camera: frame.camera.transform, depth: distance) else { return }
        let unprojected = rectanglePoints(rect).compactMap { point in
            frame.camera.unprojectPoint(CGPoint(x: point.x * viewport.width, y: point.y * viewport.height),
                ontoPlane: plane, orientation: .portrait, viewportSize: viewport)
        }
        guard unprojected.count == 4, unprojected.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return }
        corners = unprojected
        let inverse = simd_inverse(plane)
        anchorCorners = unprojected.map { point in
            let value = inverse * SIMD4<Float>(point, 1)
            return SIMD3<Float>(value.x, value.y, value.z)
        }
        worldSubject = frame.camera.unprojectPoint(CGPoint(x: center.x * viewport.width, y: center.y * viewport.height),
            ontoPlane: plane, orientation: .portrait, viewportSize: viewport)
        if let worldSubject {
            let value = inverse * SIMD4<Float>(worldSubject, 1)
            anchorSubject = SIMD3<Float>(value.x, value.y, value.z)
        }
        let anchor = ARAnchor(name: "Still composition", transform: plane)
        worldAnchor = anchor; arSession.add(anchor: anchor)
    }

    private func depth(at point: CGPoint, frame: ARFrame) -> Float? {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let imagePoint = point.applying(frame.displayTransform(for: .portrait, viewportSize: viewport).inverted())
        guard imagePoint.x >= 0, imagePoint.x <= 1, imagePoint.y >= 0, imagePoint.y <= 1 else { return nil }
        let buffer = depth.depthMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let px = min(Int(imagePoint.x * CGFloat(width)), width - 1)
        let py = min(Int(imagePoint.y * CGFloat(height)), height - 1)
        if let confidence = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            guard let bytes = CVPixelBufferGetBaseAddress(confidence) else { return nil }
            let row = bytes.advanced(by: py * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
            guard row[px] >= 1 else { return nil }
        }
        var samples: [Float] = []
        for y in max(0, py - 1)...min(height - 1, py + 1) {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float32.self)
            for x in max(0, px - 1)...min(width - 1, px + 1) {
                let value = row[x]
                if value.isFinite && value > 0.2 && value < 8 { samples.append(value) }
            }
        }
        guard samples.count >= 4 else { return nil }
        return samples.sorted()[samples.count / 2]
    }

    private func prepareVisualZoom(factor: CGFloat) {
        guard let old = trackingBox, let plan else { return }
        zooming = true
        let start = fallbackZoom, token = generation
        publish(.framing, "Setting the frame", detail: "Let the camera settle")
        camera.rampGuidedZoom(to: start * factor) { [weak self] actual, ready in
            self?.queue.async {
                guard let self, self.running, token == self.generation else { return }
                self.zooming = false
                guard ready else { self.loseTarget(); return }
                let ratio = actual / max(start, 0.01)
                let origin = GuidePlanner.zoomed(old.origin, by: ratio)
                let newBox = CGRect(x: origin.x, y: origin.y, width: old.width * ratio, height: old.height * ratio)
                guard GuidePlanner.unit.contains(newBox) else { self.loseTarget(); return }
                // Re-seed at the exact known zoom transform, then require a fresh confident observation.
                self.vision.lock(newBox); self.trackingBox = newBox
                self.plan = GuidePlan(subject: GuideSubject(bounds: newBox, confidence: plan.subject.confidence, kind: plan.subject.kind),
                    crop: CGRect(x: 0.5 + (plan.crop.minX - 0.5) * ratio, y: 0.5 + (plan.crop.minY - 0.5) * ratio,
                                 width: plan.crop.width * ratio, height: plan.crop.height * ratio),
                    score: plan.score, aspect: plan.aspect, title: plan.title)
                self.gate.reset()
            }
        }
    }

    private func takePhoto(automatic: Bool) {
        guard running, !shotPending, !lost, !zooming, let plan else { return }
        shotPending = true
        let token = generation, ticket = UUID()
        captureTicket = ticket
        publish(.capturing, "Taking photo", detail: "One photo per scan")
        if usesWorldCamera {
            let cropZoom = zoom
            arSession.captureHighResolutionFrame { [weak self] frame, error in
                guard let self else { return }
                self.queue.async {
                    guard self.running, token == self.generation, self.captureTicket == ticket else { return }
                    guard let frame, error == nil else { self.fail(error?.localizedDescription ?? "Could not capture this frame. Rescan to retry."); return }
                    do {
                        let result = try self.makePhoto(frame, aspect: plan.aspect, zoom: cropZoom)
                        self.captureTicket = nil
                        DispatchQueue.main.async { self.photo = result }
                    } catch { self.fail(error.localizedDescription) }
                }
            }
        } else {
            camera.checkGuidedReadiness { [weak self] ready in
                self?.queue.async {
                    guard let self, self.running, token == self.generation, self.captureTicket == ticket else { return }
                    guard ready else {
                        self.shotPending = false; self.captureTicket = nil; self.gate.reset()
                        self.publish(.locked, "Let the camera settle", detail: plan.title); return
                    }
                    self.camera.capturePhoto(format: self.captureFormat, preferProRAW: self.preferProRAW,
                                             flashMode: .off, aspect: plan.aspect)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 32) { [weak self] in
            guard let self, self.running, token == self.generation, self.shotPending, self.captureTicket == ticket else { return }
            self.fail("Capture timed out. Close Guide and try again.")
        }
    }

    private func makePhoto(_ frame: ARFrame, aspect: CaptureAspect, zoom: CGFloat) throws -> CapturedPhoto {
        let source = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let crop = CameraMath.crop(in: source.extent, ratio: aspect.ratio)
        let inset = CGRect(x: crop.midX - crop.width / zoom / 2, y: crop.midY - crop.height / zoom / 2,
                           width: crop.width / zoom, height: crop.height / zoom).integral.intersection(source.extent)
        let image = source.cropped(to: inset).transformed(by: CGAffineTransform(translationX: -inset.minX, y: -inset.minY))
        guard let cg = imageContext.createCGImage(image, from: image.extent) else { throw GuideError.encoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw GuideError.encoding }
        var exif = frame.exifData
        exif[kCGImagePropertyExifPixelXDimension as String] = cg.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cg.height
        let properties: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.96,
            kCGImagePropertyOrientation as String: 1, kCGImagePropertyExifDictionary as String: exif]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GuideError.encoding }
        var metadata = PhotoMetadata()
        metadata.lens = "Wide · guided"
        if let values = frame.exifData[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] { metadata.iso = values.first?.doubleValue ?? 0 }
        metadata.exposure = frame.exifData[kCGImagePropertyExifExposureTime as String] as? Double ?? 0
        metadata.focalLength = frame.exifData[kCGImagePropertyExifFocalLength as String] as? Double ?? 0
        return CapturedPhoto(processedData: data as Data, rawData: nil, processedFileExtension: "jpg", metadata: metadata, aspect: aspect)
    }

    private func loseTarget() {
        lost = true; gate.reset()
        publish(.lost, "Target lost · rescan", detail: "Choose the frame again before shooting")
    }

    private func fail(_ message: String) {
        guard running else { return }
        shotPending = false; captureTicket = nil; lost = true; gate.reset()
        publish(.failed, "Guide paused", detail: message)
        CameraDiagnostics.shared.record("Guide: \(message)")
    }

    func session(_ session: ARSession, didFailWithError error: Error) { queue.async { self.fail(error.localizedDescription) } }
    func sessionWasInterrupted(_ session: ARSession) {
        queue.async { self.gate.reset(); self.publish(.lost, "Camera interrupted", detail: "Close Guide to restart") }
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        queue.async { self.lost = true; self.gate.reset(); self.publish(.lost, "Rescan to continue", detail: "Tracking was interrupted") }
    }

    private func watchFrames(generation token: Int) {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running, token == self.generation else { return }
            if !self.shotPending && self.lastFrame > 0 && CACurrentMediaTime() - self.lastFrame > 0.45 {
                self.gate.reset()
                self.publish(.lost, "Waiting for camera", detail: "Automatic capture is paused")
            }
            self.watchFrames(generation: token)
        }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let angle = CGFloat(atan2(data.gravity.x, -data.gravity.y))
            let r = data.rotationRate, a = data.userAcceleration
            let steady = r.x * r.x + r.y * r.y + r.z * r.z < 0.0144 &&
                a.x * a.x + a.y * a.y + a.z * a.z < 0.0064
            self?.queue.async { self?.roll = angle; self?.deviceSteady = steady }
        }
    }

    private func publish(_ phase: GuidePhase, _ instruction: String, detail: String,
                         points: [CGPoint] = [], progress: Double = 0, trusted: Bool = false) {
        let tracking = corners.isEmpty ? (usesWorldCamera ? "Visual · no reliable depth" : "Visual lock") : "LiDAR · world lock"
        let value = GuideSnapshot(phase: phase, instruction: instruction, detail: detail, corners: points,
            progress: progress, zoom: usesWorldCamera ? zoom : fallbackZoom, tracking: tracking, trusted: trusted)
        DispatchQueue.main.async { self.snapshot = value }
    }

    private func rectanglePoints(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    private func midpoint(_ points: [CGPoint]) -> CGPoint {
        CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
    }
    private func boundingRect(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
}

private enum GuideError: LocalizedError {
    case encoding
    var errorDescription: String? { "The high-resolution photo could not be encoded. Close Guide and try again." }
}
