# Still 1.2 — guided shooting

Target: iPhone 17 Pro Max running iOS 27.0. Minimum deployment target: iOS 18. Runtime feature checks decide which camera path is available.

## How to use it

1. In Settings, choose a guided style: Instagram post, Portrait, Architecture, Details, Story, Scenery or Everyday.
2. Optionally enter a short preference. “A minimal Instagram post with room for text” uses a 4:5 crop and more subject spacing. “Centered”, “square” and “negative space” also affect framing.
3. Tap **GUIDE** beside PHOTO. Opening Guide starts a single local scene scan.
4. A thin yellow frame marks the suggested composition. The white + remains at the center of the viewfinder. Move the phone in the indicated direction until they meet.
5. If enabled, auto zoom sets the framing. Hold steady until the progress ring completes. The guide takes **one** photo and returns to the camera.
6. Turn AUTO off to use the shutter manually. The rescan menu can choose a new composition or let you draw around a detail.
7. Open the thumbnail to develop a photo. The normal camera stays open after capture unless Review after each photo is enabled.

A successful capture is stored in Still's private library. Export to Photos from the editor. Deleting the app removes its private library.

## What is implemented

| Capability | Implementation | Constraint |
|---|---|---|
| Suggested composition | Vision faces, people, objectness saliency and geometric rectangles; a bounded crop search scores subject retention, placement, spacing and clipped surrounding faces | Heuristics recommend a frame; they cannot guarantee aesthetic quality or understand arbitrary visual concepts |
| Target lock | A selected crop is frozen relative to its chosen detail; detection does not choose a different target every frame | Visual tracking can lose texture, occlude or drift; a lost target requires rescan |
| LiDAR scene lock | Confidence-checked depth places a camera-facing frame plane in ARKit world coordinates, with an ARAnchor and projected corners | For stationary scene details on LiDAR devices with a compatible high-resolution AR camera format; unreliable or distant depth falls back to visual tracking |
| Guided photo | ARKit high-resolution still capture in scene mode; AVCapturePhotoOutput in visual mode | AR scene mode uses the wide camera, JPEG and a center crop up to 2×. It is a digital crop, not an optical lens change |
| Auto zoom | Bounded crop zoom in AR; a hardware zoom ramp in the AVFoundation fallback | Zoom must settle before automatic capture. The cap limits resolution loss |
| Auto shutter | Confidence, center tolerance, level, continuous steady dwell, fresh frames and camera readiness gate one capture | Never active outside an explicitly opened guided session. No repeat capture until another scan |
| Preferences | Presets and local prompt keywords change aspect, centering, spacing and candidate weighting | Not an internet research feature. Preferences do not fetch social trends |
| Apple Intelligence | Optional Foundation Models classifies the written preference once in Settings | Requires an available eligible model; camera frames are not passed to it, and the shutter never waits for it |
| Daily camera flow | Review defaults off; private saving and thumbnail generation run away from the main thread | Hardware capture and storage still take finite time; no “zero lag” claim |
| Capture recovery | Captured bytes survive a failed library write for Retry; closing/backgrounding disarms the guide | Unexpected OS termination before a private write completes cannot preserve an in-memory photo |

Flash, torch, manual exposure and the regular timer remain in PHOTO mode. RAW guidance uses the visual path. Front TrueDepth, semantic scene reconstruction, Live Photos and video are outside this iteration.

## Performance architecture

- Only one owner uses the camera at a time. AVCaptureSession releases it before ARKit starts; Guide releases it before normal capture resumes.
- AR and AV frame callbacks admit at most one retained analysis frame and discard excess frames.
- Vision reuses a pixel buffer with a maximum side of 640 pixels. Full scene detection runs once per scan; subsequent visual updates use an object tracker.
- A depth-anchored frame uses inexpensive 3D projection without rerunning Vision.
- Normal conditions permit up to 20 visual updates or 30 anchor projections per second. Low power or serious thermal pressure reduces that cadence. Critical heat suspends guided capture.
- A gap in frames, tracking loss, occlusion, tilt, motion or unsettled focus/exposure resets the steady hold.
- Live camera preview is separate from the analysis cadence. Actual frame pacing, heat and first-scan latency require measurement on a physical device.

## Reference grounding

The supplied promotional images establish the visual direction: a large viewfinder, thin yellow target frame, central aiming mark, short movement instruction, restrained dark controls, and a separate film-development workflow.

[Framed's public website](https://shootframed.com/) describes a scan that identifies a frame and gives movement guidance, followed by film-inspired editing. [Its App Store listing](https://apps.apple.com/us/app/framed-take-aesthetic-photos/id6761207600) describes automatic framing and tracking, capture controls and post-capture editing. These public descriptions do not establish that Framed uses LiDAR or reveal its private scoring algorithm. Still's anchor and scoring implementations are independent.

Apple documents [depth frame semantics](https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth), [unprojecting a screen point onto a plane](https://developer.apple.com/documentation/arkit/arcamera/unprojectpoint(_:ontoplane:orientation:viewportsize:)), and [high-resolution AR still capture](https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe(completion:)). Apple's [ARKit camera presentation](https://developer.apple.com/videos/play/wwdc2022/10126/) explains the high-resolution camera path and its distinction from the regular streaming image.

## Verification

The cloud workflow archives a physical arm64 app, runs simulator checks, launches the app and packages an unsigned IPA. The new unit cases cover intent, candidate choice, crop retention/aspect, frozen target transforms, zoom limits, one-shot capture, stale frames, motion, confidence, tilt and camera readiness. Existing camera and image pipeline tests remain.

Simulator results cannot establish LiDAR accuracy, optical lens behavior, high-resolution AR quality, model availability or smoothness on iOS 27.0.

On the physical target, check a stationary textured subject in good light first. Scan, translate and rotate the phone: the world frame should stay at the selected location. Align the +, allow the zoom to settle and confirm exactly one capture. Repeat with LiDAR off, RAW selected, Auto off, rescan, manual selection, occlusion and backgrounding. Confirm the private photo matches the visible crop and survives a relaunch. Report a matching .ips crash log and Settings > Camera diagnostics if the device fails.

