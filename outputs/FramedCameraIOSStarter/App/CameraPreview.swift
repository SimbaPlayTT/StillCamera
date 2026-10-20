import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    let onFocus: (CGPoint, CGPoint, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap); view.addGestureRecognizer(hold)
        context.coordinator.hostView = view
        return view
    }
    func updateUIView(_ view: CameraPreviewHostView, context: Context) {
        context.coordinator.parent = self
        view.mirrored = mirrored
        view.updateConnection()
    }
    final class Coordinator: NSObject {
        var parent: CameraPreview
        weak var hostView: CameraPreviewHostView?
        init(_ parent: CameraPreview) { self.parent = parent }
        @objc func tap(_ gesture: UITapGestureRecognizer) { focus(gesture, locked: false) }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { focus(gesture, locked: true) }
        }
        private func focus(_ gesture: UIGestureRecognizer, locked: Bool) {
            guard let view = hostView else { return }
            let point = gesture.location(in: view)
            parent.onFocus(point, view.previewLayer.captureDevicePointConverted(fromLayerPoint: point), locked)
        }
    }
}
final class CameraPreviewHostView: UIView {
    var mirrored = false
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() { super.layoutSubviews(); updateConnection() }
    func updateConnection() {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}
