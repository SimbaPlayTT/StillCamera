import SwiftUI

/// Primary camera controls live on a solid surface outside the viewfinder.
struct CameraControlsOverlay: View {
    let ready: Bool
    let capturing: Bool
    let latestThumbnail: URL?
    let guideEnabled: Bool
    let aligned: Bool
    let onCapture: () -> Void
    let onSwitch: () -> Void
    let onLibrary: () -> Void
    let onGuide: () -> Void
    let onAdjust: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: onAdjust) { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .accessibilityLabel("Exposure and capture controls")
                Spacer()
                HStack(spacing: 23) {
                    Text("PHOTO").foregroundStyle(.yellow)
                    Button("GUIDE", action: onGuide).disabled(!ready || capturing)
                        .accessibilityLabel("Find and lock a guided composition")
                }.font(.system(size: 11, weight: .semibold)).tracking(1.5)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            HStack {
                Button(action: onLibrary) {
                    ThumbnailView(url: latestThumbnail).frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.4), lineWidth: 1))
                }.accessibilityLabel("Open photo library")
                Spacer()
                Button(action: onCapture) {
                    ZStack {
                        Circle().stroke(aligned ? .yellow : .white, lineWidth: 3).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 64, height: 64)
                        if capturing { ProgressView().tint(.black) }
                    }
                }
                .buttonStyle(.plain).disabled(!ready || capturing).opacity(ready ? 1 : 0.45)
                .accessibilityLabel(capturing ? "Capturing" : "Take photo")
                Spacer()
                Button(action: onSwitch) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 46, height: 46)
                }.disabled(!ready || capturing).accessibilityLabel("Switch front and rear camera")
            }
        }
        .buttonStyle(.plain).foregroundStyle(.white).padding(.horizontal, 28).padding(.bottom, 8)
        .background(.black)
    }
}
