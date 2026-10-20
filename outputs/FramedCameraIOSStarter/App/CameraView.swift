import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    private enum PresentedSheet: String, Identifiable {
        case settings
        case review
        case library
        var id: String { rawValue }
    }

    @StateObject private var camera = CameraService()
    @AppStorage("showCompositionGrid") private var showGrid = true
    @AppStorage("useAppleIntelligenceCoach") private var useAppleIntelligence = false
    @AppStorage("captureFormat") private var captureFormat = CaptureFormat.heif.rawValue
    @AppStorage("preferProRAW") private var preferProRAW = true
    @AppStorage("cameraHapticsEnabled") private var hapticsEnabled = true

    @State private var selectedZoom: CGFloat = 1
    @State private var guideEnabled = false
    @State private var flashMode: AVCaptureDevice.FlashMode = .auto
    @State private var presentedSheet: PresentedSheet?
    @State private var focusPoint: CGPoint?
    @State private var guideMessage: String?
    @State private var guideIsWorking = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreview(session: camera.session) { localPoint, devicePoint in
                    camera.focus(at: devicePoint)
                    withAnimation(.easeOut(duration: 0.15)) { focusPoint = localPoint }
                    if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        withAnimation(.easeOut(duration: 0.2)) { focusPoint = nil }
                    }
                }
                .ignoresSafeArea()

                LinearGradient(colors: [.black.opacity(0.18), .clear, .clear, .black.opacity(0.42)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if showGrid {
                    RuleOfThirdsGrid()
                        .padding(.horizontal, 20)
                        .padding(.vertical, geometry.size.height * 0.08)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if guideEnabled {
                    CompositionReticle(observation: camera.compositionObservation)
                        .padding(.horizontal, 20)
                        .padding(.vertical, geometry.size.height * 0.08)
                        .allowsHitTesting(false)
                }

                if let focusPoint {
                    FocusReticle()
                        .position(focusPoint)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.88)))
                }

                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        levelIndicator
                        if guideEnabled {
                            guideNote
                        }
                    }
                    .padding(.top, geometry.safeAreaInsets.top + 12)
                    .padding(.horizontal, 22)

                    Spacer(minLength: 8)

                    CameraControlsOverlay(
                        selectedZoom: $selectedZoom,
                        guideEnabled: $guideEnabled,
                        gridEnabled: $showGrid,
                        flashMode: $flashMode,
                        captureFormat: $captureFormat,
                        minimumZoom: camera.minimumZoomFactor,
                        maximumZoom: camera.maximumZoomFactor,
                        supportsRaw: camera.supportsRaw,
                        supportsProRAW: camera.supportsProRAW,
                        preferProRAW: preferProRAW,
                        hasFlash: camera.hasFlash,
                        isCameraReady: camera.isRunning,
                        isCapturing: camera.isCapturing,
                        hasRecentPhoto: camera.capturedPhoto != nil,
                        recentPhotoData: camera.capturedPhoto?.processedData,
                        onZoom: camera.setZoomFactor,
                        onExposure: camera.setExposureBias,
                        onCapture: capture,
                        onSwitchCamera: camera.switchCamera,
                        onOpenLibrary: { presentedSheet = .library },
                        onOpenSettings: { presentedSheet = .settings },
                        onGuide: requestCompositionSuggestion
                    )
                }
                .ignoresSafeArea(edges: .bottom)

                if camera.authorization != .authorized {
                    cameraStatusCard
                        .padding(.horizontal, 30)
                        .padding(.bottom, 110)
                }

                if let message = camera.message {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.82), in: Capsule())
                            .padding(.bottom, 173)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .animation(.easeInOut(duration: 0.2), value: guideEnabled)
            .animation(.easeInOut(duration: 0.18), value: showGrid)
            .onAppear { camera.start() }
            .onDisappear { camera.stop() }
            .onChange(of: camera.capturedPhoto?.id) { _, id in
                if id != nil { presentedSheet = .review }
            }
            .onChange(of: camera.isRunning) { _, isRunning in
                if isRunning && !camera.supportsRaw { captureFormat = CaptureFormat.heif.rawValue }
            }
            .onChange(of: camera.supportsRaw) { _, supportsRaw in
                if !supportsRaw { captureFormat = CaptureFormat.heif.rawValue }
            }
            .onChange(of: camera.currentZoomFactor) { _, factor in
                selectedZoom = factor
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .settings:
                    SettingsView(supportsRaw: camera.supportsRaw, supportsProRAW: camera.supportsProRAW)
                case .review:
                    if let photo = camera.capturedPhoto {
                        PhotoReviewView(photo: photo, camera: camera) {
                            camera.clearCapturedPhoto()
                            presentedSheet = nil
                        }
                    }
                case .library:
                    RecentPhotoView(photo: camera.capturedPhoto)
                        .presentationDetents([.medium, .large])
                }
            }
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.84, green: 0.71, blue: 0.48))
    }

    private var guideNote: some View {
        HStack(spacing: 10) {
            if guideIsWorking {
                ProgressView().tint(.white).controlSize(.small)
            } else {
                Image(systemName: "viewfinder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.91, green: 0.81, blue: 0.63))
            }
            Text(guideIsWorking ? "Checking the frame…" : (guideMessage ?? camera.compositionObservation.suggestedAdjustment))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 2)
            Button {
                requestCompositionSuggestion()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh composition suggestion")
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.76), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var levelIndicator: some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(abs(camera.horizonAngle) < 0.035 ? Color.white.opacity(0.82) : Color.orange.opacity(0.95))
                .frame(width: 38, height: 1.5)
                .rotationEffect(.radians(Double(-camera.horizonAngle)))
                .overlay(Circle().fill(.white).frame(width: 4, height: 4))
            Text(abs(camera.horizonAngle) < 0.035 ? "LEVEL" : "LEVEL THE HORIZON")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.62), in: Capsule())
        .accessibilityLabel(abs(camera.horizonAngle) < 0.035 ? "Horizon level" : "Horizon tilted")
    }

    private var cameraStatusCard: some View {
        VStack(spacing: 10) {
            Image(systemName: camera.authorization == .denied ? "camera.fill" : "camera")
                .font(.system(size: 25, weight: .regular))
            Text(cameraStatusTitle)
                .font(.system(size: 16, weight: .semibold))
            Text(cameraStatusDetail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            if camera.authorization == .denied {
                Button("Open Settings") {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsURL)
                    }
                }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 4)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var cameraStatusTitle: String {
        switch camera.authorization {
        case .checking: return "Starting camera…"
        case .authorized: return ""
        case .denied: return "Camera access is off"
        case .restricted: return "Camera access is restricted"
        case .unavailable: return "Camera unavailable"
        case .failed: return "Couldn’t start the camera"
        }
    }

    private var cameraStatusDetail: String {
        switch camera.authorization {
        case .checking: return "The live viewfinder will appear here."
        case .authorized: return ""
        case .denied: return "Allow camera access for Still in iPhone Settings."
        case .restricted: return "Camera access is restricted on this device."
        case .unavailable: return "No compatible camera input is available."
        case .failed(let detail): return detail
        }
    }

    private func capture() {
        let format = CaptureFormat(rawValue: captureFormat) ?? .heif
        camera.capturePhoto(format: format, preferProRAW: preferProRAW, flashMode: flashMode)
    }

    private func requestCompositionSuggestion() {
        guideMessage = nil
        let observation = camera.compositionObservation
        guard useAppleIntelligence,
              CompositionCoach.foundationModelState == .available else {
            guideMessage = observation.suggestedAdjustment
            return
        }
        guideIsWorking = true
        Task {
            do {
                let suggestion = try await CompositionCoach.onDeviceSuggestion(for: observation)
                await MainActor.run {
                    guideMessage = suggestion
                    guideIsWorking = false
                }
            } catch {
                await MainActor.run {
                    guideMessage = observation.suggestedAdjustment
                    guideIsWorking = false
                }
            }
        }
    }
}

private struct RuleOfThirdsGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let width = proxy.size.width
                let height = proxy.size.height
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                    path.move(to: CGPoint(x: 0, y: height * fraction))
                    path.addLine(to: CGPoint(x: width, y: height * fraction))
                }
            }
            .stroke(.white.opacity(0.27), style: StrokeStyle(lineWidth: 0.7, dash: [5, 4]))
        }
    }
}

private struct CompositionReticle: View {
    let observation: CompositionObservation

    var body: some View {
        GeometryReader { proxy in
            if let bounds = observation.subjectBounds {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.90), lineWidth: 1.2)
                    .frame(width: max(24, bounds.width * proxy.size.width),
                           height: max(24, bounds.height * proxy.size.height))
                    .position(x: bounds.midX * proxy.size.width, y: bounds.midY * proxy.size.height)
                    .shadow(color: .black.opacity(0.35), radius: 2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: observation.subjectCenter)
    }
}

private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color(red: 0.94, green: 0.81, blue: 0.56), lineWidth: 1.4)
            .frame(width: 66, height: 66)
            .overlay(alignment: .bottom) {
                Capsule().fill(Color(red: 0.94, green: 0.81, blue: 0.56)).frame(width: 27, height: 2).offset(y: 6)
            }
    }
}

private struct PhotoReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var saveMessage: String?
    @State private var isSaving = false

    let photo: CapturedPhoto
    let camera: CameraService
    let onRetake: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = UIImage(data: photo.processedData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    ContentUnavailableView("Photo preview unavailable", systemImage: "photo")
                }

                if let saveMessage {
                    Text(saveMessage).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button("Retake", action: onRetake)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button {
                        save()
                    } label: {
                        if isSaving { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Save to Photos").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
            }
            .padding()
            .navigationTitle(photo.rawData == nil ? "Review" : "RAW + HEIF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await camera.saveToPhotos(photo)
                await MainActor.run { saveMessage = "Saved to Photos."; isSaving = false }
            } catch {
                await MainActor.run { saveMessage = error.localizedDescription; isSaving = false }
            }
        }
    }
}

private struct RecentPhotoView: View {
    let photo: CapturedPhoto?

    var body: some View {
        NavigationStack {
            Group {
                if let photo, let image = UIImage(data: photo.processedData) {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding()
                    }
                } else {
                    ContentUnavailableView("No recent photos", systemImage: "photo.on.rectangle.angled")
                }
            }
            .navigationTitle("Recent")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
