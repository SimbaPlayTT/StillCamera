import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("useAppleIntelligenceCoach") private var intelligence = false
    @AppStorage("captureFormat") private var format = CaptureFormat.heif.rawValue
    @AppStorage("captureAspect") private var aspect = CaptureAspect.standard.rawValue
    @AppStorage("captureTimer") private var timer = 0
    @AppStorage("preferProRAW") private var proRAW = true
    @AppStorage("showCompositionGrid") private var grid = true
    @AppStorage("showHorizonLevel") private var level = true
    @AppStorage("cameraHapticsEnabled") private var haptics = true
    @AppStorage("reviewAfterCapture") private var review = false
    @AppStorage("guideStyle") private var guideStyle = GuideStyle.instagram.rawValue
    @AppStorage("guidePrompt") private var prompt = ""
    @AppStorage("guideInterpretedStyle") private var interpretedStyle = ""
    @AppStorage("guideInterpretedPrompt") private var interpretedPrompt = ""
    @AppStorage("guideAutoZoom") private var autoZoom = true
    @AppStorage("guideAutoCapture") private var autoCapture = true
    @AppStorage("guideDepthLock") private var depthLock = true
    @AppStorage("guideDwell") private var dwell = 0.8
    @State private var modelState = CompositionCoach.foundationModelState
    @State private var intentTask: Task<Void, Never>?
    @State private var interpreting = false
    @State private var intentStatus: String?
    let supportsRaw: Bool
    let supportsProRAW: Bool

    var body: some View {
        NavigationStack {
            Form {
                guideSection
                intentSection
                intelligenceSection
                Section {
                    Toggle("Grid", isOn: $grid)
                    Toggle("Horizon level", isOn: $level)
                    Toggle("Haptic feedback", isOn: $haptics)
                } header: { Text("Viewfinder") }
                Section {
                    Picker("Photo format", selection: $format) {
                        Text("HEIF / JPEG").tag(CaptureFormat.heif.rawValue)
                        if supportsRaw { Text("RAW + photo").tag(CaptureFormat.raw.rawValue) }
                    }
                    if supportsRaw { Toggle("Prefer Apple ProRAW", isOn: $proRAW).disabled(!supportsProRAW) }
                    Picker("Framing", selection: $aspect) {
                        ForEach(CaptureAspect.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Picker("Timer", selection: $timer) {
                        Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10)
                    }
                    Toggle("Review after each photo", isOn: $review)
                } header: { Text("Capture") } footer: {
                    Text("Turn review off to keep shooting. Photos and RAW originals are kept in Still; open the thumbnail to edit or save to Photos.")
                }
                Section {
                    Text("Framing analysis stays on your iPhone. Your preference sets a composition style; the guide does not search the internet or promise a perfect photo.")
                        .font(.footnote)
                    NavigationLink("Camera diagnostics") { DiagnosticsView() }
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2")
                } header: { Text("About & support") }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.white).preferredColorScheme(.dark)
        .onAppear { modelState = CompositionCoach.foundationModelState }
        .onDisappear { intentTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { modelState = CompositionCoach.foundationModelState }
        }
        .onChange(of: prompt) { _, value in
            if value.count > 240 { prompt = String(value.prefix(240)) }
            intentTask?.cancel(); interpreting = false; intentStatus = nil
        }
    }

    private var guideSection: some View {
        Section {
            Toggle("Auto zoom to the frame", isOn: $autoZoom)
            Toggle("Shoot when aligned", isOn: $autoCapture)
            if autoCapture {
                Picker("Hold steady for", selection: $dwell) {
                    Text("0.8 seconds").tag(0.8)
                    Text("1.2 seconds").tag(1.2)
                    Text("1.8 seconds").tag(1.8)
                }
            }
            Toggle("LiDAR scene anchoring", isOn: $depthLock)
                .disabled(!GuideSession.worldTrackingAvailable)
            LabeledContent("Scene anchoring", value: GuideSession.worldTrackingAvailable ? "Available" : "Visual fallback")
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink("How guided shooting works") { GuideHelpView() }
        } header: { Text("Guided shooting") } footer: {
            Text("Match the white + to the yellow target. Hold steady for one automatic photo per scan.")
        }
    }

    private var intentSection: some View {
        Section {
            Picker("Style", selection: $guideStyle) {
                ForEach(GuideStyle.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            TextField("For example: a minimal Instagram post with room for text", text: $prompt, axis: .vertical)
                .lineLimit(2...4).font(.body)
            let intent = GuideIntent(style: GuideStyle(rawValue: guideStyle) ?? .instagram, prompt: prompt)
            LabeledContent("Framing", value: intent.aspect.rawValue)
            if let intentStatus { Text(intentStatus).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("What do you want to shoot?") } footer: {
            Text("The preference changes crop, subject spacing and placement. “Instagram post” uses 4:5; “story” uses 9:16. Add “centered”, “square” or “negative space” to adjust the composition.")
        }
    }

    private var intelligenceSection: some View {
        Section {
            Toggle("Apple Intelligence", isOn: $intelligence).disabled(modelState != .available)
            Text(modelStatus).font(.footnote).foregroundStyle(.secondary)
            if intelligence && modelState == .available {
                Button {
                    intentTask?.cancel()
                    let preference = prompt
                    interpreting = true
                    intentTask = Task { @MainActor in
                        defer { if !Task.isCancelled { interpreting = false } }
                        do {
                            let result = try await CompositionCoach.interpretIntent(preference)
                            try Task.checkCancellation()
                            interpretedStyle = result.rawValue; interpretedPrompt = preference
                            intentStatus = "Preference ready: \(result.rawValue)."
                        } catch {
                            if !Task.isCancelled { intentStatus = "Using the selected style and local composition rules." }
                        }
                    }
                } label: {
                    HStack { Text("Interpret my preference"); Spacer(); if interpreting { ProgressView() } }
                }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || interpreting)
            }
        } header: { Text("On-device intelligence") } footer: {
            Text("The optional model interprets your written preference once. Live framing uses Vision and geometry, so taking a photo never waits for a language model.")
        }
    }

    private var modelStatus: String {
        switch modelState {
        case .available: return "On-device model ready."
        case .requiresNewerOS: return "Requires iOS 26 or later. Local framing remains available."
        case .appleIntelligenceOff: return "Enable Apple Intelligence in iPhone Settings to use this option."
        case .modelPreparing: return "The model is downloading or preparing. Local framing is available."
        case .unsupportedLanguage: return "This iPhone language is not supported by the model."
        case .unavailable: return "The model is unavailable. Local framing is available."
        }
    }
}

private struct GuideHelpView: View {
    var body: some View {
        List {
            Section("Choose a frame") {
                Text("Tap Guide to find a composition. Use the rescan menu to choose a new frame or draw around a detail yourself.")
            }
            Section("Align and shoot") {
                Text("Move the phone until the white + meets the yellow target. The guide sets the framing and waits for a steady hold. Turn Auto off to press the shutter yourself.")
            }
            Section("Scene anchoring") {
                Text("LiDAR keeps stationary scene details fixed in space. When depth is unavailable, visual tracking follows the selected detail. If tracking is lost, rescan before shooting.")
            }
            Section("Capture options") {
                Text("LiDAR mode uses the wide camera and a high-resolution JPEG crop up to 2×. RAW uses visual tracking. Flash, the flashlight, the regular timer and manual exposure are available in Photo mode.")
            }
        }.navigationTitle("Guided shooting").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticsView: View {
    @State private var report = ""
    var body: some View {
        ScrollView { Text(report).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle("Diagnostics")
            .toolbar { ShareLink(item: report) { Label("Share", systemImage: "square.and.arrow.up") } }
            .onAppear { report = CameraDiagnostics.shared.report() }
    }
}
