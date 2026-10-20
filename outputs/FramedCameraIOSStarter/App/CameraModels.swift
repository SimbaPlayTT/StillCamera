import AVFoundation
import Foundation
import CoreGraphics

enum CameraAuthorizationState: Equatable {
    case checking, authorized, denied, restricted, unavailable
    case failed(String)
}

enum SessionState: String {
    case idle, configuring, running, switching, capturing, paused, interrupted, failed
    var allowsCapture: Bool { self == .running }
    var allowsConfiguration: Bool { self == .running }
}

enum CaptureFormat: String, CaseIterable, Identifiable {
    case heif, raw
    var id: String { rawValue }
    var title: String { self == .raw ? "RAW + photo" : "HEIF / JPEG" }
}

enum CaptureAspect: String, CaseIterable, Identifiable, Codable, Hashable {
    case standard = "3:4", print = "4:5", square = "1:1", tall = "9:16"
    var id: String { rawValue }
    var ratio: CGFloat {
        switch self {
        case .standard: return 3 / 4
        case .print: return 4 / 5
        case .square: return 1
        case .tall: return 9 / 16
        }
    }
}

struct LensPreset: Identifiable, Equatable {
    let factor: CGFloat
    var id: CGFloat { factor }
    var title: String { String(format: factor < 1 ? "%.1f×" : "%g×", Double(factor)) }
}

struct CompositionObservation {
    let subjectBounds: CGRect?
    let subjectCenter: CGPoint?
    let horizonAngle: CGFloat
    let suggestedAdjustment: String
    let detectedFace: Bool
    let detectedPose: Bool
    static let neutral = CompositionObservation(subjectBounds: nil, subjectCenter: nil, horizonAngle: 0,
        suggestedAdjustment: "Choose a subject to frame.", detectedFace: false, detectedPose: false)
}

struct PhotoMetadata: Codable {
    var date = Date()
    var lens = "Camera"
    var iso: Double = 0
    var exposure: Double = 0
    var focalLength: Double = 0
}

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let processedData: Data
    let rawData: Data?
    let processedFileExtension: String
    let metadata: PhotoMetadata
    let aspect: CaptureAspect
}

enum CameraMath {
    static func horizon(gravityX x: Double, gravityY y: Double) -> CGFloat {
        // A horizon is undefined when pointing almost straight up or down (for example a flat lay).
        guard x.isFinite, y.isFinite, hypot(x, y) >= 0.3 else { return 0 }
        return CGFloat(atan2(x, -y))
    }
    static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard value.isFinite, minimum.isFinite, maximum.isFinite, minimum <= maximum else { return minimum }
        return min(max(value, minimum), maximum)
    }

    /// A centered crop in upright image coordinates. The original is always retained.
    static func crop(in extent: CGRect, ratio: CGFloat) -> CGRect {
        guard extent.width > 0, extent.height > 0, ratio > 0 else { return .zero }
        let width = min(extent.width, extent.height * ratio)
        let height = width / ratio
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height)
    }

    /// Vision's upright top-left normalized rectangle -> aspect-filled portrait viewport.
    static func viewRect(_ rect: CGRect, imageSize: CGSize, viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offsetX = (viewSize.width - imageSize.width * scale) / 2
        let offsetY = (viewSize.height - imageSize.height * scale) / 2
        return CGRect(x: rect.minX * imageSize.width * scale + offsetX,
                      y: rect.minY * imageSize.height * scale + offsetY,
                      width: rect.width * imageSize.width * scale,
                      height: rect.height * imageSize.height * scale)
    }

    static func imageRect(_ rect: CGRect, imageSize: CGSize, viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offsetX = (viewSize.width - imageSize.width * scale) / 2
        let offsetY = (viewSize.height - imageSize.height * scale) / 2
        return CGRect(x: (rect.minX - offsetX) / (imageSize.width * scale),
                      y: (rect.minY - offsetY) / (imageSize.height * scale),
                      width: rect.width / (imageSize.width * scale), height: rect.height / (imageSize.height * scale))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func displayedPresets(switchFactors: [CGFloat], multiplier: CGFloat,
                                 minimum: CGFloat, maximum: CGFloat) -> [LensPreset] {
        let hardware = ([minimum] + switchFactors).map { $0 * multiplier }
        let candidates = hardware + [1, 2]
        var values: [CGFloat] = []
        for value in candidates.sorted() where value >= minimum * multiplier - 0.01 && value <= maximum * multiplier + 0.01 {
            let rounded = (value * 10).rounded() / 10
            if !values.contains(where: { abs($0 - rounded) < 0.05 }) { values.append(rounded) }
        }
        return values.map { LensPreset(factor: $0) }
    }
}
