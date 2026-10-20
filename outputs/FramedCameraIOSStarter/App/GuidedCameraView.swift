import ARKit
import SceneKit
import SwiftUI

struct GuidedCameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: GuideSession
    @AppStorage("guideAutoCapture") private var autoCapture = true
    @AppStorage("cameraHapticsEnabled") private var haptics = true
    @State private var selectionMode = false
    @State private var dragStart: CGPoint?
    @State private var selection: CGRect?
    @State private var closing = false
    private let onClose: () -> Void
    private let onPhoto: (CapturedPhoto) -> Void

    init(onClose: @escaping () -> Void, onPhoto: @escaping (CapturedPhoto) -> Void) {
        let defaults = UserDefaults.standard
        let style = GuideStyle(rawValue: defaults.string(forKey: "guideStyle") ?? "") ?? .instagram
        let prompt = defaults.string(forKey: "guidePrompt") ?? ""
        let interpreted = defaults.string(forKey: "guideInterpretedPrompt") == prompt ?
            GuideStyle(rawValue: defaults.string(forKey: "guideInterpretedStyle") ?? "") : nil
        var intent = GuideIntent(style: style, prompt: prompt)
        if let interpreted, defaults.bool(forKey: "useAppleIntelligenceCoach") {
            intent.style = interpreted
            if !prompt.lowercased().contains("square") { intent.aspect = interpreted.aspect }
        }
        _model = StateObject(wrappedValue: GuideSession(intent: intent,
            preferDepth: defaults.object(forKey: "guideDepthLock") as? Bool ?? true,
            autoZoom: defaults.object(forKey: "guideAutoZoom") as? Bool ?? true,
            autoCapture: defaults.object(forKey: "guideAutoCapture") as? Bool ?? true,
            dwell: defaults.double(forKey: "guideDwell") > 0 ? defaults.double(forKey: "guideDwell") : 0.8,
            format: CaptureFormat(rawValue: defaults.string(forKey: "captureFormat") ?? "") ?? .heif,
            preferProRAW: defaults.object(forKey: "preferProRAW") as? Bool ?? true))
        self.onClose = onClose; self.onPhoto = onPhoto
    }

    var body: some View {
        GeometryReader { proxy in
            let height = min(proxy.size.width / model.aspect.ratio, max(180, proxy.size.height - 248))
            let size = CGSize(width: min(proxy.size.width, height * model.aspect.ratio), height: height)
            VStack(spacing: 0) {
                toolbar
                Spacer(minLength: 0)
                viewfinder(size)
                    .frame(maxWidth: .infinity)
                    .onAppear { model.start(viewport: size) }
                    .onChange(of: size) { _, value in model.start(viewport: value) }
                Spacer(minLength: 0)
                instructions
                controls
            }
        }
        .background(.black).foregroundStyle(.white).preferredColorScheme(.dark).tint(.yellow)
        .interactiveDismissDisabled()
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && !closing { close() }
        }
        .onChange(of: autoCapture) { _, value in model.setAutoCapture(value) }
        .onChange(of: model.photo?.id) { _, id in
            guard id != nil, let photo = model.photo, !closing else { return }
            closing = true; feedback(.medium)
            model.stop { onPhoto(photo) }
        }
        .onChange(of: model.snapshot.phase) { old, new in
            if old == .scanning && new == .locked { feedback(.light) }
        }
    }

    private var toolbar: some View {
        HStack {
            Button(action: close) { Image(systemName: "xmark").frame(width: 48, height: 48) }
                .accessibilityLabel("Close guide").disabled(model.snapshot.phase == .capturing || closing)
            Spacer()
            Menu {
                ForEach(GuideStyle.allCases) { style in
                    Button(style.rawValue) { selectionMode = false; model.rescan(style: style) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("GUIDE").tracking(1.5).font(.caption.weight(.semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }.frame(height: 48)
            }.disabled(!model.snapshot.canScan)
            Spacer()
            Text(model.aspect.rawValue).font(.caption.monospaced()).frame(width: 48, height: 48)
        }.padding(.horizontal, 8).buttonStyle(.plain)
    }

    private func viewfinder(_ size: CGSize) -> some View {
        ZStack {
            Group {
                if model.usesWorldCamera {
                    WorldCameraPreview(session: model.arSession)
                        .scaleEffect(model.snapshot.zoom)
                        .animation(.easeOut(duration: 0.12), value: model.snapshot.zoom)
                } else {
                    CameraPreview(session: model.camera.session, mirrored: false) { _, _, _ in }
                }
            }
            .frame(width: size.width, height: size.height).clipped().allowsHitTesting(false)

            GuideTargetOverlay(snapshot: model.snapshot)
                .allowsHitTesting(false)
            if selectionMode {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                        dragStart = value.startLocation
                        selection = normalizedRect(from: value.startLocation, to: value.location, size: size)
                    }.onEnded { _ in
                        if let selection { model.select(region: selection) }
                        selection = nil; dragStart = nil; selectionMode = false
                    })
                    .overlay {
                        if let selection {
                            Rectangle().stroke(.yellow, lineWidth: 1)
                                .frame(width: selection.width * size.width, height: selection.height * size.height)
                                .position(x: selection.midX * size.width, y: selection.midY * size.height)
                                .allowsHitTesting(false)
                        }
                    }
            }
            VStack {
                HStack(spacing: 6) {
                    Circle().fill(model.snapshot.trusted ? Color.yellow : Color.white.opacity(0.7)).frame(width: 4, height: 4)
                    Text(selectionMode ? "DRAG AROUND A DETAIL" : model.snapshot.tracking.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.8)
                    Spacer()
                    Text(String(format: "%.1f×%@", Double(model.snapshot.zoom), model.usesWorldCamera ? " CROP" : ""))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .padding(10).background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
                Spacer()
                if model.snapshot.phase == .scanning || model.snapshot.phase == .starting {
                    ProgressView().tint(.yellow).padding(12).background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
            }.allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height).clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Guided viewfinder. \(model.snapshot.instruction). \(model.snapshot.tracking).")
    }

    private var instructions: some View {
        VStack(spacing: 6) {
            Text(selectionMode ? "Draw the frame you want" : model.snapshot.instruction)
                .font(.system(size: 16, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            Text(selectionMode ? "Release to lock your selection" : model.snapshot.detail)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            Capsule().fill(.white.opacity(0.13)).frame(width: 80, height: 2)
                .overlay(alignment: .leading) {
                    Capsule().fill(.yellow).frame(width: 80 * model.snapshot.progress, height: 2)
                }
                .opacity(autoCapture ? 1 : 0)
        }.frame(height: 79).padding(.horizontal, 22)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                Menu {
                    Button("Find a new frame", systemImage: "arrow.clockwise") { selectionMode = false; model.rescan() }
                    Button("Select a detail", systemImage: "crop") {
                        model.rescan(); selectionMode = true
                    }
                } label: {
                    Image(systemName: selectionMode ? "crop" : "arrow.clockwise").font(.title3).frame(width: 52, height: 52)
                }.disabled(!model.snapshot.canScan).accessibilityLabel("Rescan or select a detail")
                Spacer()
                Button {
                    if model.snapshot.canCapture { model.captureNow() }
                    else { model.rescan() }
                    feedback(.light)
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 64, height: 64)
                        if model.snapshot.phase == .capturing { ProgressView().tint(.black) }
                        else if !model.snapshot.canCapture { Image(systemName: "plus").font(.system(size: 25, weight: .light)).foregroundStyle(.black) }
                    }
                }
                .disabled(!model.snapshot.canCapture && !model.snapshot.canScan)
                .accessibilityLabel(model.snapshot.canCapture ? "Take guided photo now" : "Scan for a frame")
                Spacer()
                Button { autoCapture.toggle(); feedback(.light) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: autoCapture ? "checkmark.circle.fill" : "circle").font(.title3)
                        Text("AUTO").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.7)
                    }.foregroundStyle(autoCapture ? .yellow : .white).frame(width: 52, height: 52)
                }.disabled(model.snapshot.phase == .capturing).accessibilityLabel("Automatic capture")
                    .accessibilityValue(autoCapture ? "On" : "Off")
            }
            Text("Align the + with the yellow target").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28).padding(.bottom, 12).buttonStyle(.plain)
    }

    private func close() {
        guard !closing, model.snapshot.phase != .capturing else { return }
        closing = true; model.stop(completion: onClose)
    }
    private func feedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        if haptics { UIImpactFeedbackGenerator(style: style).impactOccurred() }
    }
    private func normalizedRect(from start: CGPoint, to end: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: max(0, min(start.x, end.x) / size.width), y: max(0, min(start.y, end.y) / size.height),
               width: min(1, abs(end.x - start.x) / size.width), height: min(1, abs(end.y - start.y) / size.height))
            .intersection(GuidePlanner.unit)
    }
}

private struct WorldCameraPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session; view.scene = SCNScene()
        view.preferredFramesPerSecond = 60; view.antialiasingMode = .none
        view.automaticallyUpdatesLighting = false; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct GuideTargetOverlay: View {
    let snapshot: GuideSnapshot
    var body: some View {
        GeometryReader { proxy in
            let points = snapshot.corners.map { CGPoint(x: $0.x * proxy.size.width, y: $0.y * proxy.size.height) }
            if points.count == 4 {
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                }.stroke(.yellow.opacity(snapshot.trusted ? 0.95 : 0.4), lineWidth: 1.25)
                let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / 4, y: points.reduce(0) { $0 + $1.y } / 4)
                Crosshair().stroke(.yellow, lineWidth: 1.5).frame(width: 16, height: 16).position(center)
            }
            Crosshair().stroke(.black.opacity(0.5), lineWidth: 3).frame(width: 22, height: 22)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            Crosshair().stroke(.white.opacity(0.9), lineWidth: 1).frame(width: 22, height: 22)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            if snapshot.progress > 0 {
                Circle().trim(from: 0, to: snapshot.progress).stroke(.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 38, height: 38)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
    }
}

private struct Crosshair: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
