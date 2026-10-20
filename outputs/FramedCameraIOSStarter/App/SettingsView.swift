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
    @State private var modelState = CompositionCoach.foundationModelState
    let supportsRaw: Bool
    let supportsProRAW: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Apple Intelligence", isOn: $intelligence).disabled(modelState != .available)
                    Text(modelStatus).font(.footnote).foregroundStyle(.secondary)
                    Toggle("Grid", isOn: $grid)
                    Toggle("Horizon level", isOn: $level)
                } header: { Text("Composition") } footer: {
                    Text("The viewfinder Guide uses on-device Vision. Optional Apple Intelligence adds wording when you refresh a suggestion.")
                }
                Section {
                    Picker("Photo format", selection: $format) {
                        Text("HEIF / JPEG").tag(CaptureFormat.heif.rawValue)
                        if supportsRaw { Text("RAW + photo").tag(CaptureFormat.raw.rawValue) }
                    }
                    if supportsRaw { Toggle("Prefer Apple ProRAW", isOn: $proRAW).disabled(!supportsProRAW) }
                    Picker("Framing", selection: $aspect) { ForEach(CaptureAspect.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Picker("Timer", selection: $timer) {
                        Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10)
                    }
                    Toggle("Haptic feedback", isOn: $haptics)
                } header: { Text("Capture") } footer: {
                    Text("RAW availability changes with the active camera. Originals and edit settings stay in Still until you delete them.")
                }
                Section {
                    LabeledContent("LiDAR depth", value: DepthSession.supported ? "Available" : "Unavailable")
                    Text("Open exposure controls below the viewfinder, then the timer menu to use Depth Assist. It measures the surface at the center and uses a separate camera mode.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Depth assistance") }
                Section {
                    Text("Camera analysis stays on your iPhone. Photos access is requested when you export. Import uses the system photo picker.")
                        .font(.footnote)
                    NavigationLink("Camera diagnostics") { DiagnosticsView() }
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1")
                } header: { Text("About & support") }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.white).preferredColorScheme(.dark)
        .onAppear { modelState = CompositionCoach.foundationModelState }
        .onChange(of: scenePhase) { _, phase in if phase == .active { modelState = CompositionCoach.foundationModelState } }
    }

    private var modelStatus: String {
        switch modelState {
        case .available: return "On-device model ready."
        case .requiresNewerOS: return "Apple Intelligence guidance requires iOS 26 or later. Vision guidance remains available."
        case .appleIntelligenceOff: return "Enable Apple Intelligence in iPhone Settings to use this option."
        case .modelPreparing: return "The model is downloading or preparing. Vision guidance is available."
        case .unsupportedLanguage: return "This iPhone language is not supported by the model."
        case .unavailable: return "The model is unavailable. Vision guidance is available."
        }
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
