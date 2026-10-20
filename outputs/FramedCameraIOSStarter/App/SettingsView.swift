import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("useAppleIntelligenceCoach") private var useAppleIntelligence = false
    @AppStorage("captureFormat") private var captureFormat = CaptureFormat.heif.rawValue
    @AppStorage("preferProRAW") private var preferProRAW = true
    @AppStorage("showCompositionGrid") private var showGrid = true
    @AppStorage("cameraHapticsEnabled") private var hapticsEnabled = true
    @State private var modelState = CompositionCoach.foundationModelState

    let supportsRaw: Bool
    let supportsProRAW: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("On-Device AI Composition Coach (Apple Intelligence)", isOn: $useAppleIntelligence)
                        .disabled(modelState != .available)
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(modelStatusTitle)
                                .font(.subheadline.weight(.medium))
                            Text(modelStatusDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: modelState == .available ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(modelState == .available ? .green : .secondary)
                    }
                    .padding(.vertical, 3)
                } header: {
                    Text("Composition")
                } footer: {
                    Text("Vision finds framing cues on-device. When enabled, Apple Intelligence receives only coarse framing measurements after you tap Guide. No photo is sent to a server, and the coach never runs continuously.")
                }

                Section("Capture") {
                    if supportsRaw {
                        Picker("Photo format", selection: $captureFormat) {
                            Text("HEIF").tag(CaptureFormat.heif.rawValue)
                            Text("RAW + HEIF").tag(CaptureFormat.raw.rawValue)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: captureFormat) { _, value in
                            if value == CaptureFormat.raw.rawValue { preferProRAW = true }
                        }
                    } else {
                        LabeledContent("Photo format", value: "HEIF")
                    }

                    if supportsRaw && captureFormat == CaptureFormat.raw.rawValue {
                        Toggle("Prefer Apple ProRAW when available", isOn: $preferProRAW)
                            .disabled(!supportsProRAW)
                    }
                    Toggle("Rule-of-thirds grid", isOn: $showGrid)
                    Toggle("Haptic feedback", isOn: $hapticsEnabled)
                } footer: {
                    Text("RAW support depends on the camera hardware and active capture format. When ProRAW is unavailable, Still uses a supported RAW format with a processed HEIF preview.")
                }

                Section("Privacy") {
                    Label("Camera analysis stays on this iPhone", systemImage: "lock.shield")
                    Text("Still does not use a third-party image service. Photos access is requested only when you save a capture.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Still", value: "Camera prototype")
                    LabeledContent("Minimum iOS", value: "iOS 18")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Color(red: 0.78, green: 0.64, blue: 0.40))
        .onAppear { modelState = CompositionCoach.foundationModelState }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { modelState = CompositionCoach.foundationModelState }
        }
    }

    private var modelStatusTitle: String {
        switch modelState {
        case .available: return "Available on this iPhone"
        case .requiresNewerOS: return "Requires a newer iOS version"
        case .appleIntelligenceOff: return "Apple Intelligence is turned off"
        case .modelPreparing: return "Apple’s on-device model is preparing"
        case .unsupportedLanguage: return "Current language isn’t supported"
        case .unavailable: return "Apple Intelligence is unavailable"
        }
    }

    private var modelStatusDetail: String {
        switch modelState {
        case .available:
            return "On-device composition suggestions are ready when requested."
        case .requiresNewerOS:
            return "This option requires iOS 26 or later. Standard Vision framing guidance works on iOS 18 and later."
        case .appleIntelligenceOff:
            return "Turn on Apple Intelligence in iPhone Settings. Standard Vision guidance remains available."
        case .modelPreparing:
            return "Try again later. Standard Vision guidance remains available."
        case .unsupportedLanguage:
            return "Choose a supported iPhone language to enable the optional on-device model."
        case .unavailable:
            return "Standard Vision framing guidance remains available on this iPhone."
        }
    }
}
