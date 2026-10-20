# Still — native iOS camera

This project is a native SwiftUI camera app. It uses AVFoundation for the live viewfinder and photo capture, Vision for on-device framing analysis, and PhotoKit to save captures. The camera interface uses restrained black controls, tactile feedback, a level indicator, subject framing marks, and a rule-of-thirds grid.

## Compatibility

- Minimum deployment target: iOS 18.
- The UI, AVFoundation camera, Vision composition guides, RAW/HEIF capture fallback, and Photos saving are designed for iOS 18 and later.
- Apple Foundation Models are optional and require iOS 26 or later plus Apple Intelligence availability. On iOS 18 or when the model is unavailable, the Vision-based composition cue remains available.
- Device capabilities are checked at runtime. On a supported triple-camera device, Still uses the virtual triple-camera input so iOS can switch physical lenses at zoom stops. Other devices fall back to the rear wide-angle camera.

## Project contents

- `App/CameraService.swift` — serial AVFoundation session configuration, camera permissions, triple/wide camera selection, lens zoom, tap focus/exposure, flash, HEIF/JPEG and RAW/ProRAW capture, runtime errors, motion leveling, Vision frame delivery, and Photos saving.
- `App/CameraView.swift` — the live viewfinder, grid, horizon indicator, focus reticle, framing guidance, capture review, and recent capture screen.
- `App/CameraControlsOverlay.swift` — black ergonomic controls, exposure compensation, flash/format/settings, guide and grid switches, swipeable zoom presets, haptics, and shutter.
- `App/CameraPreview.swift` — `AVCaptureVideoPreviewLayer` bridge with tap-to-focus coordinate conversion.
- `App/CompositionCoach.swift` — on-device saliency, face, pose, and rectangle analysis. When enabled and available, Foundation Models turns coarse measurements into a short cue; it receives no image.
- `App/SettingsView.swift` — the requested Apple Intelligence toggle, capture format, ProRAW preference, grid, haptics, and privacy details.
- `App/Info.plist` — camera and photo-library usage descriptions plus iPhone requirements.
- `project.yml` — XcodeGen project specification, target, bundle identifier, assets, and iOS deployment target.
- Workspace `.github/workflows/build-ipa.yml` — GitHub Actions workflow that generates an Xcode project on a macOS runner, archives the iOS app without signing, packages an unsigned `.ipa`, and uploads it as an artifact.

## Build on GitHub Actions from Windows

The workflow lives at the workspace repository path `.github/workflows/build-ipa.yml` and builds `outputs/FramedCameraIOSStarter`. Commit and push both the project folder and the workflow to a GitHub repository, then run **Build unsigned Still iOS IPA** from the Actions tab or push a change to the project. Download the `StillCamera-unsigned-ipa` artifact from the completed workflow.

The workflow uses `macos-latest`, installs XcodeGen, runs `xcodegen generate`, archives with `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`, then packages `Payload/Still.app` into `StillCamera-unsigned.ipa`.

## Install on a physical iPhone

The workflow intentionally creates an **unsigned** IPA. It is not ready to install directly on an iPhone. Import it into a sideloading tool such as AltStore or SideStore to sign it with a provisioning profile, or configure a signing workflow with your Apple Developer credentials. A free Apple development signing profile generally expires and needs refreshing. TrollStore only works on specific iOS versions and devices; the artifact itself does not make a phone eligible.

For a local Mac build, open `project.yml` in the project directory, run `xcodegen generate`, then open the generated `StillCamera.xcodeproj` in Xcode. Choose a development team in **Signing & Capabilities**, connect the iPhone, and Run. Approve camera access on the device. Photos add-only access is requested only when a capture is saved.

## Capture behavior

- The back camera prefers `.builtInTripleCamera` and falls back to `.builtInWideAngleCamera`; the front camera uses its wide-angle camera.
- Zoom buttons and horizontal swipes select 0.5×, 1×, 2×, and 5× where those factors are supported by the active camera. Unsupported stops are disabled.
- Tap the preview to focus and expose. The exposure slider controls AVFoundation exposure bias.
- The capture format control offers HEIF by default and RAW + processed HEIF when the device supports RAW. The processed image is available for review; RAW data is stored alongside it in Photos when present.
- Apple ProRAW is enabled on the capture output before the session starts when the connected device and configuration support it. The RAW preference chooses ProRAW when available and Bayer RAW otherwise.
- Vision analysis is downsampled and throttled. The live horizon level uses Core Motion. Guide can fall back to a deterministic thirds-based instruction.

## Limits of this prototype

This source tree and workflow have not been built on a Mac in this workspace. The first capture slice does not yet include the full Framed film editor, custom frame drawing, video capture, a persistent in-app photo library, or manual shutter-speed/ISO dials. Those features should be added only after a device build and camera/RAW behavior have been verified on the iPhone 17 Pro Max.
