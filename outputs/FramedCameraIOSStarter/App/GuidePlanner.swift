import CoreGraphics
import Foundation
import Vision
import CoreVideo
import CoreImage
import ImageIO
import simd

enum GuideWorldGeometry {
    /// ARKit's plane has a +Y normal (its local XZ plane), unlike a camera's image XY plane.
    static func cameraFacingPlane(camera: simd_float4x4, depth: Float) -> simd_float4x4? {
        guard depth.isFinite, depth > 0.2 else { return nil }
        var plane = camera
        plane.columns.1 = camera.columns.2
        plane.columns.2 = -camera.columns.1
        plane.columns.3 = camera.columns.3 - camera.columns.2 * depth
        return plane
    }
}

enum GuideStyle: String, CaseIterable, Identifiable {
    case balanced = "Everyday", instagram = "Instagram post", portrait = "Portrait"
    case architecture = "Architecture", detail = "Details", story = "Story", scenery = "Scenery"
    var id: String { rawValue }
    var aspect: CaptureAspect {
        switch self { case .instagram, .portrait: return .print; case .story: return .tall; default: return .standard }
    }
}

struct GuideIntent {
    var style: GuideStyle
    var prompt: String
    var centered: Bool
    var breathingRoom: Bool
    var aspect: CaptureAspect

    init(style: GuideStyle, prompt: String = "") {
        self.style = style
        self.prompt = String(prompt.prefix(240))
        let text = self.prompt.lowercased()
        if text.contains("instagram") || text.contains("social post") { self.style = .instagram }
        if text.contains("portrait") || text.contains("headshot") { self.style = .portrait }
        if text.contains("architecture") || text.contains("building") { self.style = .architecture }
        if text.contains("detail") || text.contains("close up") { self.style = .detail }
        if text.contains("landscape") || text.contains("scenery") { self.style = .scenery }
        if text.contains("story") || text.contains("reel") { self.style = .story }
        centered = text.contains("center") || text.contains("symmetr") || self.style == .architecture
        breathingRoom = text.contains("minimal") || text.contains("negative space") || text.contains("room for text")
        aspect = text.contains("square") ? .square : self.style.aspect
    }
}

struct GuideSubject {
    enum Kind: Equatable { case face, person, salient, geometry }
    let bounds: CGRect
    let confidence: Float
    let kind: Kind
}

struct GuidePlan {
    let subject: GuideSubject
    let crop: CGRect
    let score: CGFloat
    let aspect: CaptureAspect
    let title: String

    /// Freeze the composition relative to a tracked detail. Detection never silently picks a new subject.
    func crop(tracking rect: CGRect) -> CGRect {
        let sx = rect.width / max(subject.bounds.width, 0.001)
        let sy = rect.height / max(subject.bounds.height, 0.001)
        return CGRect(x: rect.minX + (crop.minX - subject.bounds.minX) * sx,
                      y: rect.minY + (crop.minY - subject.bounds.minY) * sy,
                      width: crop.width * sx, height: crop.height * sy)
    }
}

enum GuidePlanner {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// A bounded crop search over faces, people, salient details and architectural edges.
    /// This is a composition heuristic, not an aesthetic quality guarantee.
    static func choose(subjects: [GuideSubject], imageAspect: CGFloat, intent: GuideIntent) -> GuidePlan? {
        guard imageAspect.isFinite, imageAspect > 0 else { return nil }
        let usable = subjects.filter {
            $0.confidence.isFinite && $0.confidence >= 0.45 && $0.bounds.width > 0.025 && $0.bounds.height > 0.025 &&
                unit.contains($0.bounds) && $0.bounds.width * $0.bounds.height < 0.96
        }.prefix(12)
        let normalizedRatio = intent.aspect.ratio / imageAspect
        var best: GuidePlan?
        for subject in usable {
            let occupancy: CGFloat
            switch subject.kind { case .face: occupancy = 0.42; case .person: occupancy = 0.72
            case .salient: occupancy = intent.style == .detail ? 0.72 : 0.58; case .geometry: occupancy = 0.8 }
            let base = max(subject.bounds.height / occupancy, subject.bounds.width / (occupancy * normalizedRatio))
            let anchors: [CGFloat] = intent.centered ? [0.5] : [1 / 3, 0.5, 2 / 3]
            for scale in [CGFloat(1), 1.22, 1.48] {
                let padding: CGFloat = intent.breathingRoom ? 1.25 : 1
                let height = min(max(base * scale * padding, 0.4), min(1, 1 / normalizedRatio))
                let width = height * normalizedRatio
                for anchor in anchors {
                    let vertical: CGFloat = subject.kind == .face ? 0.34 : 0.5
                    let x = min(max(subject.bounds.midX - anchor * width, 0), 1 - width)
                    let y = min(max(subject.bounds.midY - vertical * height, 0), 1 - height)
                    let crop = CGRect(x: x, y: y, width: width, height: height)
                    let value = score(crop: crop, subject: subject, others: Array(usable), intent: intent)
                    if best == nil || value > best!.score {
                        best = GuidePlan(subject: subject, crop: crop, score: value, aspect: intent.aspect,
                            title: title(subject.kind, intent: intent))
                    }
                }
            }
        }
        return best
    }

    private static func score(crop: CGRect, subject: GuideSubject, others: [GuideSubject], intent: GuideIntent) -> CGFloat {
        let area = subject.bounds.width * subject.bounds.height
        let visible = crop.intersection(subject.bounds)
        guard !visible.isNull, area > 0 else { return -100 }
        let retained = visible.width * visible.height / area
        // Never prefer a crop that slices through the chosen face or person.
        if retained < 0.97 { return -100 }
        let x = (subject.bounds.midX - crop.minX) / crop.width
        let y = (subject.bounds.midY - crop.minY) / crop.height
        let placement = intent.centered ? abs(x - 0.5) : min(abs(x - 1 / 3), abs(x - 2 / 3))
        let desiredArea: CGFloat = subject.kind == .face ? 0.12 : subject.kind == .person ? 0.34 : 0.3
        let proportion = area / (crop.width * crop.height)
        var value = CGFloat(subject.confidence) * 2 + 1 - placement * 1.5 - abs(proportion - desiredArea) * 2
        value -= abs(y - (subject.kind == .face ? 0.34 : 0.5)) * 0.6
        switch (intent.style, subject.kind) {
        case (.portrait, .face), (.portrait, .person): value += 2
        case (.architecture, .geometry), (.detail, .salient): value += 1.5
        case (.scenery, .geometry), (.scenery, .salient): value += crop.width * crop.height
        default: break
        }
        // Prefer complete surrounding faces over crops that cut bystanders in half.
        for other in others where other.kind == .face {
            let part = crop.intersection(other.bounds)
            if !part.isNull {
                let fraction = part.width * part.height / max(other.bounds.width * other.bounds.height, 0.001)
                if fraction > 0.1 && fraction < 0.95 { value -= 1.5 }
            }
        }
        return value
    }

    private static func title(_ kind: GuideSubject.Kind, intent: GuideIntent) -> String {
        if intent.style == .instagram { return "A frame for your feed" }
        switch kind { case .face, .person: return "Keep the subject in this frame"
        case .geometry: return "Follow the lines"; case .salient: return "A detail worth framing" }
    }

    static func instruction(target: CGPoint, level: CGFloat) -> String {
        if !target.x.isFinite || !target.y.isFinite { return "Find the target again" }
        let dx = target.x - 0.5, dy = target.y - 0.5
        if max(abs(dx), abs(dy)) > 0.045 {
            if abs(dx) > abs(dy) { return dx > 0 ? "Move phone right" : "Move phone left" }
            return dy > 0 ? "Move phone down" : "Move phone up"
        }
        return abs(level) > 0.055 ? "Level your phone" : "Hold steady"
    }

    static func zoomToFill(_ bounds: CGRect, maximum: CGFloat = 2) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        return CameraMath.clamp(min(1 / bounds.width, 1 / bounds.height), minimum: 1, maximum: maximum)
    }

    static func zoomed(_ point: CGPoint, by zoom: CGFloat) -> CGPoint {
        CGPoint(x: 0.5 + (point.x - 0.5) * zoom, y: 0.5 + (point.y - 0.5) * zoom)
    }
}

/// One shot per scan. Losing confidence, stale frames, motion or leaving the center resets the dwell.
struct GuideCaptureGate {
    private(set) var fired = false
    private var began: TimeInterval?
    private var lastTime: TimeInterval?
    private var previous: CGPoint?
    private var previousScale: CGFloat?
    mutating func reset() { self = GuideCaptureGate() }

    mutating func update(time: TimeInterval, point: CGPoint, trusted: Bool, level: CGFloat,
                         ready: Bool, dwell: TimeInterval = 0.8, scale: CGFloat = 1) -> (progress: Double, fire: Bool) {
        defer { lastTime = time; previous = point; previousScale = scale }
        guard !fired, time.isFinite, point.x.isFinite, point.y.isFinite, trusted, ready,
              scale.isFinite, scale > 0,
              abs(point.x - 0.5) < 0.045, abs(point.y - 0.5) < 0.045, abs(level) < 0.055 else {
            began = nil; return (0, false)
        }
        if let lastTime, time <= lastTime || time - lastTime > 0.35 { began = nil }
        if let previous, let lastTime, time > lastTime {
            let elapsed = CGFloat(max(time - lastTime, 0.01))
            if hypot(point.x - previous.x, point.y - previous.y) / elapsed > 0.2 { began = nil }
            if let previousScale, previousScale > 0,
               abs(log(scale / previousScale)) / elapsed > 0.22 { began = nil }
        }
        if began == nil { began = time }
        let progress = min(max((time - (began ?? time)) / max(dwell, 0.4), 0), 1)
        if progress >= 1 { fired = true; return (1, true) }
        return (progress, false)
    }
}

/// Reuses a small pixel buffer. No full-resolution UIImage allocation in the live analysis path.
final class GuideVision {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var workingBuffer: CVPixelBuffer?
    private var sequence = VNSequenceRequestHandler()
    private var tracker: VNTrackObjectRequest?

    func upright(_ input: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: input).oriented(orientation)
        let scale = min(1, 640 / max(image.extent.width, image.extent.height))
        let width = max(2, Int(image.extent.width * scale) / 2 * 2)
        let height = max(2, Int(image.extent.height * scale) / 2 * 2)
        if workingBuffer == nil || CVPixelBufferGetWidth(workingBuffer!) != width || CVPixelBufferGetHeight(workingBuffer!) != height {
            var next: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferCGImageCompatibilityKey as String: true]
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      attributes as CFDictionary, &next) == kCVReturnSuccess else { return nil }
            workingBuffer = next
        }
        guard let workingBuffer else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                            y: CGFloat(height) / image.extent.height))
        context.render(scaled, to: workingBuffer)
        return workingBuffer
    }

    func detect(_ buffer: CVPixelBuffer) throws -> [GuideSubject] {
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 5; rectangles.minimumConfidence = 0.6; rectangles.minimumSize = 0.12
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([faces, people, saliency, rectangles])
        var subjects: [GuideSubject] = []
        for face in faces.results ?? [] { subjects.append(subject(face.boundingBox, face.confidence, .face)) }
        for person in people.results ?? [] { subjects.append(subject(person.boundingBox, person.confidence, .person)) }
        for item in saliency.results?.first?.salientObjects ?? [] { subjects.append(subject(item.boundingBox, item.confidence, .salient)) }
        for rect in rectangles.results ?? [] { subjects.append(subject(rect.boundingBox, rect.confidence, .geometry)) }
        return subjects
    }

    func lock(_ bounds: CGRect) {
        sequence = VNSequenceRequestHandler()
        let rect = CGRect(x: bounds.minX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height)
        tracker = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rect))
        tracker?.trackingLevel = .accurate
    }

    func track(_ buffer: CVPixelBuffer) throws -> CGRect? {
        guard let tracker else { return nil }
        try sequence.perform([tracker], on: buffer, orientation: .up)
        guard let observation = tracker.results?.first as? VNDetectedObjectObservation, observation.confidence > 0.55 else { return nil }
        tracker.inputObservation = observation
        let rect = observation.boundingBox
        return CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    private func subject(_ box: CGRect, _ confidence: Float, _ kind: GuideSubject.Kind) -> GuideSubject {
        GuideSubject(bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                     confidence: confidence, kind: kind)
    }
}
