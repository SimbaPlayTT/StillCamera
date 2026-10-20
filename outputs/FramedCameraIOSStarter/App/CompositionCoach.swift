import CoreGraphics
import Foundation
import ImageIO
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

struct VisionComposition {
    let subjectBounds: CGRect?
    let subjectCenter: CGPoint?
    let suggestedAdjustment: String
    let detectedFace: Bool
    let detectedPose: Bool
}

enum CompositionCoach {
    enum FoundationModelState: Equatable {
        case available
        case requiresNewerOS
        case appleIntelligenceOff
        case modelPreparing
        case unsupportedLanguage
        case unavailable
    }

    static var foundationModelState: FoundationModelState {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .requiresNewerOS }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale.current) ? .available : .unsupportedLanguage
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .modelPreparing
        case .unavailable(.deviceNotEligible):
            return .unavailable
        case .unavailable(_):
            return .unavailable
        }
        #else
        return .requiresNewerOS
        #endif
    }

    static func analyze(frame: CGImage) -> VisionComposition {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let poseRequest = VNDetectHumanBodyPoseRequest()
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 4
        rectangleRequest.minimumConfidence = 0.55
        rectangleRequest.minimumSize = 0.12

        let handler = VNImageRequestHandler(cgImage: frame, orientation: .right, options: [:])
        do {
            try handler.perform([faceRequest, poseRequest, saliencyRequest, rectangleRequest])
        } catch {
            return VisionComposition(
                subjectBounds: nil,
                subjectCenter: nil,
                suggestedAdjustment: "Keep the horizon level and leave room around your subject.",
                detectedFace: false,
                detectedPose: false
            )
        }

        let face = faceRequest.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        let pose = poseRequest.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        let salient = saliencyRequest.results?.first?.salientObjects
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })?
            .boundingBox
        let rectangle = rectangleRequest.results?.first?.boundingBox
        let visionBox = face?.boundingBox ?? pose?.boundingBox ?? salient ?? rectangle
        let screenBox = visionBox.map(toTopLeftCoordinates)
        let center = screenBox.map { CGPoint(x: $0.midX, y: $0.midY) }

        return VisionComposition(
            subjectBounds: screenBox,
            subjectCenter: center,
            suggestedAdjustment: heuristic(for: center),
            detectedFace: face != nil,
            detectedPose: pose != nil
        )
    }

    @MainActor
    static func onDeviceSuggestion(for observation: CompositionObservation) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw CoachError.modelUnavailable }
        guard foundationModelState == .available else { throw CoachError.modelUnavailable }

        let session = LanguageModelSession(
            instructions: "You are a concise, practical camera composition guide. Based only on coarse, non-identifying framing measurements, offer one small physical camera adjustment in no more than eight words. Never identify a person or scene, praise or rate the photo, mention AI, or suggest editing. If the frame is balanced, say: Hold this frame."
        )
        let response = try await session.respond(to: modelPrompt(for: observation))
        let suggestion = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !suggestion.isEmpty else { throw CoachError.emptyResponse }
        return String(suggestion.prefix(100))
        #else
        throw CoachError.modelUnavailable
        #endif
    }

    static func modelPrompt(for observation: CompositionObservation) -> String {
        guard let center = observation.subjectCenter else {
            return "No clear subject location was found. Give one gentle composition cue based on thirds and a level horizon."
        }
        let horizontal: String
        if center.x < 0.34 { horizontal = "left third" }
        else if center.x > 0.66 { horizontal = "right third" }
        else { horizontal = "center" }

        let vertical: String
        if center.y < 0.34 { vertical = "upper third" }
        else if center.y > 0.66 { vertical = "lower third" }
        else { vertical = "middle" }

        let subject = observation.detectedFace ? "face" : (observation.detectedPose ? "person" : "subject")
        let level = abs(observation.horizonAngle) > 0.035 ? "horizon slightly tilted" : "horizon approximately level"
        return "The \(subject) is in the \(horizontal), \(vertical); \(level). Give one short adjustment or say Hold this frame."
    }

    private static func heuristic(for center: CGPoint?) -> String {
        guard let center else { return "Place your subject near a third and keep the horizon level." }
        if center.x < 0.31 { return "Shift the frame slightly right." }
        if center.x > 0.69 { return "Shift the frame slightly left." }
        if center.y < 0.31 { return "Lower the frame a little." }
        if center.y > 0.69 { return "Raise the frame slightly." }
        return "Hold the frame and keep the horizon level."
    }

    private static func toTopLeftCoordinates(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    enum CoachError: Error {
        case modelUnavailable
        case emptyResponse
    }
}
