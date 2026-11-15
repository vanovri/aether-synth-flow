# AetherSynth & Flow

A Swift and Metal spatial-audio prototype with Apple-platform targets, DSP kernels, synthetic physiology, and numerical tests.

## Implementation

- [Audio synthesis](Sources/App/Audio/AudioSynthEngine.swift), [FFT analysis](Sources/App/Audio/SpectralFFTAnalyzer.swift), and [spatial filtering](Sources/App/Audio/SpatialHRTFConvolver.swift).
- [Acoustic simulation](Sources/App/Audio/FDTDWaveguideSolver.swift) and [graphics sources](Sources/App/Graphics/).
- [BLE packet processing](Sources/Shared/EEGBrainComputerInterface.swift), [tests](Tests/AetherSynthTests/), and [XcodeGen configuration](project.yml).

The configuration defines iOS 18, macOS 15, visionOS 2, watchOS 11, widget, and AUv3 targets. A configured target is not evidence that a build or device test passed.

## Build and test

Use macOS with Xcode 16 or later and XcodeGen. The Apple frameworks require their platform SDKs.

```sh
brew install xcodegen
xcodegen generate
xcodebuild build -project AetherSynthFlow.xcodeproj -scheme AetherSynthMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project AetherSynthFlow.xcodeproj -scheme AetherSynthMacTests -destination 'platform=macOS' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES
```

Other builds need the corresponding SDK and simulator. The [workflow](.github/workflows/ios-ci.yml) contains the configured destinations and commands.

## Evidence and scope

The [verified CI run on 15 November 2026](https://github.com/vanovri/aether-synth-flow/actions/runs/43730846782) passed at source commit `33e8a23f97479848a0c35dd6c195fd310dd025af`. It executed the native macOS Swift Testing suite, built iOS application/extension targets and the iOS test bundle, and built the visionOS and watchOS targets. The iOS step uses `build-for-testing`; it does not execute simulator tests.

The BLE synchronizer now accepts an optional acquisition sequence origin. This preserves producer sample indices through initial packet reordering, missing prefixes, and UInt16 rollover. An unknown origin retains the first-measurement-zero clock. The Track31 numerical assertions remain unchanged, with two added origin-contract regression tests. Native throughput assertions run with Release optimization and retain their original time budget. See [current CI](https://github.com/vanovri/aether-synth-flow/actions) for later commits.

Earlier latency, attenuation, allocation, and blanket test-pass claims have been removed because the audit did not reproduce them. Synthetic signal fixtures do not establish clinical accuracy, Apple Watch measurement validity, or headset performance.

Developed with AI coding assistance. [Portfolio notes](https://ardhyanovri.my.id/projects/aether-synth-flow.html).
