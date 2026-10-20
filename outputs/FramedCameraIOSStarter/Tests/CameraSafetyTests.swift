import XCTest
import UIKit
@testable import StillCamera

final class CameraSafetyTests: XCTestCase {
    func testCaptureAndDeviceChangesOnlyAllowedInRunningState() {
        for state in [SessionState.idle, .configuring, .switching, .capturing, .paused, .interrupted, .failed] {
            XCTAssertFalse(state.allowsCapture, "Capture must be rejected while \(state)")
            XCTAssertFalse(state.allowsConfiguration, "Hardware changes must be rejected while \(state)")
        }
        XCTAssertTrue(SessionState.running.allowsCapture)
        XCTAssertTrue(SessionState.running.allowsConfiguration)
    }

    func testTripleCameraZoomUsesWideCameraAsOneX() {
        let presets = CameraMath.displayedPresets(switchFactors: [2, 8], multiplier: 0.5, minimum: 1, maximum: 20)
        XCTAssertEqual(presets.map(\.factor), [0.5, 1, 2, 4])
        XCTAssertFalse(presets.contains { $0.factor == 5 }, "Do not invent a 5x optical lens")
        let single = CameraMath.displayedPresets(switchFactors: [], multiplier: 1, minimum: 1, maximum: 1)
        XCTAssertEqual(single.map(\.factor), [1])
    }

    func testInvalidZoomAndRangeClamping() {
        XCTAssertEqual(CameraMath.clamp(.nan, minimum: 1, maximum: 10), 1)
        XCTAssertEqual(CameraMath.clamp(0.1, minimum: 0.5, maximum: 10), 0.5)
        XCTAssertEqual(CameraMath.clamp(99, minimum: 0.5, maximum: 10), 10)
    }

    func testAspectFillCoordinateRoundTripIncludesCroppedEdges() {
        let image = CGSize(width: 300, height: 400), viewport = CGSize(width: 300, height: 300)
        let original = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5)
        let view = CameraMath.viewRect(original, imageSize: image, viewSize: viewport)
        XCTAssertEqual(view.minY, 30, accuracy: 0.001)
        let restored = CameraMath.imageRect(view, imageSize: image, viewSize: viewport)
        XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(restored.minY, original.minY, accuracy: 0.001)
        XCTAssertEqual(restored.width, original.width, accuracy: 0.001)
        XCTAssertEqual(restored.height, original.height, accuracy: 0.001)
    }

    func testAllAspectCropsStayCenteredAndInsideOriginal() {
        let extent = CGRect(x: 10, y: 20, width: 300, height: 400)
        for aspect in CaptureAspect.allCases {
            let result = CameraMath.crop(in: extent, ratio: aspect.ratio)
            XCTAssertTrue(extent.contains(result))
            XCTAssertEqual(result.midX, extent.midX, accuracy: 0.001)
            XCTAssertEqual(result.midY, extent.midY, accuracy: 0.001)
            XCTAssertEqual(result.width / result.height, aspect.ratio, accuracy: 0.001)
        }
    }

    func testRecipeRoundTripPreservesAdjustmentsAndOriginalReference() throws {
        var recipe = EditRecipe()
        recipe["exposure"] = 0.75; recipe.hue[4] = 0.2; recipe.curve[2] = 0.6
        recipe.aspect = .square; recipe.frame = "Specs"; recipe.dateStamp = true
        let entry = LibraryPhoto(id: UUID(), sourceExtension: "heic", hasRaw: true, metadata: PhotoMetadata(), recipe: recipe)
        let decoded = try JSONDecoder().decode(LibraryPhoto.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.recipe, recipe)
        XCTAssertEqual(decoded.originalURL.lastPathComponent, "original.heic")
        XCTAssertEqual(decoded.rawURL.lastPathComponent, "original.dng")
    }

    @MainActor
    func testExposureAdjustmentChangesRenderedImage() async throws {
        let photo = LibraryPhoto(id: UUID(), sourceExtension: "png", hasRaw: false, metadata: PhotoMetadata(), recipe: EditRecipe())
        try FileManager.default.createDirectory(at: photo.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: photo.directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 80)).image { context in
            UIColor(white: 0.3, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
        }
        try XCTUnwrap(image.pngData()).write(to: photo.originalURL)
        let baseline = try await PhotoRenderer.shared.render(photo, recipe: EditRecipe(), maximumSide: 80)
        var brighter = EditRecipe(); brighter["exposure"] = 1
        let changed = try await PhotoRenderer.shared.render(photo, recipe: brighter, maximumSide: 80)
        XCTAssertEqual(baseline.size, changed.size)
        XCTAssertNotEqual(baseline.pngData(), changed.pngData(), "Exposure must alter rendered image data")
    }

    @MainActor
    func testRendererExportsEffectsAndFramesWithoutChangingOriginal() async throws {
        let photo = LibraryPhoto(id: UUID(), sourceExtension: "png", hasRaw: false, metadata: PhotoMetadata(), recipe: EditRecipe())
        try FileManager.default.createDirectory(at: photo.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: photo.directory) }
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        }
        let original = try XCTUnwrap(source.pngData())
        try original.write(to: photo.originalURL)
        var recipe = EditRecipe()
        recipe.aspect = .square; recipe.frame = "Specs"; recipe.dateStamp = true; recipe.look = "Amber"
        recipe.hue[0] = 0.2; recipe["shadowColor"] = 0.1
        for name in ["grain", "halation", "glow", "leak", "scratches", "dust", "motion", "vignette"] { recipe[name] = 0.4 }
        let result = try await PhotoRenderer.shared.render(photo, recipe: recipe, maximumSide: 100)
        XCTAssertGreaterThan(result.size.height, result.size.width)
        XCTAssertNotNil(result.jpegData(compressionQuality: 0.8))
        XCTAssertEqual(try Data(contentsOf: photo.originalURL), original)
    }
}
