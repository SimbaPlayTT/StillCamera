# Still 1.1 — repair and device verification

Primary device requested: **iPhone 17 Pro Max, iOS 27.0**. Minimum OS remains iOS 18. The CI runner selects the newest installed stable Xcode and records its actual SDK in BuildInfo.txt. An older SDK can build an app that runs on newer iOS, but that is not physical-device verification.

## Defects established from source

- Exposure compensation called setExposureTargetBias without lockForConfiguration. Apple's API contract says this raises an exception. All changes now go through one session queue and a device lock.
- Captures enabled the deprecated high-resolution photo setting while the photo output had never enabled high-resolution capture. Replaced both with supported maxPhotoDimensions, configured before the session starts.
- Triple-camera hardware zoom was treated as displayed magnification, disabling 0.5x and mislabeling other presets. Wide-camera 1x is now derived from constituent switch factors; no 5x lens is invented.
- There was no torch operation. Flash Auto/On affects capture, not continuous preview illumination. A separate torch control now checks support, observes actual activation, and shuts down during camera handoff/backgrounding.
- Guide analysis ran even with Guide off, converted every sampled buffer into a CGImage, and mapped detections onto a differently padded viewport. It now reads rotated pixel buffers directly, runs only on demand, throttles under low power/thermal pressure, tracks a selected object, and maps through the same aspect-fill transform.
- Instructions for subjects near the frame edge moved the camera in the opposite direction. The deterministic guide now uses corrected camera-motion directions and accounts for selected output framing.
- The app had no UILaunchScreen definition, plus heavy viewfinder gradients and oversized control stacks. Added launch metadata, removed scene-darkening gradients, and moved controls onto compact solid surfaces.
- Review retained only a temporary capture and there was no persistent editor/library. Originals, RAW files and separate edit recipes now persist in Application Support.

These are code-supported defects. Screenshots and a successful archive cannot establish the causes of every reported device crash. Physical reports may reveal additional issues.

Sources:
- [Exposure locking](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuretargetbias(_:completionhandler:))
- [High-resolution configuration](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/ishighresolutioncaptureenabled)
- [Maximum photo dimensions](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions)
- [Launch screen](https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen)

## Feature matrix

References rechecked October 20, 2026: [Framed website](https://shootframed.com/) and [Framed App Store listing](https://apps.apple.com/us/app/framed-take-aesthetic-photos/id6761207600). Documented means publicly described, not independently tested in Framed.

| Area | Public reference | Still implementation / limitation |
|---|---|---|
| Automatic framing | Scene scan and guidance | Local face/pose/saliency selection, tracking, corrected pan/tilt cues, horizon and thirds alignment indicator. Heuristic guidance; aesthetic ranking, automatic exposure/zoom recommendations and optimal viewpoint selection remain incomplete. |
| User framing | Draw, move and resize a target | Select a region, move the rectangle, resize its corner, then track using Vision. This follows the selected region; it does not promise a reconstructed 3D shot. |
| Capture | RAW, manual shutter/ISO, flash, exposure compensation | Capability-gated HEIF/JPEG, paired RAW/ProRAW, locked manual/automatic exposure, separate flash and torch, tap focus, hold AE/AF lock, timer and runtime zoom presets. Physical combinations need device tests. |
| Aspect ratios | 3:4, 4:5, square, 9:16 | Matching viewport crops and export framing; full original retained. |
| Looks and light | Adjustable looks and tonal controls | Four original looks, exposure, contrast, highlights, shadows, whites, blacks, fade, temperature, tint and saturation. |
| Color | HSL, grading, curves, calibration | Six-channel HSL color cube; shadow/highlight hues and strengths; five-point tone curve; RGB gain calibration. Sensor-specific profiles and per-channel curves are not implemented. |
| Effects | Film and optical effects | Grain, bloom-based halation approximation, glow, leaks, procedural scratches/dust, motion blur and vignette. Not a calibrated physical film/halation model. |
| Finish | Border variants, date and capture details | Plain/white/paper-toned/black/negative/specs frames; capture-date stamp and metadata captions. Paper texture simulation is not implemented. |
| Library and export | Persistent edits, import, Photos and sharing | Local originals plus RAW and JSON edit recipes; PhotosPicker import; full-size edit/original export; system share sheet. Share destinations depend on installed apps. DNG import is currently treated as an imported source rather than a paired RAW asset. |
| Apple Intelligence | Still addition | Optional Foundation Models text suggestions, runtime availability checks and Vision fallback. No third-party cloud calls. |
| Depth assistance | Still addition | Capability-gated ARKit LiDAR center-distance measurement, confidence checks, smoothing and plane-status feedback, in a separate camera mode. No RAW capture inside AR mode. Front TrueDepth, 3D target placement and reconstructed viewpoint coaching are not implemented. |

[Scene depth support](https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth) is checked at runtime. The name Pro/Max alone is not used as a capability check. ARSession receives the camera only after AVCaptureSession stops, and pauses before returning it.

## Automated verification

The workflow archives a physical-device app, runs seven simulator checks covering operation gating, zoom capability examples, invalid zoom, crop transforms, aspect ratios, recipe persistence and the image-effects/export pipeline, then launches the simulator app and uploads a screenshot. Archive/test logs and xcresult bundles are uploaded even on failure. The IPA is packaged only after checks succeed.

Simulator camera-unavailable startup and a still-image rendering test do not verify actual camera hardware, photo formats, flash/torch, tracking accuracy, AR depth, model availability, sustained frame rate, battery use or heat.

## Device checklist — iOS 27.0

Install the latest build over the existing app with the same signing identity to preserve its library. Verify the version is 1.1 and use Settings > About & support > Camera diagnostics to share the actual runtime report.

1. Launch, grant Camera access; check viewfinder is full size without compatibility letterboxing. Deny access on a clean install separately and verify Open Settings/Retry.
2. Take 20 HEIF photos; rapidly press shutter during processing. Exactly one request should run, each original should appear in Library, and the app should remain responsive.
3. Change every available lens 20 times, pinch and swipe zoom. Verify labels against the hardware and that 0.5x is available when supported. Switch front/back 20 times and verify correct mirroring, focus and RAW availability.
4. Move exposure through its range, select manual ISO/shutter, return to automatic. Verify displayed values, image exposure, tap focus and long-press AE/AF lock.
5. In a dark room, test Flash Off/Auto/On by actually taking a photo. Separately toggle the flashlight button and verify continuous LED illumination before taking a photo. Switch cameras and background the app; the torch must turn off.
6. Test available RAW/ProRAW combinations on each camera. Save original+RAW and check Photos recognizes the pair. Unsupported choices must be unavailable or produce a useful explanation.
7. Check each aspect ratio against the exported photograph. Verify upright orientation and capture metadata.
8. Turn Guide on/off; select, move and resize a region. Move the phone, verify the box follows the subject and movement directions are correct. When tracking fails, reselect. Guide off should stop expensive image analysis.
9. Open Depth Assist from exposure controls > timer menu. Aim the center at a textured surface; check the approximate distance changes sensibly and uncertain glass/dark surfaces do not display trusted measurements. Close/reopen it and test background recovery. Devices without LiDAR must not offer this mode.
10. Capture/import, change every editor category, compare Original, dismiss/reopen and restart the app. Verify the recipe persists and originals remain intact. Export and share; deny Photos add permission and confirm recovery without losing the local original.
11. Cancel a timer, interrupt capture with background/foreground cycles, and repeat Settings/Library/Editor transitions. No operations should restart the camera behind AR or another sheet.
12. Run a ten-minute preview/guide session, checking frame pacing, memory and temperature in device tools. Measurements must be recorded before making performance claims. Repeat with Low Power Mode and large accessibility text.

If a crash persists, send the exact action sequence, format/lens, and Still's diagnostics. Also share the Still .ips report from iPhone Settings > Privacy & Security > Analytics & Improvements > Analytics Data (look for Still and the matching time). Crash reports, rather than screenshots alone, are needed to attribute remaining failures.

## Current boundaries

iOS 27.0 physical verification remains pending until these checks are run on the user's phone. This Windows workspace has no local Xcode or connected iPhone. CI uses the SDK actually installed on its Mac runner and does not imply that SDK is version 27. Local photos are not encrypted beyond iOS app sandbox/data protection, are not synced across devices, and are removed if the app is deleted.
