import AVFoundation
import SwiftUI

struct CameraView: View {
    private enum Sheet: Identifiable {
        case settings, library, editor(LibraryPhoto)
        var id: String { switch self { case .settings: return "settings"; case .library: return "library"; case .editor(let photo): return photo.id.uuidString } }
    }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraService()
    @StateObject private var library = PhotoLibraryStore()
    @AppStorage("showCompositionGrid") private var grid = true
    @AppStorage("showHorizonLevel") private var showLevel = true
    @AppStorage("useAppleIntelligenceCoach") private var intelligence = false
    @AppStorage("captureFormat") private var format = CaptureFormat.heif.rawValue
    @AppStorage("captureAspect") private var aspectValue = CaptureAspect.standard.rawValue
    @AppStorage("captureTimer") private var timerSeconds = 0
    @AppStorage("preferProRAW") private var proRAW = true
    @AppStorage("cameraHapticsEnabled") private var haptics = true
    @State private var sheet: Sheet?
    @State private var depthPresented = false
    @State private var guide = false
    @State private var drawFrame = false
    @State private var adjustments = false
    @State private var flash: AVCaptureDevice.FlashMode = .off
    @State private var focusPoint: CGPoint?
    @State private var focusID = UUID()
    @State private var pinchStart: CGFloat?
    @State private var countdown: Int?
    @State private var timerTask: Task<Void, Never>?
    @State private var coachTask: Task<Void, Never>?
    @State private var coachText: String?
    @State private var manualISO: Float = 0
    @State private var manualShutter: Double = 0
    @State private var storingCapture = false
    @State private var userFrame = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)
    private var aspect: CaptureAspect { CaptureAspect(rawValue: aspectValue) ?? .standard }
    private var ready: Bool { camera.phase == .running && !storingCapture && countdown == nil && camera.capturedPhoto == nil }
    private var framedObservation: CompositionObservation {
        let unit = CGSize(width: aspect.ratio, height: 1)
        let bounds = camera.compositionObservation.subjectBounds.map {
            CameraMath.viewRect($0, imageSize: camera.imageSize, viewSize: unit)
        }
        let center = bounds.map { CGPoint(x: $0.midX / unit.width, y: $0.midY) }
        return CompositionObservation(subjectBounds: bounds, subjectCenter: center, horizonAngle: camera.horizonAngle,
            suggestedAdjustment: bounds == nil ? camera.compositionObservation.suggestedAdjustment :
                abs(camera.horizonAngle) > 0.06 ? "Level the camera." : CompositionCoach.heuristic(for: center),
            detectedFace: camera.compositionObservation.detectedFace, detectedPose: camera.compositionObservation.detectedPose)
    }
    private var aligned: Bool {
        guard guide, let point = framedObservation.subjectCenter else { return false }
        let third = min(abs(point.x - 1 / 3), abs(point.x - 2 / 3))
        return third < 0.055 && point.y > 0.2 && point.y < 0.8 && abs(camera.horizonAngle) < 0.035
    }

    var body: some View {
        GeometryReader { geometry in
            let reserve: CGFloat = adjustments ? 320 : 205
            let height = min(geometry.size.width / aspect.ratio, max(160, geometry.size.height - reserve))
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                viewfinder(size: CGSize(width: min(geometry.size.width, height * aspect.ratio), height: height))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                if adjustments { adjustmentPanel }
                CameraControlsOverlay(ready: ready, capturing: camera.isCapturing || storingCapture,
                    latestThumbnail: library.photos.first?.thumbnailURL, guideEnabled: guide, aligned: aligned,
                    onCapture: shutter, onSwitch: switchCamera, onLibrary: { present(.library) },
                    onGuide: toggleGuide, onAdjust: { withAnimation(.easeInOut(duration: 0.2)) { adjustments.toggle() } })
            }
            .background(.black)
        }
        .background(.black).foregroundStyle(.white).preferredColorScheme(.dark).tint(.yellow)
        .onAppear { camera.start() }
        .onDisappear { cancelWork(); camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && sheet == nil && !depthPresented { camera.start(); camera.setAnalysisEnabled(guide) }
            else if phase != .active { cancelWork(); camera.stop() }
        }
        .onChange(of: camera.supportsRaw) { _, raw in if !raw { format = CaptureFormat.heif.rawValue } }
        .onChange(of: camera.currentZoomFactor) { _, _ in coachTask?.cancel(); coachText = nil }
        .onChange(of: flash) { _, value in
            if value != .off && camera.torchOn { camera.setTorch(false) }
        }
        .onChange(of: camera.capturedPhoto?.id) { _, id in
            if id != nil { keepCapture() }
        }
        .sheet(item: $sheet, onDismiss: resume) { value in
            switch value {
            case .settings: SettingsView(supportsRaw: camera.supportsRaw, supportsProRAW: camera.supportsProRAW)
            case .library: LibraryView(store: library)
            case .editor(let entry): PhotoEditorView(entry: entry, store: library)
            }
        }
        .fullScreenCover(isPresented: $depthPresented, onDismiss: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { resume() }
        }) { DepthAssistView() }
        .alert("Camera", isPresented: Binding(get: { camera.message != nil || library.error != nil }, set: {
            if !$0 { camera.dismissMessage(); library.error = nil }
        })) {
            Button("OK") { camera.dismissMessage(); library.error = nil }
            if camera.capturedPhoto != nil && !storingCapture { Button("Retry keeping photo") { keepCapture() } }
            if camera.capturedPhoto != nil && !storingCapture {
                Button("Discard unsaved capture", role: .destructive) { camera.clearCapturedPhoto(); library.error = nil; camera.dismissMessage() }
            }
            if camera.phase == .failed { Button("Retry") { camera.start() } }
        } message: { Text(camera.message ?? library.error ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Flash off") { flash = .off }
                Button("Flash automatic") { flash = .auto }
                Button("Flash on for capture") { flash = .on }
            } label: {
                Image(systemName: flash == .off ? "bolt.slash" : "bolt.fill")
                    .foregroundStyle(flash == .off ? .white : .yellow).frame(width: 48, height: 48)
            }.disabled(!camera.hasFlash || !ready).accessibilityLabel("Photo flash")
            Button {
                let enabled = !camera.torchOn
                if enabled { flash = .off }
                camera.setTorch(enabled)
            } label: {
                Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .foregroundStyle(camera.torchOn ? .yellow : .white).frame(width: 48, height: 48)
            }.disabled(!camera.hasTorch || !ready).accessibilityLabel(camera.torchOn ? "Turn continuous light off" : "Turn continuous light on")
            Spacer(minLength: 0)
            Menu {
                ForEach(CaptureAspect.allCases) { value in Button(value.rawValue) { aspectValue = value.rawValue } }
            } label: { Text(aspect.rawValue).font(.caption.monospaced()).frame(width: 48, height: 48) }
            Menu {
                Button("HEIF / JPEG") { format = CaptureFormat.heif.rawValue }
                if camera.supportsRaw { Button(camera.supportsProRAW ? "ProRAW + photo" : "RAW + photo") { format = CaptureFormat.raw.rawValue } }
            } label: {
                Text(format == CaptureFormat.raw.rawValue ? "RAW" : "HEIF").font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(format == CaptureFormat.raw.rawValue ? .yellow : .white).frame(width: 52, height: 48)
            }.disabled(!ready)
            Button { present(.settings) } label: { Image(systemName: "gearshape").frame(width: 48, height: 48) }
                .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain).padding(.horizontal, 8)
    }

    private func viewfinder(size: CGSize) -> some View {
        ZStack {
            CameraPreview(session: camera.session, mirrored: camera.isFrontCamera) { local, device, locked in
                guard ready, !drawFrame else { return }
                camera.focus(at: device, lock: locked)
                focusPoint = local
                let token = UUID(); focusID = token
                haptic()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if focusID == token { focusPoint = nil } }
            }
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                guard ready, !drawFrame else { return }
                if pinchStart == nil { pinchStart = camera.currentZoomFactor }
                camera.setZoomFactor((pinchStart ?? camera.currentZoomFactor) * value.magnification)
            }.onEnded { _ in pinchStart = nil })
            if grid { ThirdsGrid().allowsHitTesting(false) }
            if guide, let bounds = camera.compositionObservation.subjectBounds, !drawFrame {
                let box = CameraMath.viewRect(bounds, imageSize: camera.imageSize, viewSize: size)
                RoundedRectangle(cornerRadius: 2).stroke(.yellow.opacity(0.8), lineWidth: 1)
                    .frame(width: max(2, box.width), height: max(2, box.height)).position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
            }
            if drawFrame {
                FrameSelection(rect: $userFrame) {
                    let rect = CGRect(x: userFrame.minX * size.width, y: userFrame.minY * size.height,
                        width: userFrame.width * size.width, height: userFrame.height * size.height)
                    camera.trackSubject(in: CameraMath.imageRect(rect, imageSize: camera.imageSize, viewSize: size))
                }
            }
            if let focusPoint {
                Rectangle().stroke(.yellow, lineWidth: 1.2).frame(width: 62, height: 62)
                    .position(focusPoint).allowsHitTesting(false)
            }
            VStack {
                HStack {
                    if camera.exposureLocked { Text("AE/AF LOCK").font(.caption2.monospaced()).foregroundStyle(.yellow) }
                    Spacer()
                    if guide {
                        Button { drawFrame.toggle(); coachText = nil } label: {
                            Label(drawFrame ? "Track" : "Select", systemImage: drawFrame ? "checkmark" : "crop")
                                .font(.caption).padding(10).background(.black.opacity(0.65), in: Capsule())
                        }.accessibilityLabel(drawFrame ? "Track selected frame" : "Select and resize your own frame")
                    }
                }
                if guide {
                    HStack(spacing: 8) {
                        Text(drawFrame ? "Drag to select. Move the box or resize its corner." : coachText ?? framedObservation.suggestedAdjustment)
                            .font(.caption).lineLimit(2)
                        Spacer(minLength: 0)
                        Button { requestCoach() } label: { Image(systemName: "arrow.clockwise").frame(width: 36, height: 36) }
                            .accessibilityLabel("Refresh framing suggestion")
                    }.padding(.leading, 10).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                if showLevel && abs(camera.horizonAngle) < 0.18 {
                    Rectangle().fill(abs(camera.horizonAngle) < 0.035 ? .yellow : .white)
                        .frame(width: 55, height: 1.5).rotationEffect(.radians(Double(-camera.horizonAngle)))
                        .overlay(Circle().fill(.white).frame(width: 3, height: 3)).allowsHitTesting(false)
                }
                Spacer()
                lensRow
            }.padding(12)
            if let countdown {
                VStack { Text("\(countdown)").font(.system(size: 70, weight: .light)); Button("Cancel timer") { cancelWork() } }
                    .padding().background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if camera.authorization != .authorized || camera.phase == .failed || camera.phase == .interrupted {
                VStack(spacing: 12) {
                    Image(systemName: "camera").font(.largeTitle)
                    Text(statusText).multilineTextAlignment(.center)
                    if camera.authorization == .denied {
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    } else { Button("Retry") { camera.start() } }
                }.padding(24).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(width: size.width, height: size.height).clipped()
    }

    private var lensRow: some View {
        HStack(spacing: 8) {
            ForEach(camera.lenses) { lens in
                Button { camera.setZoomFactor(lens.factor); haptic() } label: {
                    Text(lens.title).font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(abs(lens.factor - camera.currentZoomFactor) < 0.08 ? .yellow : .white)
                        .frame(minWidth: 44, minHeight: 44)
                }.disabled(!ready)
            }
            if !camera.lenses.contains(where: { abs($0.factor - camera.currentZoomFactor) < 0.08 }) {
                Text(String(format: "%.1f×", Double(camera.currentZoomFactor))).font(.caption.monospaced()).foregroundStyle(.yellow)
            }
        }.padding(.horizontal, 8).background(.black.opacity(0.55), in: Capsule())
        .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
            let ordered = camera.lenses.sorted { $0.factor < $1.factor }
            let candidate = value.translation.width < 0 ? ordered.first(where: { $0.factor > camera.currentZoomFactor + 0.08 }) : ordered.last(where: { $0.factor < camera.currentZoomFactor - 0.08 })
            if let candidate { camera.setZoomFactor(candidate.factor) }
        })
    }

    private var adjustmentPanel: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "sun.max")
                Slider(value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposureBias(Float($0)) }),
                    in: Double(camera.exposureRange.lowerBound)...Double(camera.exposureRange.upperBound))
                    .accessibilityLabel("Exposure compensation")
                Text(String(format: "%+.1f", camera.exposureBias)).font(.caption.monospaced()).frame(width: 40)
            }
            HStack {
                Menu {
                    Button("Automatic exposure") { manualISO = 0; manualShutter = 0; camera.setManualExposure(iso: nil, shutterSeconds: nil) }
                    ForEach([50, 100, 200, 400, 800, 1600, 3200], id: \.self) { iso in
                        Button("ISO \(iso)") { manualISO = Float(iso); camera.setManualExposure(iso: manualISO, shutterSeconds: manualShutter == 0 ? nil : manualShutter) }
                    }
                } label: { Text(camera.exposureIsManual ? "ISO \(Int(camera.actualISO))" : "ISO AUTO").font(.caption.monospaced()).frame(minHeight: 44) }.disabled(!camera.manualExposureSupported)
                Spacer()
                Menu {
                    Button("Automatic shutter") { manualShutter = 0; manualISO = 0; camera.setManualExposure(iso: nil, shutterSeconds: nil) }
                    ForEach([15, 30, 60, 125, 250, 500, 1000], id: \.self) { denominator in
                        Button("1/\(denominator)s") { manualShutter = 1 / Double(denominator); camera.setManualExposure(iso: manualISO == 0 ? nil : manualISO, shutterSeconds: manualShutter) }
                    }
                } label: { Text(camera.exposureIsManual ? "1/\(Int((1 / max(camera.actualExposure, 0.000001)).rounded()))s" : "SHUTTER AUTO").font(.caption.monospaced()).frame(minHeight: 44) }.disabled(!camera.manualExposureSupported)
                Spacer()
                Menu {
                    ForEach([0, 3, 10], id: \.self) { seconds in Button(seconds == 0 ? "Timer off" : "\(seconds) seconds") { timerSeconds = seconds } }
                    Toggle("Grid", isOn: $grid)
                    if DepthSession.supported { Button("Depth assist") { openDepth() } }
                } label: { Image(systemName: timerSeconds == 0 ? "timer" : "timer.circle.fill").frame(width: 44, height: 44) }
            }
        }.padding(.horizontal, 20).disabled(!ready).background(.black)
    }

    private var statusText: String {
        switch camera.authorization {
        case .checking: return "Starting camera…"
        case .denied: return "Allow camera access to take photographs."
        case .restricted: return "Camera access is restricted on this iPhone."
        case .unavailable: return "No camera is available."
        case .failed(let text): return text
        case .authorized: return camera.phase == .interrupted ? "Camera interrupted" : "Camera paused"
        }
    }
    private func shutter() {
        guard ready else { return }
        if timerSeconds == 0 { capture(); return }
        let seconds = timerSeconds
        timerTask = Task { @MainActor in
            do {
                for value in stride(from: seconds, through: 1, by: -1) {
                    countdown = value; haptic(); try await Task.sleep(for: .seconds(1))
                }
                countdown = nil; try Task.checkCancellation(); capture()
            } catch { countdown = nil }
            timerTask = nil
        }
    }
    private func capture() {
        haptic()
        camera.capturePhoto(format: CaptureFormat(rawValue: format) ?? .heif, preferProRAW: proRAW, flashMode: flash, aspect: aspect)
    }
    private func keepCapture() {
        guard let photo = camera.capturedPhoto, !storingCapture else { return }
        storingCapture = true
        Task {
            do {
                let entry = try await library.add(photo)
                camera.clearCapturedPhoto()
                present(.editor(entry))
            } catch { library.error = error.localizedDescription }
            storingCapture = false
        }
    }
    private func switchCamera() {
        guard ready else { return }
        coachTask?.cancel(); coachText = nil; drawFrame = false; manualISO = 0; manualShutter = 0
        camera.switchCamera()
    }
    private func toggleGuide() {
        guide.toggle(); coachText = nil; drawFrame = false; coachTask?.cancel()
        camera.setAnalysisEnabled(guide)
        if guide { requestCoach() }
    }
    private func requestCoach() {
        coachTask?.cancel(); coachText = nil
        guard intelligence, CompositionCoach.foundationModelState == .available,
              camera.compositionObservation.subjectCenter != nil else { return }
        let observation = framedObservation
        coachTask = Task { @MainActor in
            do {
                let result = try await CompositionCoach.onDeviceSuggestion(for: observation)
                try Task.checkCancellation(); coachText = result
            } catch { if !Task.isCancelled { coachText = observation.suggestedAdjustment } }
        }
    }
    private func present(_ target: Sheet) {
        cancelWork(); camera.setAnalysisEnabled(false)
        camera.stop { sheet = target }
    }
    private func openDepth() {
        guard ready, DepthSession.supported else { return }
        cancelWork(); camera.setAnalysisEnabled(false)
        camera.stop { depthPresented = true }
    }
    private func resume() {
        if scenePhase == .active && !depthPresented { camera.start(); camera.setAnalysisEnabled(guide) }
    }
    private func cancelWork() { timerTask?.cancel(); timerTask = nil; countdown = nil; coachTask?.cancel(); coachText = nil }
    private func haptic() { if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
}

private struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: proxy.size.width * fraction, y: 0)); path.addLine(to: CGPoint(x: proxy.size.width * fraction, y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: proxy.size.height * fraction)); path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height * fraction))
                }
            }.stroke(.white.opacity(0.3), lineWidth: 0.5)
        }
    }
}

private struct FrameSelection: View {
    @Binding var rect: CGRect
    let onCommit: () -> Void
    @State private var startRect: CGRect?
    var body: some View {
        GeometryReader { proxy in
            Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 8).onChanged { value in
                let start = value.startLocation, end = value.location
                rect = constrained(CGRect(x: min(start.x, end.x) / proxy.size.width, y: min(start.y, end.y) / proxy.size.height,
                    width: abs(end.x - start.x) / proxy.size.width, height: abs(end.y - start.y) / proxy.size.height))
            }.onEnded { _ in onCommit() })
            Rectangle().stroke(.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .background(.yellow.opacity(0.05)).contentShape(Rectangle())
                .frame(width: rect.width * proxy.size.width, height: rect.height * proxy.size.height)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.caption).padding(10).background(.black.opacity(0.7))
                        .gesture(DragGesture().onChanged { value in
                            if startRect == nil { startRect = rect }
                            if let startRect {
                                rect = constrained(CGRect(origin: startRect.origin, size: CGSize(
                                    width: startRect.width + value.translation.width / proxy.size.width,
                                    height: startRect.height + value.translation.height / proxy.size.height)))
                            }
                        }.onEnded { _ in startRect = nil; onCommit() })
                }
                .position(x: rect.midX * proxy.size.width, y: rect.midY * proxy.size.height)
                .gesture(DragGesture().onChanged { value in
                    if startRect == nil { startRect = rect }
                    if let startRect {
                        rect = constrained(startRect.offsetBy(dx: value.translation.width / proxy.size.width,
                            dy: value.translation.height / proxy.size.height))
                    }
                }.onEnded { _ in startRect = nil; onCommit() })
        }
    }
    private func constrained(_ value: CGRect) -> CGRect {
        let width = min(max(value.width, 0.08), 0.95), height = min(max(value.height, 0.08), 0.95)
        return CGRect(x: min(max(value.minX, 0), 1 - width), y: min(max(value.minY, 0), 1 - height), width: width, height: height)
    }
}
