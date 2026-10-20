import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.hostView = view
        return view
    }

    func updateUIView(_ view: CameraPreviewHostView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        weak var hostView: CameraPreviewHostView?

        init(_ parent: CameraPreview) { self.parent = parent }

        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = hostView else { return }
            let point = recognizer.location(in: view)
            let cameraPoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            parent.onFocus(point, cameraPoint)
        }
    }
}

final class CameraPreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
