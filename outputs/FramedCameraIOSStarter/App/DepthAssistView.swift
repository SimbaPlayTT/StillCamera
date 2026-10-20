import ARKit
import SceneKit
import SwiftUI

struct DepthAssistView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var depth = DepthSession()
    var body: some View {
        ZStack {
            DepthPreview(model: depth).ignoresSafeArea()
            VStack {
                HStack {
                    Text("DEPTH ASSIST").font(.caption.monospaced())
                    Spacer()
                    Button("Done") { depth.stop(); dismiss() }.frame(minWidth: 44, minHeight: 44)
                }.padding().background(.black.opacity(0.7))
                Spacer()
                Image(systemName: "plus").font(.title2).accessibilityHidden(true)
                Spacer()
                VStack(spacing: 8) {
                    Text(depth.distance.map { String(format: "%.2f m", $0) } ?? "Aim at a surface")
                        .font(.title.monospacedDigit())
                    Text(depth.message).font(.subheadline).multilineTextAlignment(.center)
                    Text("Center-point distance · approximate LiDAR measurement")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity).background(.black.opacity(0.8))
            }
        }
        .background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .onDisappear { depth.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { depth.start() } else { depth.stop() } }
    }
}

final class DepthSession: NSObject, ObservableObject, ARSessionDelegate {
    static var supported: Bool {
        ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    @Published var distance: Float?
    @Published var message = "Move slowly. Depth improves with a clear, textured surface."
    let session = ARSession()
    private let queue = DispatchQueue(label: "still.depth", qos: .utility)
    private var lastTimestamp: TimeInterval = 0
    private var filteredDistance: Float?

    override init() { super.init(); session.delegate = self; session.delegateQueue = queue }
    func start() {
        guard Self.supported else { message = "LiDAR scene depth is unavailable on this device."; return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.frameSemantics = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) ? .smoothedSceneDepth : .sceneDepth
        session.run(configuration)
    }
    func stop() { session.pause() }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastTimestamp > 0.3 else { return }
        lastTimestamp = frame.timestamp
        guard case .normal = frame.camera.trackingState,
              let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            DispatchQueue.main.async { self.distance = nil; self.message = "Move slowly while spatial tracking recovers." }
            return
        }
        let buffer = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let x = CVPixelBufferGetWidth(buffer) / 2, y = CVPixelBufferGetHeight(buffer) / 2
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return }
        let row = address.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float32.self)
        let value = row[x]
        var reliable = false
        if let confidence = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(confidence) {
                let cx = CVPixelBufferGetWidth(confidence) / 2, cy = CVPixelBufferGetHeight(confidence) / 2
                let confidenceRow = base.advanced(by: cy * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
                reliable = confidenceRow[cx] >= 1
            }
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
        }
        guard value.isFinite, value > 0.15, value < 8, reliable else {
            filteredDistance = nil
            DispatchQueue.main.async { self.distance = nil; self.message = "Depth is uncertain here. Aim at a nearer, non-reflective surface." }
            return
        }
        let smoothed = filteredDistance.map { $0 * 0.65 + value * 0.35 } ?? value
        filteredDistance = smoothed
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.count
        DispatchQueue.main.async {
            self.distance = smoothed
            self.message = planes > 0 ? "Surface tracking ready. Adjust your distance to change the perspective." : "Distance ready. Move slowly to find surfaces."
        }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        CameraDiagnostics.shared.record("AR session: \(error.localizedDescription)")
        DispatchQueue.main.async { self.distance = nil; self.message = error.localizedDescription }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.distance = nil; self.message = "Depth assistance interrupted. Return to Camera and reopen it." }
    }
}

private struct DepthPreview: UIViewRepresentable {
    let model: DepthSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = model.session
        view.scene = SCNScene()
        model.start()
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) { view.session.pause() }
}
