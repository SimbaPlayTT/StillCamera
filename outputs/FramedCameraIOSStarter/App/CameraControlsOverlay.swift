import AVFoundation
import Foundation
import SwiftUI
import UIKit

struct CameraControlsOverlay: View {
    @Binding var selectedZoom: CGFloat
    @Binding var guideEnabled: Bool
    @Binding var gridEnabled: Bool
    @Binding var flashMode: AVCaptureDevice.FlashMode
    @Binding var captureFormat: String

    let minimumZoom: CGFloat
    let maximumZoom: CGFloat
    let supportsRaw: Bool
    let supportsProRAW: Bool
    let preferProRAW: Bool
    let hasFlash: Bool
    let isCameraReady: Bool
    let isCapturing: Bool
    let hasRecentPhoto: Bool
    let recentPhotoData: Data?
    let onZoom: (CGFloat) -> Void
    let onExposure: (Float) -> Void
    let onCapture: () -> Void
    let onSwitchCamera: () -> Void
    let onOpenLibrary: () -> Void
    let onOpenSettings: () -> Void
    let onGuide: () -> Void

    @AppStorage("cameraHapticsEnabled") private var hapticsEnabled = true
    @State private var exposureBias: Float = 0
    @State private var lastSwipeChange = Date.distantPast

    private var selectedFormat: CaptureFormat {
        CaptureFormat(rawValue: captureFormat) ?? .heif
    }

    var body: some View {
        VStack(spacing: 15) {
            topBar
            exposureControl
            guideAndGridRow
            zoomSelector
            shutterRow
            Text("PHOTO")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(.white.opacity(0.56))
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.70), .black.opacity(0.94)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            controlButton(title: flashTitle, symbol: "bolt.fill", selected: flashMode != .off) {
                flashMode = nextFlashMode
                selectionHaptic()
            }
            .disabled(!hasFlash)
            .opacity(hasFlash ? 1 : 0.45)
            .accessibilityLabel("Flash, \(flashTitle)")

            Spacer(minLength: 6)

            Button {
                guard supportsRaw else { return }
                captureFormat = selectedFormat == .raw ? CaptureFormat.heif.rawValue : CaptureFormat.raw.rawValue
                selectionHaptic()
            } label: {
                Text(selectedFormat == .raw ? (supportsProRAW && preferProRAW ? "PRORAW" : "RAW") : "HEIF")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(selectedFormat == .raw ? Color(red: 0.91, green: 0.81, blue: 0.63) : .white)
                    .frame(minWidth: 55, minHeight: 36)
                    .background(Color.black.opacity(0.74), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!supportsRaw)
            .opacity(supportsRaw ? 1 : 0.50)
            .accessibilityLabel(supportsRaw ? "Capture format, \(selectedFormat.title)" : "RAW capture unavailable")

            Spacer(minLength: 6)

            controlButton(title: "", symbol: "slider.horizontal.3", selected: false, action: onOpenSettings)
                .accessibilityLabel("Camera settings")
        }
        .foregroundStyle(.white)
    }

    private var exposureControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))

            Slider(value: Binding(
                get: { Double(exposureBias) },
                set: { value in
                    exposureBias = Float(value)
                    onExposure(exposureBias)
                }
            ), in: -2...2, step: 0.1)
            .tint(Color(red: 0.91, green: 0.81, blue: 0.63))
            .accessibilityLabel("Exposure compensation")

            Text(String(format: "%+.1f", exposureBias))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 5)
        .frame(height: 26)
    }

    private var guideAndGridRow: some View {
        HStack(spacing: 9) {
            togglePill(guideEnabled ? "Guide on" : "Guide", symbol: "viewfinder", selected: guideEnabled) {
                guideEnabled.toggle()
                selectionHaptic()
                if guideEnabled { onGuide() }
            }
            togglePill("Grid", symbol: "grid", selected: gridEnabled) {
                gridEnabled.toggle()
                selectionHaptic()
            }
            Spacer()
            if supportsRaw && selectedFormat == .raw {
                Text(supportsProRAW && preferProRAW ? "APPLE PRORAW" : "DNG + HEIF")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.45)
                    .foregroundStyle(.white.opacity(0.57))
                    .lineLimit(1)
            }
        }
    }

    private var zoomSelector: some View {
        HStack(spacing: 11) {
            ForEach(LensPreset.standard) { preset in
                let allowed = preset.factor >= minimumZoom - 0.01 && preset.factor <= maximumZoom + 0.01
                Button {
                    guard allowed else { return }
                    selectedZoom = preset.factor
                    onZoom(preset.factor)
                    selectionHaptic()
                } label: {
                    Text(preset.title)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected(preset.factor) ? .black : .white.opacity(allowed ? 0.90 : 0.34))
                        .frame(width: 40, height: 34)
                        .background(isSelected(preset.factor) ? Color(red: 0.92, green: 0.83, blue: 0.65) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!allowed)
                .accessibilityLabel("\(preset.title) lens")
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let now = Date()
                    guard now.timeIntervalSince(lastSwipeChange) > 0.25 else { return }
                    lastSwipeChange = now
                    selectNextAvailableLens(direction: value.translation.width < 0 ? 1 : -1)
                }
        )
        .accessibilityHint("Swipe left or right to change lens zoom")
    }

    private var shutterRow: some View {
        HStack(alignment: .center) {
            Button(action: onOpenLibrary) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 47, height: 47)
                    if let recentPhotoData, let image = UIImage(data: recentPhotoData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 47, height: 47)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                    } else if hasRecentPhoto {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white.opacity(0.88))
                    } else {
                        Image(systemName: "square.stack")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(.white.opacity(0.72), lineWidth: 1)
                        .frame(width: 47, height: 47)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open recent photo")

            Spacer()

            Button {
                impactHaptic()
                onCapture()
            } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.95), lineWidth: 2.5).frame(width: 72, height: 72)
                    Circle().fill(.white).frame(width: 59, height: 59)
                    if isCapturing {
                        ProgressView().tint(.black)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isCapturing || !isCameraReady)
            .opacity(isCameraReady ? 1 : 0.45)
            .accessibilityLabel(isCapturing ? "Capturing photo" : "Take photo")

            Spacer()

            Button(action: onSwitchCamera) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 47, height: 47)
            }
            .buttonStyle(.plain)
            .disabled(!isCameraReady)
            .opacity(isCameraReady ? 1 : 0.45)
            .accessibilityLabel("Switch camera")
        }
        .padding(.horizontal, 3)
    }

    private func controlButton(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                if !title.isEmpty {
                    Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(selected ? Color(red: 0.94, green: 0.82, blue: 0.59) : .white)
            .frame(minWidth: 38, minHeight: 36)
            .padding(.horizontal, title.isEmpty ? 0 : 9)
            .background(Color.black.opacity(0.74), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func togglePill(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 0.98 : 0.76))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(selected ? Color.white.opacity(0.18) : Color.black.opacity(0.62), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(selected ? 0.34 : 0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var flashTitle: String {
        switch flashMode {
        case .auto: return "AUTO"
        case .on: return "ON"
        case .off: return "OFF"
        @unknown default: return "OFF"
        }
    }

    private var nextFlashMode: AVCaptureDevice.FlashMode {
        switch flashMode {
        case .auto: return .on
        case .on: return .off
        case .off: return .auto
        @unknown default: return .auto
        }
    }

    private func isSelected(_ factor: CGFloat) -> Bool { abs(selectedZoom - factor) < 0.05 }

    private func selectNextAvailableLens(direction: Int) {
        let options = LensPreset.standard.filter { $0.factor >= minimumZoom - 0.01 && $0.factor <= maximumZoom + 0.01 }
        guard !options.isEmpty else { return }
        let current = options.firstIndex(where: { isSelected($0.factor) }) ?? 0
        let next = min(max(current + direction, 0), options.count - 1)
        guard next != current else { return }
        selectedZoom = options[next].factor
        onZoom(options[next].factor)
        selectionHaptic()
    }

    private func impactHaptic() {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func selectionHaptic() {
        guard hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
