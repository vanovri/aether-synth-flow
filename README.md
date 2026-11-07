# AetherSynth & Flow

Offline-first **iOS 18, visionOS 2, macOS 15 Sequoia, watchOS 11 & AUv3 / Swift 6** Spatial Focus Timer, Gravitational Habit Matrix, 6-DoF Bimanual Hand-Tracking Synthesizer, Stereoscopic `CompositorServices` Metal Engine, Wrist HealthKit HRV Biometric Streamer, On-Device CoreML Neural Brainwave Predictor, and Real-Time Procedural Audio/Visual Workstation with zero external package dependencies.

## System Architecture

| Layer | Implementation |
| --- | --- |
| **SwiftData & Concurrency** | `FocusSession`, `HabitNode`, `AudioPreset`, `DailyTelemetry` managed by `@ModelActor TelemetryDatabaseActor` with App Group container sharing (`group.com.aethersynth.flow`), chunked batch ingestion, and deterministic conflict policies (`higherRevisionWins`, `newerTimestampWins`, `mergeAccumulate`, `keepExisting`). |
| **Procedural DSP & vDSP FFT** | Allocation-free `ProceduralSynthKernel` inside `AVAudioSourceNode` (`os_unfair_lock_trylock` wait-free bridge) synthesizing stereo binaural beats, 4-operator through-zero FM, Paul Kellet 7-pole $1/f$ pink noise, 5-voice detuned ambient pads, and cascaded 24dB/oct Cytomic TPT SVF filtering, paired with `SpectralFFTAnalyzer` (`Accelerate/vDSP` 256-point Hann DFT → 64 perceptual bars + sub/low/mid/high energy bands). |
| **6-DoF Spatial Telemetry & Procedural Meshes** | Pure-SIMD `SpatialPoseTelemeter` mapping left-hand thumb–index pinch (`0.005m...0.12m`) to logarithmic `binauralBeatHz` (`1.5...40.0 Hz`) with Schmitt-trigger hysteresis, right-hand pinch to Cytomic SVF `filterCutoffHz` (`120...12,000 Hz`) + quaternion wrist roll to `filterResonance` (`0.08...0.92`), and bimanual palm span (`0.10m...0.85m`) to `padDetuneCents`, `bloomBoost`, and `orbitalRadiusScale`. `ProceduralMeshGenerator` builds manifold geodesic icosahedron and Keplerian $(p,q)$ torus-knot buffers. |
| **visionOS 2 `RealityKit` & `ARKit` Hand Tracking** | `AetherVisionApp` coordinates a 2D glass control deck (`aether-control-deck`), a `0.85m³` volumetric orbital window (`VolumetricOrbitalRealityView`) with inclined 3D Keplerian habit satellites emitting phase-continuous spatial overtones, and `BimanualHandTrackingActor` (`ARKitSession` + `HandTrackingProvider` at 90Hz with deterministic Lissajous Gesture Simulator fallback). |
| **visionOS 2 `CompositorServices` Metal Engine** | `AetherCompositorRenderer` & `AetherCompositorShaders.metal` running a 90Hz background `LayerRenderer` loop (`.rgba16Float` HDR, `.depth32Float` reverse-Z, `.layered` layout, foveated rendering `isFoveationEnabled`) with a double-buffered 16,384-particle 3D curl-noise compute kernel (`aetherCurlNoiseParticleKernel`) and single-pass stereoscopic vertex/fragment shaders (`[[render_target_array_index]]`). |
| **macOS 15 Sequoia Studio, `MenuBarExtra` & CoreAudio HAL** | `AetherMacApp` 3-column `NavigationSplitView` desktop workstation, native `.menuBarExtraStyle(.window)` live countdown + waveform bar, borderless always-on-top floating `NSPanel` PiP HUD (`FloatingOrbitalHUDController`), global hotkey monitor (`MacGlobalShortcutController`: `⌘⇧F`, `⌘⇧B`, `⌘⇧H`, `⌘⇧]`), and zero-dependency `CoreAudioDeviceManager` HAL output router with hot-plug listeners. |
| **HRV Signal Processing & Lomb-Scargle** | `BiometricTelemetryModels` (`HRVSignalProcessor`) computing ectopic-filtered SDNN, RMSSD, pNN50, Baevsky Stress Index ($SI$), Poincaré $\text{SD1}/\text{SD2}$ geometry, and uneven-grid Lomb-Scargle periodogram (`0.04–0.15 Hz` Mayer LF & `0.15–0.40 Hz` vagal HF bands). |
| **CoreML + `MPSGraph` GPU Autodiff Entrainment** | `AdaptiveBrainwaveMLPredictor` packing `[1, 12]` `MLMultiArray` / `BiometricFeatureProvider` tensors into a 3-layer SIMD MLP (`12 -> 24 -> 16 -> 5` with LayerNorm, GELU, skip connections, Huber-loss online personalization) + `EntrainmentPIDController` closed-loop audio damping, paired with `MPSGraphBrainwaveTrainer` (`MetalPerformanceShadersGraph` reverse-mode autodiff temporal self-attention `[Batch, 8, 12] -> 32 -> 5` with in-graph Smooth-L1 loss, global L2 gradient clipping $\|\nabla\mathcal{L}\|_2 \le 1.0$, and compiled `MPSGraphExecutable` AdamW updates + deterministic CPU SIMD fallback). |
| **watchOS 11 & WatchConnectivity** | `WatchHealthKitBiometricEngine` (`HKWorkoutSession` + `HKLiveWorkoutBuilder` + `HKHeartbeatSeriesQuery` + `.mindfulSession`), Digital Crown + Double-Tap (`WatchOrbitalCrownView`), `WatchSmartStackWidget` complications, and 64-bit FNV-1a binary `WatchBiometricBridgeActor` + `SyntheticPhysiologySimulator`. |
| **3D Binaural KEMAR HRTF, Shoebox ISM & Neural DSP** | Parametric KEMAR 128-tap HRIR synthesizer (`KEMARHRIRSynthesizer`: Woodworth-Schlosberg diffraction ITD, 4th-order Thiran fractional delay, Brown & Duda spherical head-shadow ILD, and 4-stage pinna notch cascade) + allocation-free UPOLS Radix-2 FFT convolver (`PartitionedOverlapSaveConvolver` / `SpatialHRTFConvolver` with dual-path raised-cosine crossfade), 8-channel normalized Hadamard FDN Reverb + 4-operator Through-Zero FM (`ReverbAndFMDSP`), 24-bit/32-bit RIFF/WAVE stem renderer (`OfflineStemExporter`), 18-source 3D Shoebox Image-Source early reflection solver (`ShoeboxRoomSimulator` + `OrbitalHabitSpatializer`), 2D/3D FDTD PML acoustic waveguide (`FDTDWaveguideSolver`), Metal ray-traced directional room impulse response (`MetalAcousticRayTracer`), and RVQ + Snake rectified-flow neural soundscape (`NeuralLatentSoundscapeEngine`). |
| **Audio Unit v3 (`AetherSynthAUv3`) & Sub-ms PTP/WFS Orchestra** | Allocation-free `AetherSynthAudioUnit` (`aumu` instrument + `aumf` spatial FX, `44.1...192 kHz`, 5 factory presets) with sample-accurate `internalRenderBlock` sub-block event slicing (`AURenderEventParameter`, `AURenderEventParameterRamp`, `AURenderEventMIDI`), 16-parameter lock-free `RealtimeParameterBank` (`Synchronization.Atomic<UInt32>` + raw ramp buffers in `AUParameterTreeBridge`), 8-voice MIDI/MPE `MPEPolyphonicVoiceBank` (Master Ch 1 + Member Ch 2–16 $\pm 48\text{ st}$ pitch bend, aftertouch, CC74 slide, Oldest-Released / Quietest-Envelope stealing with `2.5 ms` raised-cosine crossfade), SwiftUI `AetherAUv3ViewController`, and `DistributedOrchestraEngine` (`mach_continuous_time()` monotonic clock, 64-byte 4-timestamp PTP/NTP `OrchestraPTPClockPacket` with 64-bit FNV-1a tag, `MarzulloClockFilter` $W=16$ interval intersection + IEEE 1139 Allan deviation $\sigma_y(\tau)$, critically damped 2nd-order PI-PLL `PhaseLockedLoopClockServo` $\alpha_{\text{pll}} \in [0.9990, 1.0010]$, and 2.5D Rayleigh I WFS `SpatialWaveFieldSolver` with 4-point 3rd-order Lagrange fractional ToF delay line). |
| **Cortical EEG BCI, SPWVD/HHT, Quantum MPS/DMRG & Optical Caustics** | 4-channel 256 Hz BLE EEG receiver + zero-phase 50/60 Hz notch + causal RLS ocular blink rejection + Bispectral Index ($BIS$) + Tort Theta-Gamma PAC (`EEGBrainComputerInterface`), Smoothed Pseudo Wigner-Ville Distribution & Empirical Mode Decomposition (`WignerVilleHilbertHuangAnalyzer`), 6-site Matrix Product State (MPS) + 2-site DMRG variational solver (`TensorNetworkQuantumOptimizer`), Sellmeier chromatic dispersion + CIE 1931 optical caustics (`SpectralCausticsRenderer`), 2D Kalman focus estimator + Hermite spline ramps (`CognitiveEntrainmentEngine`), Curve25519 + ChaChaPoly Bonjour P2P sync (`AetherMeshSyncActor`), and 12-stage SHA-256 benchmark verifier (`AetherCapstoneBenchmarkSuite`). |
| **Metal 3 Shaders & 120Hz Particles** | Stitchable `aetherAurora` triple-stage fluid domain-warping FBM shader + `interactiveRipple` refractive wave-equation layer shader + 64-step sphere-traced 3D SDF raymarcher (`aetherRaymarchedCore` / `OrbitalSDFCoreView`) + 120Hz ProMotion `TimelineView(.animation)` & `Canvas` vortex/wake particle simulation. |
| **iOS 18 System Surfaces & Portability** | Lock Screen & Dynamic Island `ActivityKit` Live Activities (`FocusLiveActivityWidget`), Home Screen `WidgetKit` 7-day heatmap (`HabitMatrixHomeWidget`), Control Center toggle (`SpatialFocusControlWidget`), FNV-1a 64-bit checksum JSON archive (`AetherTelemetryArchive`), and RFC-4180 CSV exporter (`TelemetryCSVSerializer`). |

## Targets (`project.yml`)

- **`AetherSynthFlow`**: Main iOS 18.0+ application (`SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`).
- **`AetherSynthWidgets`**: Embedded iOS 18 WidgetKit / ActivityKit / ControlWidget extension.
- **`AetherSynthVision`**: Native visionOS 2.0+ volumetric `RealityKit`, `ARKit` bimanual hand tracking, and `CompositorServices` stereoscopic Metal target.
- **`AetherSynthMac`**: Native macOS 15.0+ Sequoia 3-column desktop studio, `MenuBarExtra`, floating `NSPanel` HUD, and `CoreAudio` HAL router.
- **`AetherSynthWatch`**: Companion watchOS 11.0+ HealthKit HRV streamer, Digital Crown controller, and Smart Stack complication target.
- **`AetherSynthAUv3`**: Audio Unit v3 (`aufx`/`aumu`) DAW instrument & spatial effect extension.
- **`AetherSynthTests` & `AetherSynthMacTests`**: `Swift Testing` (`@Suite`, `@Test`) verification suites covering concurrency, multi-sample-rate DSP/FFT (`44.1/48/96 kHz`), 6-DoF `SpatialPoseTelemeter`, manifold `ProceduralMeshGenerator`, Lomb-Scargle HRV, CoreML/MLP online SGD, and AUv3/acoustics invariants.

## Build & Verify (macOS 15 / Xcode 16+)

```bash
brew install xcodegen
xcodegen generate

# macOS 15 Native Build & Swift Testing Suite
xcodebuild test \
  -project AetherSynthFlow.xcodeproj \
  -scheme AetherSynthMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

# iOS 18 Simulator Build & Test
xcodebuild test \
  -project AetherSynthFlow.xcodeproj \
  -scheme AetherSynthFlow \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO

# visionOS 2 Simulator Build
xcodebuild build \
  -project AetherSynthFlow.xcodeproj \
  -scheme AetherSynthVision \
  -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

# watchOS 11 Simulator Build
xcodebuild build \
  -project AetherSynthFlow.xcodeproj \
  -scheme AetherSynthWatch \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Automated macOS-15 / Xcode 16 multi-platform matrix CI runs on every push via `.github/workflows/ios-ci.yml`.
