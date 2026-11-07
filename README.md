# AetherSynth & Flow

Offline-first **iOS 18 & watchOS 11 / Swift 6** Spatial Focus Timer, Gravitational Habit Matrix, Wrist HealthKit HRV Biometric Streamer, On-Device CoreML Neural Brainwave Predictor, and Real-Time Procedural Audio/Visual Synthesizer with zero external package dependencies.

## System Architecture

| Layer | Implementation |
| --- | --- |
| **SwiftData & Concurrency** | `FocusSession`, `HabitNode`, `AudioPreset`, `DailyTelemetry` managed by `@ModelActor TelemetryDatabaseActor` with App Group container sharing (`group.com.aethersynth.flow`), chunked batch ingestion, and deterministic conflict policies (`higherRevisionWins`, `newerTimestampWins`, `mergeAccumulate`, `keepExisting`). |
| **Procedural DSP & vDSP FFT** | Allocation-free `ProceduralSynthKernel` inside `AVAudioSourceNode` (`os_unfair_lock_trylock` wait-free bridge) synthesizing stereo binaural beats, Paul Kellet 7-pole $1/f$ pink noise, 5-voice detuned ambient pads, and cascaded 24dB/oct Cytomic TPT SVF filtering, paired with `SpectralFFTAnalyzer` (`Accelerate/vDSP` 256-point Hann DFT → 64 perceptual bars). |
| **HRV Signal Processing & Lomb-Scargle** | `BiometricTelemetryModels` (`HRVSignalProcessor`) computing ectopic-filtered SDNN, RMSSD, pNN50, Baevsky Stress Index ($SI$), Poincaré $\text{SD1}/\text{SD2}$ geometry, and uneven-grid Lomb-Scargle periodogram (`0.04–0.15 Hz` Mayer LF & `0.15–0.40 Hz` vagal HF bands). |
| **CoreML + SIMD Neural Entrainment** | `AdaptiveBrainwaveMLPredictor` packing `[1, 12]` `MLMultiArray` / `BiometricFeatureProvider` tensors into a 3-layer SIMD MLP (`12 -> 24 -> 16 -> 5` with LayerNorm, GELU, skip connections, Huber-loss online personalization) + `EntrainmentPIDController` closed-loop audio damping. |
| **watchOS 11 & WatchConnectivity** | `WatchHealthKitBiometricEngine` (`HKWorkoutSession` + `HKLiveWorkoutBuilder` + `HKHeartbeatSeriesQuery` + `.mindfulSession`), Digital Crown + Double-Tap (`WatchOrbitalCrownView`), `WatchSmartStackWidget` complications, and 64-bit FNV-1a binary `WatchBiometricBridgeActor` + `SyntheticPhysiologySimulator`. |
| **Metal & 120Hz Particles** | Stitchable `aetherAurora` triple-stage fluid domain-warping FBM shader + `interactiveRipple` refractive wave-equation layer shader with RGB optical dispersion + 120Hz ProMotion `TimelineView(.animation)` & `Canvas` vortex/wake particle simulation. |
| **iOS 18 System Surfaces** | Lock Screen & Dynamic Island `ActivityKit` Live Activities (`FocusLiveActivityWidget`), Interactive Home Screen `WidgetKit` 7-day heatmap (`HabitMatrixHomeWidget` + `LogHabitPulseIntent`), and iOS 18 Control Center toggle (`SpatialFocusControlWidget`). |
| **Ledger Portability** | Verified FNV-1a 64-bit checksum JSON archive backup/restore (`AetherTelemetryArchive`) and RFC-4180 CSV session exporter (`TelemetryCSVSerializer`). |

## Targets (`project.yml`)

- **`AetherSynthFlow`**: Main iOS 18.0+ application (`SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`).
- **`AetherSynthWidgets`**: Embedded iOS 18 WidgetKit / ActivityKit / ControlWidget extension.
- **`AetherSynthWatch`**: Companion watchOS 11.0+ HealthKit HRV streamer, Digital Crown controller, and Smart Stack complication target.
- **`AetherSynthTests`**: `Swift Testing` (`@Suite`, `@Test`) verification suite covering concurrency, DSP/FFT, Lomb-Scargle HRV, CoreML/MLP online SGD, and WatchConnectivity closed-loop convergence.

## Build & Verify (macOS / Xcode 16+)

```bash
brew install xcodegen
xcodegen generate

xcodebuild test \
  -project AetherSynthFlow.xcodeproj \
  -scheme AetherSynthFlow \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project AetherSynthFlow.xcodeproj \
  -scheme AetherSynthWatch \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Automated macOS-15 / Xcode 16 CI runs on every push via `.github/workflows/ios-ci.yml`.
