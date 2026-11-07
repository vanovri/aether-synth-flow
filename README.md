# AetherSynth & Flow

Offline-first **iOS 18 / Swift 6** Spatial Focus Timer, Gravitational Habit Matrix, and Real-Time Procedural Audio/Visual Synthesizer with zero external package dependencies.

## System Architecture

| Layer | Implementation |
| --- | --- |
| **SwiftData & Concurrency** | `FocusSession`, `HabitNode`, `AudioPreset`, `DailyTelemetry` managed by `@ModelActor TelemetryDatabaseActor` with App Group container sharing (`group.com.aethersynth.flow`), chunked batch ingestion, and deterministic conflict policies (`higherRevisionWins`, `newerTimestampWins`, `mergeAccumulate`, `keepExisting`). |
| **Procedural DSP & vDSP FFT** | Allocation-free `ProceduralSynthKernel` inside `AVAudioSourceNode` (`os_unfair_lock_trylock` wait-free bridge) synthesizing stereo binaural beats, Paul Kellet 7-pole $1/f$ pink noise, 5-voice detuned ambient pads, and cascaded 24dB/oct Cytomic TPT SVF filtering, paired with `SpectralFFTAnalyzer` (`Accelerate/vDSP` 256-point Hann DFT → 64 perceptual bars). |
| **Metal & 120Hz Particles** | Stitchable `aetherAurora` triple-stage fluid domain-warping FBM shader + `interactiveRipple` refractive wave-equation layer shader with RGB optical dispersion + 120Hz ProMotion `TimelineView(.animation)` & `Canvas` vortex/wake particle simulation. |
| **Spatial UI & Tactile Engine** | Custom `RadialOrbitalLayout: Layout` with Keplerian inverse-mass radial stratification, zoomable/pannable 365-day contribution heatmap with `OrbitalMatrixWarpEffect: GeometryEffect` 3D transitions, `.matchedGeometryEffect` segmented navigation, and `CHHapticEngine` continuous/transient curves. |
| **iOS 18 System Surfaces** | Lock Screen & Dynamic Island `ActivityKit` Live Activities (`FocusLiveActivityWidget`), Interactive Home Screen `WidgetKit` 7-day heatmap (`HabitMatrixHomeWidget` + `LogHabitPulseIntent`), and iOS 18 Control Center toggle (`SpatialFocusControlWidget`). |
| **Hardware & Media Integration** | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` Lock Screen playback & preset cycling, `AVAudioSession` interruption/unplug auto-pause, and AirPods Pro/Max `CMHeadphoneMotionManager` head-yaw constant-power panning. |
| **Ledger Portability** | Verified FNV-1a 64-bit checksum JSON archive backup/restore (`AetherTelemetryArchive`) and RFC-4180 CSV session exporter (`TelemetryCSVSerializer`). |

## Targets (`project.yml`)

- **`AetherSynthFlow`**: Main iOS 18.0+ application (`SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`).
- **`AetherSynthWidgets`**: Embedded WidgetKit / ActivityKit / ControlWidget extension.
- **`AetherSynthTests`**: `Swift Testing` (`@Suite`, `@Test`) verification suite.

## Build & Verify (macOS / Xcode 16+)

```bash
brew install xcodegen
xcodegen generate

xcodebuild test \
  -project AetherSynthFlow.xcodeproj \
  -scheme AetherSynthFlow \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

Automated macOS-15 / Xcode 16 CI runs on every push via `.github/workflows/ios-ci.yml`.
