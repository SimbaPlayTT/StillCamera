import XCTest
import simd
@testable import StillCamera

final class GuidedCaptureTests: XCTestCase {
    private let face = GuideSubject(bounds: CGRect(x: 0.16, y: 0.19, width: 0.13, height: 0.15), confidence: 0.95, kind: .face)
    private let building = GuideSubject(bounds: CGRect(x: 0.43, y: 0.18, width: 0.45, height: 0.66), confidence: 0.95, kind: .geometry)

    func testIntentChangesAspectAndPlacement() {
        let feed = GuideIntent(style: .balanced, prompt: "A minimal Instagram post with negative space")
        XCTAssertEqual(feed.style, .instagram); XCTAssertEqual(feed.aspect, .print); XCTAssertTrue(feed.breathingRoom)
        let story = GuideIntent(style: .instagram, prompt: "A centered story")
        XCTAssertEqual(story.aspect, .tall); XCTAssertTrue(story.centered)
        XCTAssertEqual(GuideIntent(style: .story, prompt: "A square portrait").aspect, .square)
    }

    func testPromptIsBounded() {
        XCTAssertEqual(GuideIntent(style: .balanced, prompt: String(repeating: "x", count: 1000)).prompt.count, 240)
    }

    func testStyleSelectsDifferentCandidateInsteadOfAlwaysLargestObject() throws {
        let subjects = [building, face]
        let portrait = try XCTUnwrap(GuidePlanner.choose(subjects: subjects, imageAspect: 0.75,
                                                       intent: GuideIntent(style: .portrait)))
        let architecture = try XCTUnwrap(GuidePlanner.choose(subjects: subjects, imageAspect: 0.75,
                                                            intent: GuideIntent(style: .architecture)))
        XCTAssertEqual(portrait.subject.kind, .face)
        XCTAssertEqual(architecture.subject.kind, .geometry)
        XCTAssertNotEqual(portrait.crop, architecture.crop)
    }

    func testPlannedCropKeepsSubjectAndCorrectOutputAspect() throws {
        for style in GuideStyle.allCases {
            let plan = try XCTUnwrap(GuidePlanner.choose(subjects: [face, building], imageAspect: 0.75,
                                                        intent: GuideIntent(style: style)))
            XCTAssertTrue(GuidePlanner.unit.contains(plan.crop))
            let retained = plan.crop.intersection(plan.subject.bounds)
            XCTAssertEqual(retained.width * retained.height,
                           plan.subject.bounds.width * plan.subject.bounds.height, accuracy: 0.0001)
            XCTAssertEqual(plan.crop.width / plan.crop.height * 0.75, plan.aspect.ratio, accuracy: 0.001)
        }
    }

    func testEmptyOrLowConfidenceSceneCannotInventTarget() {
        XCTAssertNil(GuidePlanner.choose(subjects: [], imageAspect: 0.75, intent: GuideIntent(style: .instagram)))
        let uncertain = GuideSubject(bounds: face.bounds, confidence: 0.2, kind: .face)
        XCTAssertNil(GuidePlanner.choose(subjects: [uncertain], imageAspect: 0.75, intent: GuideIntent(style: .portrait)))
        XCTAssertNil(GuidePlanner.choose(subjects: [face], imageAspect: 0, intent: GuideIntent(style: .portrait)))
    }

    func testLockedCompositionMovesWithSelectedDetailWithoutReplanning() throws {
        let plan = try XCTUnwrap(GuidePlanner.choose(subjects: [face], imageAspect: 0.75, intent: GuideIntent(style: .portrait)))
        let shifted = face.bounds.offsetBy(dx: 0.1, dy: -0.04)
        let tracked = plan.crop(tracking: shifted)
        XCTAssertEqual(tracked.minX, plan.crop.minX + 0.1, accuracy: 0.0001)
        XCTAssertEqual(tracked.minY, plan.crop.minY - 0.04, accuracy: 0.0001)
        XCTAssertEqual(tracked.width, plan.crop.width, accuracy: 0.0001)
        XCTAssertEqual(plan.subject.bounds, face.bounds, "The chosen target must remain immutable")
    }

    func testAutomaticCaptureRequiresContinuousSteadyDwellAndOnlyFiresOnce() {
        var gate = GuideCaptureGate()
        var fires = 0
        for index in 0...25 {
            let result = gate.update(time: Double(index) * 0.1, point: CGPoint(x: 0.5, y: 0.5),
                                     trusted: true, level: 0, ready: true)
            if index < 8 { XCTAssertFalse(result.fire) }
            if result.fire { fires += 1 }
        }
        XCTAssertEqual(fires, 1); XCTAssertTrue(gate.fired)
        gate.reset(); XCTAssertFalse(gate.fired)
    }

    func testLostTrackingFocusZoomAndTiltAllPreventAutomaticCapture() {
        for scenario in 0...3 {
            var gate = GuideCaptureGate()
            for index in 0...20 {
                let result = gate.update(time: Double(index) * 0.1, point: CGPoint(x: scenario == 3 ? 0.7 : 0.5, y: 0.5),
                    trusted: scenario != 0, level: scenario == 1 ? 0.2 : 0, ready: scenario != 2)
                XCTAssertFalse(result.fire)
            }
            XCTAssertFalse(gate.fired)
        }
    }

    func testStaleFramesAndMovementRestartDwell() {
        var gate = GuideCaptureGate()
        for index in 0...5 {
            _ = gate.update(time: Double(index) * 0.1, point: CGPoint(x: 0.5, y: 0.5), trusted: true, level: 0, ready: true)
        }
        let stale = gate.update(time: 1.2, point: CGPoint(x: 0.5, y: 0.5), trusted: true, level: 0, ready: true)
        XCTAssertEqual(stale.progress, 0); XCTAssertFalse(stale.fire)
        let moved = gate.update(time: 1.3, point: CGPoint(x: 0.53, y: 0.5), trusted: true, level: 0, ready: true)
        XCTAssertEqual(moved.progress, 0); XCTAssertFalse(moved.fire)
        let lost = gate.update(time: 1.4, point: CGPoint(x: 0.5, y: 0.5), trusted: false, level: 0, ready: true)
        XCTAssertEqual(lost.progress, 0)
    }

    func testInvalidMeasurementsCannotTriggerCapture() {
        var gate = GuideCaptureGate()
        let result = gate.update(time: .nan, point: CGPoint(x: CGFloat.infinity, y: 0.5), trusted: true, level: 0, ready: true)
        XCTAssertFalse(result.fire); XCTAssertEqual(result.progress, 0)
        XCTAssertEqual(GuidePlanner.zoomToFill(.zero), 1)
    }

    func testMovingTowardTargetCannotTriggerCaptureWithCenteredCrosshair() {
        var gate = GuideCaptureGate()
        for index in 0...30 {
            let result = gate.update(time: Double(index) * 0.1, point: CGPoint(x: 0.5, y: 0.5),
                trusted: true, level: 0, ready: true, scale: CGFloat(pow(1.05, Double(index))))
            XCTAssertFalse(result.fire)
        }
        XCTAssertFalse(gate.fired)
    }

    func testGuidedZoomIsCappedAndCenterRemainsFixed() {
        XCTAssertEqual(GuidePlanner.zoomToFill(CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)), 2)
        XCTAssertEqual(GuidePlanner.zoomToFill(CGRect(x: 0, y: 0, width: 2, height: 2)), 1)
        let center = GuidePlanner.zoomed(CGPoint(x: 0.5, y: 0.5), by: 2)
        XCTAssertEqual(center, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(GuidePlanner.instruction(target: CGPoint(x: 0.5, y: 0.2), level: 0), "Move phone up")
    }

    func testWorldFramePlaneFacesCameraUsingARKitYNormalConvention() throws {
        var camera = simd_float4x4(simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0)))
        camera.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let plane = try XCTUnwrap(GuideWorldGeometry.cameraFacingPlane(camera: camera, depth: 2))
        XCTAssertEqual(plane.columns.1, camera.columns.2)
        for local in [SIMD4<Float>(0, 0, 0, 1), SIMD4<Float>(0.7, 0, -0.4, 1)] {
            let worldPoint = plane * local
            let inCamera = simd_inverse(camera) * worldPoint
            XCTAssertEqual(inCamera.z, -2, accuracy: 0.0001)
            var movedCamera = camera
            movedCamera.columns.3.x += 0.5
            let afterMoving = simd_inverse(movedCamera) * worldPoint
            XCTAssertNotEqual(inCamera.x, afterMoving.x, "A fixed world target must shift on screen when the camera moves")
        }
        XCTAssertNil(GuideWorldGeometry.cameraFacingPlane(camera: camera, depth: .nan))
    }
}
