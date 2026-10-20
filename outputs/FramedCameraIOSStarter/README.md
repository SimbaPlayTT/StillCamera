# Still — native camera and photo library

Still is a SwiftUI / AVFoundation iPhone app. Version 1.2 adds composition selection, a frozen scene target, crosshair alignment, bounded automatic zoom and one automatic photo per scan. It retains manual capture, RAW, a persistent photo library and adjustable film-style editing.

**Requested physical target: iPhone 17 Pro Max on iOS 27.0.** Minimum iOS remains 18. Apple Intelligence uses runtime availability checks (iOS 26+ and an eligible, ready model); Vision guidance works without it.

Read [REPAIR-NOTES.md](REPAIR-NOTES.md) for established defects, the source-grounded Framed comparison, implementation limits and the device checklist. Hardware behavior on iOS 27.0 is not certified by simulator tests.

## Camera

- Compact top row: capture flash, continuous torch, crop, format and Settings.
- Runtime lens presets; pinch or swipe to zoom. Virtual hardware factors are converted to wide-camera 1x. The displayed presets reflect actual constituents rather than a fixed 0.5/1/2/5 list.
- Tap to focus/expose, hold for AE/AF lock. Open the sliders button for exposure compensation, manual ISO/shutter, timer and Grid.
- Flash On fires during capture. The flashlight button controls continuous LED illumination. Torch shuts down before camera switching, backgrounding or AR handoff.
- RAW/ProRAW appears only when the active output supports it. HEIF falls back to JPEG if HEVC is unavailable.
- 3:4, 4:5, square and 9:16 export crops preserve the original.
- Tap GUIDE for the dedicated guided viewfinder. See [GUIDED-SHOOTING.md](GUIDED-SHOOTING.md) for the shooting flow, anchoring, intent settings and capture safeguards.
- In Settings, choose a composition style or enter a short photographic preference. Optional Apple Intelligence interprets that preference once; it never blocks the shutter or receives camera frames.

## Develop and keep

Captures are saved in Still's private library. By default the camera stays open; enable Review after each photo in Settings to open the editor automatically. Import uses the system Photos picker. The library retains original bytes, a paired DNG where captured, metadata, thumbnails and separate edit recipes.

The editor provides original looks, tonal adjustments, white balance, six-channel HSL, split grading, tone curves, RGB calibration, texture/optical effects, crop, borders and a capture-date stamp. Halation is a bloom approximation. Paper is a border tone rather than a paper-texture simulation.

Use the editor's menu to export an edit, share it, save original+RAW, share original files, reset edits or delete from Still. Local edits can be reopened after restarting the app. Library photos are removed if the app is deleted.

## Depth assistance

On a device supporting ARKit scene depth, open the camera adjustment panel and its timer menu, then choose Depth Assist. It reports a confidence-checked, smoothed approximate distance at the center and plane-tracking status. It is a separate camera mode; close it to return to full-resolution photography. Front TrueDepth and 3D viewpoint reconstruction are not implemented.

## GitHub Actions from Windows

Push changes to the existing repository or run **Build unsigned Still iOS IPA** in Actions. The workflow:

1. Selects the newest installed stable Xcode on macos-latest and generates the project using XcodeGen.
2. Archives for physical iOS with signing disabled and records a build result bundle.
3. Runs camera-state, zoom, crop, edit-persistence, image-export, composition-planning and automatic-capture-gate tests on an available iPhone simulator.
4. Launches the simulator app and captures a screenshot. A simulator cannot verify physical camera features.
5. Packages Payload/Still.app into StillCamera-unsigned.ipa and uploads it with BuildInfo.txt. Logs, result bundles and screenshot are uploaded separately, including when a build fails.

Download the StillCamera-unsigned-ipa artifact. Its IPA needs signing through a compatible sideloading tool or your Apple development workflow before device installation. BuildInfo.txt identifies the actual SDK used; the requested device OS does not imply that the runner has SDK 27 installed.

For Mac development: run xcodegen generate in this folder, open StillCamera.xcodeproj, choose a signing team and run the StillCamera scheme. The minimum deployment target is iOS 18.

## Diagnostics

Settings > About & support > Camera diagnostics contains runtime iOS version, app version, camera configuration and recent state/error events. No photo content is included. Share it with a matching device .ips crash report when reporting failures. See the device checklist before claiming that crashes, heat or frame pacing are resolved.
