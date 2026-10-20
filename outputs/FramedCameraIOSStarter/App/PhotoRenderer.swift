import CoreImage
import UIKit

/// One renderer bounds GPU work. Cancelled slider requests are discarded before rendering.
actor PhotoRenderer {
    static let shared = PhotoRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    static let looks = ["Original", "Daylight", "Amber", "Slate", "Silver"]
    static let frames = ["None", "Plain", "White", "Paper", "Black", "Negative", "Specs"]

    func render(_ entry: LibraryPhoto, recipe: EditRecipe, maximumSide: CGFloat? = 1400) throws -> UIImage {
        try Task.checkCancellation()
        let url = entry.hasRaw ? entry.rawURL : entry.originalURL
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            ?? CIImage(contentsOf: entry.originalURL, options: [.applyOrientationProperty: true]) else { throw LibraryError.invalidImage }
        image = image.cropped(to: CameraMath.crop(in: image.extent, ratio: recipe.aspect.ratio))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let maximumSide {
            let scale = min(1, maximumSide / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = image.extent
        var r = recipe
        switch recipe.look {
        case "Daylight": r["temperature"] += 0.12; r["contrast"] += 0.12; r["saturation"] -= 0.06
        case "Amber": r["temperature"] += 0.3; r["fade"] += 0.12; r["grain"] += 0.18
        case "Slate": r["temperature"] -= 0.16; r["contrast"] += 0.18; r["saturation"] -= 0.25
        case "Silver": r["saturation"] = -1; r["contrast"] += 0.22; r["grain"] += 0.18
        default: break
        }
        image = filter("CIExposureAdjust", image, ["inputEV": r["exposure"]])
        image = filter("CITemperatureAndTint", image, ["inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 + r["temperature"] * 2200, y: r["tint"] * 80)])
        image = filter("CIColorControls", image, ["inputContrast": 1 + r["contrast"] * 0.4,
            "inputSaturation": max(0, 1 + r["saturation"])])
        image = filter("CIHighlightShadowAdjust", image, ["inputHighlightAmount": 1 + min(0, r["highlights"]) * 0.65,
            "inputShadowAmount": r["shadows"] * 0.7])
        var curveParameters: [String: Any] = [:]
        for i in 0..<5 {
            var y = r.curve[i]
            if i == 0 { y += r["blacks"] * 0.13 + r["fade"] * 0.18 }
            if i == 4 { y += r["whites"] * 0.16 }
            if i == 3 { y += max(0, r["highlights"]) * 0.12 }
            curveParameters["inputPoint\(i)"] = CIVector(x: CGFloat(i) / 4, y: min(max(y, 0), 1))
        }
        image = filter("CIToneCurve", image, curveParameters)
        if recipe.hue.contains(where: { $0 != 0 }) || recipe.saturation.contains(where: { $0 != 0 }) ||
            recipe.luminance.contains(where: { $0 != 0 }) || ["red", "green", "blue", "shadowColor", "highlightColor"].contains(where: { r[$0] != 0 }) {
            image = filter("CIColorCube", image, ["inputCubeDimension": 16, "inputCubeData": colorCube(r)])
        }
        let unit = max(extent.width, extent.height) / 1400
        if r["halation"] > 0 {
            let bloom = filter("CIBloom", image.clampedToExtent(), ["inputRadius": 9 * unit, "inputIntensity": r["halation"] * 0.7])
            image = bloom.cropped(to: extent)
        }
        if r["glow"] > 0 {
            image = filter("CIBloom", image.clampedToExtent(), ["inputRadius": 22 * unit, "inputIntensity": r["glow"]]).cropped(to: extent)
        }
        if r["motion"] > 0 {
            image = filter("CIMotionBlur", image.clampedToExtent(), ["inputRadius": r["motion"] * 24 * unit, "inputAngle": 0.2]).cropped(to: extent)
        }
        if r["grain"] > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grain = filter("CIColorMatrix", noise, ["inputRVector": CIVector(x: 0.3, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.3, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0.3, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: r["grain"] * 0.35)])
            let centeredGrain = filter("CIColorMatrix", grain, ["inputBiasVector": CIVector(x: 0.35, y: 0.35, z: 0.35, w: 0)])
            image = filter("CISoftLightBlendMode", centeredGrain.cropped(to: extent), [kCIInputBackgroundImageKey: image])
        }
        if r["leak"] > 0, let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: extent.width * 0.05, y: extent.height * 0.7),
            "inputRadius0": 0, "inputRadius1": extent.width * 0.85,
            "inputColor0": CIColor(red: 1, green: 0.25, blue: 0.03, alpha: r["leak"] * 0.55),
            "inputColor1": CIColor(red: 1, green: 0.4, blue: 0, alpha: 0)])?.outputImage {
            image = gradient.cropped(to: extent).composited(over: image)
        }
        if r["scratches"] > 0 || r["dust"] > 0 {
            let texture = blemishes(r, seed: entry.id.uuidString.utf8.reduce(UInt64(1)) { $0 &* 31 &+ UInt64($1) })
            image = texture.transformed(by: CGAffineTransform(scaleX: extent.width / 512, y: extent.height / 512))
                .cropped(to: extent).composited(over: image)
        }
        image = filter("CIVignette", image, ["inputIntensity": r["vignette"] * 1.5, "inputRadius": extent.width * 0.6])
        try Task.checkCancellation()
        guard let cgImage = context.createCGImage(image, from: extent) else { throw LibraryError.invalidImage }
        let result = finish(UIImage(cgImage: cgImage), recipe: recipe, metadata: entry.metadata)
        if maximumSide == nil { context.clearCaches() }
        return result
    }

    private func filter(_ name: String, _ image: CIImage, _ parameters: [String: Any]) -> CIImage {
        var values = parameters
        values[kCIInputImageKey] = image
        return CIFilter(name: name, parameters: values)?.outputImage ?? image
    }

    private func colorCube(_ r: EditRecipe) -> Data {
        var data: [Float] = []
        data.reserveCapacity(16 * 16 * 16 * 4)
        for b in 0..<16 { for g in 0..<16 { for red in 0..<16 {
            let rgb = (Double(red) / 15, Double(g) / 15, Double(b) / 15)
            var (h, s, l) = hsl(rgb.0, rgb.1, rgb.2)
            for index in 0..<6 {
                let distance = min(abs(h - Double(index) / 6), 1 - abs(h - Double(index) / 6))
                let weight = max(0, 1 - distance * 6)
                h += r.hue[index] * weight / 12
                s *= 1 + r.saturation[index] * weight
                l += r.luminance[index] * weight * 0.18
            }
            var color = rgbFromHSL(h, min(max(s, 0), 1), min(max(l, 0), 1))
            color.0 *= 1 + r["red"] * 0.2
            color.1 *= 1 + r["green"] * 0.2
            color.2 *= 1 + r["blue"] * 0.2
            let shadow = rgbFromHSL(r["shadowHue"], 0.7, 0.5)
            let highlight = rgbFromHSL(r["highlightHue"], 0.7, 0.5)
            let darkWeight = (1 - l) * r["shadowColor"] * 0.25
            let lightWeight = l * r["highlightColor"] * 0.25
            color.0 += (shadow.0 - 0.5) * darkWeight + (highlight.0 - 0.5) * lightWeight
            color.1 += (shadow.1 - 0.5) * darkWeight + (highlight.1 - 0.5) * lightWeight
            color.2 += (shadow.2 - 0.5) * darkWeight + (highlight.2 - 0.5) * lightWeight
            data += [Float(min(max(color.0, 0), 1)), Float(min(max(color.1, 0), 1)), Float(min(max(color.2, 0), 1)), 1]
        } } }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let hi = max(r, max(g, b)), lo = min(r, min(g, b)), delta = hi - lo
        let l = (hi + lo) / 2
        guard delta > 0 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        var h = hi == r ? (g - b) / delta : hi == g ? (b - r) / delta + 2 : (r - g) / delta + 4
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, l)
    }

    private func rgbFromHSL(_ hue: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let h = (hue - floor(hue)) * 6
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }

    private func blemishes(_ r: EditRecipe, seed: UInt64) -> CIImage {
        var state = seed
        func next() -> CGFloat { state = state &* 6364136223846793005 &+ 1; return CGFloat(state % 10000) / 10000 }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
        let texture = renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.withAlphaComponent(r["dust"] * 0.45).cgColor)
            for _ in 0..<Int(r["dust"] * 65) {
                let x = next() * 512, y = next() * 512, radius = 0.5 + next() * 1.8
                ctx.cgContext.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
            }
            ctx.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(r["scratches"] * 0.35).cgColor)
            ctx.cgContext.setLineWidth(0.4)
            for _ in 0..<Int(r["scratches"] * 8) {
                let x = next() * 512, y = next() * 512
                ctx.cgContext.move(to: CGPoint(x: x, y: y))
                ctx.cgContext.addLine(to: CGPoint(x: x + next() * 3, y: min(512, y + 80 + next() * 200)))
                ctx.cgContext.strokePath()
            }
        }
        let source = CIImage(image: texture) ?? CIImage.empty()
        return source.transformed(by: CGAffineTransform(scaleX: 512 / source.extent.width, y: 512 / source.extent.height))
    }

    private func finish(_ image: UIImage, recipe: EditRecipe, metadata: PhotoMetadata) -> UIImage {
        let framed = recipe.frame != "None"
        guard framed || recipe.dateStamp else { return image }
        let width = image.size.width, height = image.size.height
        let border = framed ? width * (recipe.frame == "Plain" ? 0.025 : 0.06) : 0
        let caption = ["Specs", "Negative"].contains(recipe.frame) ? width * 0.08 : 0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width + 2 * border, height: height + 2 * border + caption), format: format).image { ctx in
            let dark = ["Black", "Negative"].contains(recipe.frame)
            (dark ? UIColor(white: 0.06, alpha: 1) : recipe.frame == "Paper" ? UIColor(red: 0.94, green: 0.92, blue: 0.87, alpha: 1) : .white).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width + 2 * border, height: height + 2 * border + caption))
            image.draw(in: CGRect(x: border, y: border, width: width, height: height))
            if caption > 0 {
                let line = recipe.frame == "Specs" ? String(format: "%@  ·  %.0fmm  ·  ISO %.0f  ·  1/%.0fs", metadata.lens, metadata.focalLength, metadata.iso, 1 / max(metadata.exposure, 0.00001)) : "STILL  /  \(metadata.date.formatted(date: .numeric, time: .omitted))"
                (line as NSString).draw(in: CGRect(x: border, y: height + border * 1.35, width: width, height: caption), withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: width * 0.021, weight: .regular),
                    .foregroundColor: dark ? UIColor.white : UIColor.black])
            }
            if recipe.dateStamp {
                let text = metadata.date.formatted(date: .numeric, time: .omitted)
                let font = UIFont.monospacedSystemFont(ofSize: width * 0.026, weight: .medium)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(red: 1, green: 0.65, blue: 0.25, alpha: 1)]
                let textWidth = (text as NSString).size(withAttributes: attributes).width
                (text as NSString).draw(at: CGPoint(x: width + border - textWidth - width * 0.04, y: height + border - width * 0.08), withAttributes: attributes)
            }
        }
    }
}
