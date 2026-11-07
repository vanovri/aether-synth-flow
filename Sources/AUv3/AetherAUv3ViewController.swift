// MARK: - FILE: AetherAUv3ViewController.swift

import Foundation
import SwiftUI
import Observation
import Synchronization
#if canImport(AudioToolbox) && canImport(CoreAudioKit) && !os(watchOS)
import AudioToolbox
import CoreAudioKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - 1. 60fps Observable ViewModel Bridging AetherSynthAudioUnit <-> SwiftUI

@Observable
@MainActor
public final class AetherAUv3ViewModel {
    public var spectrumBars: [Float] = [Float](repeating: 0.0, count: SpectralFFTAnalyzer.outputBarCount)
    public var dominantFrequencyHz: Float = 0.0
    public var voiceConstellation: [MPEVoiceConstellationPoint] = (0..<MPEPolyphonicVoiceBank.maxVoices).map {
        MPEVoiceConstellationPoint(voiceIndex: $0)
    }

    public var selectedPresetNumber: Int = 0
    public var autonomousDroneEnabled: Bool = false
    public var hostTempoBPM: Double = 120.0
    public var isHostMoving: Bool = false

    // Live mirrored parameter state for responsive 60fps XY pads & macro controls
    public var carrierFrequencyHz: Float = AetherAUParameterAddress.carrierFrequencyHz.defaultValue
    public var binauralBeatHz: Float = AetherAUParameterAddress.binauralBeatHz.defaultValue
    public var filterCutoffHz: Float = AetherAUParameterAddress.filterCutoffHz.defaultValue
    public var filterResonance: Float = AetherAUParameterAddress.filterResonance.defaultValue
    public var reverbWetMix: Float = AetherAUParameterAddress.reverbWetMix.defaultValue
    public var reverbDecaySeconds: Float = AetherAUParameterAddress.reverbDecaySeconds.defaultValue
    public var fmModulationIndex: Float = AetherAUParameterAddress.fmModulationIndex.defaultValue
    public var hrtfAzimuthDeg: Float = AetherAUParameterAddress.hrtfAzimuthDeg.defaultValue
    public var hrtfElevationDeg: Float = AetherAUParameterAddress.hrtfElevationDeg.defaultValue
    public var hrtfDistanceMeters: Float = AetherAUParameterAddress.hrtfDistanceMeters.defaultValue
    public var neuralSoundscapeMix: Float = AetherAUParameterAddress.neuralSoundscapeMix.defaultValue
    public var masterGain: Float = AetherAUParameterAddress.masterGain.defaultValue

    private weak var audioUnit: AetherSynthAudioUnit?
    private var observerToken: AUParameterObserverToken?
    private var displayLoopTask: Task<Void, Never>?
    private let fftAnalyzer = SpectralFFTAnalyzer()

    public init() {}

    public func attach(audioUnit unit: AetherSynthAudioUnit) {
        detach()
        self.audioUnit = unit
        syncAllParametersFromUnit(unit)

        if let tree = unit.parameterTree {
            observerToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
                Task { @MainActor [weak self] in
                    self?.applyObservedParameter(address: address, value: value)
                }
            })
        }

        start60FPSDisplayLoop()
    }

    public func detach() {
        displayLoopTask?.cancel()
        displayLoopTask = nil
        if let token = observerToken, let tree = audioUnit?.parameterTree {
            tree.removeParameterObserver(token)
        }
        observerToken = nil
        audioUnit = nil
    }

    private func start60FPSDisplayLoop() {
        displayLoopTask?.cancel()
        displayLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                self.tickTelemetryFrame()
            }
        }
    }

    private func tickTelemetryFrame() {
        guard let unit = audioUnit else { return }
        let kernel = unit.renderKernel

        let scopeSamples = kernel.copyRecentScopeSamples()
        let fftFrame = fftAnalyzer.analyze(samples: scopeSamples, sampleRate: kernel.sampleRate)
        spectrumBars = fftFrame.bars
        dominantFrequencyHz = fftFrame.dominantFrequencyHz

        voiceConstellation = kernel.voiceBank.snapshotVoiceConstellation()
        hostTempoBPM = kernel.lastHostTempoBPM
        isHostMoving = kernel.isHostTransportMoving
        autonomousDroneEnabled = kernel.autonomousDroneEnabled

        // Keep UI synced with sample-accurate DAW parameter ramps
        filterCutoffHz = unit.parameterBank.getHostValue(for: .filterCutoffHz)
        filterResonance = unit.parameterBank.getHostValue(for: .filterResonance)
        hrtfAzimuthDeg = unit.parameterBank.getHostValue(for: .hrtfAzimuthDeg)
        hrtfElevationDeg = unit.parameterBank.getHostValue(for: .hrtfElevationDeg)
        hrtfDistanceMeters = unit.parameterBank.getHostValue(for: .hrtfDistanceMeters)
        masterGain = unit.parameterBank.getHostValue(for: .masterGain)
    }

    private func syncAllParametersFromUnit(_ unit: AetherSynthAudioUnit) {
        let bank = unit.parameterBank
        carrierFrequencyHz = bank.getHostValue(for: .carrierFrequencyHz)
        binauralBeatHz = bank.getHostValue(for: .binauralBeatHz)
        filterCutoffHz = bank.getHostValue(for: .filterCutoffHz)
        filterResonance = bank.getHostValue(for: .filterResonance)
        reverbWetMix = bank.getHostValue(for: .reverbWetMix)
        reverbDecaySeconds = bank.getHostValue(for: .reverbDecaySeconds)
        fmModulationIndex = bank.getHostValue(for: .fmModulationIndex)
        hrtfAzimuthDeg = bank.getHostValue(for: .hrtfAzimuthDeg)
        hrtfElevationDeg = bank.getHostValue(for: .hrtfElevationDeg)
        hrtfDistanceMeters = bank.getHostValue(for: .hrtfDistanceMeters)
        neuralSoundscapeMix = bank.getHostValue(for: .neuralSoundscapeMix)
        masterGain = bank.getHostValue(for: .masterGain)
        selectedPresetNumber = unit.currentPreset?.number ?? 0
        autonomousDroneEnabled = unit.renderKernel.autonomousDroneEnabled
    }

    private func applyObservedParameter(address: AUParameterAddress, value: AUValue) {
        guard let param = AetherAUParameterAddress(rawValue: address) else { return }
        let v = param.clamp(value)
        switch param {
        case .carrierFrequencyHz: carrierFrequencyHz = v
        case .binauralBeatHz: binauralBeatHz = v
        case .filterCutoffHz: filterCutoffHz = v
        case .filterResonance: filterResonance = v
        case .reverbWetMix: reverbWetMix = v
        case .reverbDecaySeconds: reverbDecaySeconds = v
        case .fmModulationIndex: fmModulationIndex = v
        case .hrtfAzimuthDeg: hrtfAzimuthDeg = v
        case .hrtfElevationDeg: hrtfElevationDeg = v
        case .hrtfDistanceMeters: hrtfDistanceMeters = v
        case .neuralSoundscapeMix: neuralSoundscapeMix = v
        case .masterGain: masterGain = v
        case .binauralMix, .pinkNoiseMix, .padMix, .padDetuneCents:
            break
        }
    }

    public func setParameter(_ param: AetherAUParameterAddress, value: Float) {
        let clamped = param.clamp(value)
        applyObservedParameter(address: param.rawValue, value: clamped)
        guard let unit = audioUnit else { return }
        unit.parameterBank.setHostValue(clamped, for: param)
        if let node = unit.parameterTree?.parameter(withAddress: param.rawValue) {
            if let token = observerToken {
                node.setValue(clamped, originator: token)
            } else {
                node.value = clamped
            }
        }
    }

    public func selectFactoryPreset(number: Int) {
        selectedPresetNumber = number
        guard let unit = audioUnit,
              let preset = unit.factoryPresets?.first(where: { $0.number == number }) else {
            return
        }
        unit.currentPreset = preset
        syncAllParametersFromUnit(unit)
    }

    public func toggleAutonomousDrone(_ enabled: Bool) {
        autonomousDroneEnabled = enabled
        audioUnit?.renderKernel.autonomousDroneEnabled = enabled
    }
}

// MARK: - 2. Compact Responsive SwiftUI AUv3 Plugin Interface

public struct AetherAUv3PluginView: View {
    @Bindable public var model: AetherAUv3ViewModel

    public init(model: AetherAUv3ViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.11),
                    Color(red: 0.07, green: 0.09, blue: 0.17),
                    Color(red: 0.03, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                factoryPresetBar

                HStack(spacing: 10) {
                    fftAndMPEConstellationCard
                    svfCutoffResonanceXYPad
                    binauralHRTFSpatialPuck
                }
                .frame(maxHeight: .infinity)

                macroStripBar
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 320)
    }

    // MARK: Preset Bar & Transport Sync Header

    private var factoryPresetBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isHostMoving ? Color.green : Color.cyan)
                    .frame(width: 7, height: 7)
                Text("AetherSynth AUv3")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(String(format: "%.0f BPM", model.hostTempoBPM))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.85))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AetherAUFactoryPresetSpec.allPresets) { spec in
                        let active = model.selectedPresetNumber == spec.number
                        Button {
                            model.selectFactoryPreset(number: spec.number)
                        } label: {
                            Text(spec.name)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(active ? .white : .white.opacity(0.68))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    active ? Color.cyan.opacity(0.35) : Color.white.opacity(0.08),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .strokeBorder(.white.opacity(active ? 0.55 : 0.14), lineWidth: 0.8)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                model.toggleAutonomousDrone(!model.autonomousDroneEnabled)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.autonomousDroneEnabled ? "waveform.circle.fill" : "pianokeys")
                        .font(.system(size: 11, weight: .bold))
                    Text(model.autonomousDroneEnabled ? "Drone On" : "MPE Gate")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    model.autonomousDroneEnabled ? Color.purple.opacity(0.55) : Color.white.opacity(0.10),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 60fps 64-Bin FFT + 8-Voice MPE Pitch/Timbre/Pressure Constellation Radar

    private var fftAndMPEConstellationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("64-BIN FFT & MPE CONSTELLATION")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                let activeVoices = model.voiceConstellation.filter(\.isActive).count
                Text("\(activeVoices)/8 Voices")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }

            Canvas { context, size in
                let w = size.width
                let h = size.height

                // Subtle radar grid
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: h * 0.5))
                grid.addLine(to: CGPoint(x: w, y: h * 0.5))
                grid.move(to: CGPoint(x: w * 0.5, y: 0))
                grid.addLine(to: CGPoint(x: w * 0.5, y: h))
                context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 0.7)

                // 64-bin FFT spectral floor
                let bars = model.spectrumBars
                let count = max(1, bars.count)
                let spacing: CGFloat = 1.5
                let barW = max(1.0, (w - CGFloat(count - 1) * spacing) / CGFloat(count))
                for i in 0..<bars.count {
                    let amp = CGFloat(min(max(bars[i], 0.02), 1.0))
                    let barH = max(2.0, amp * h * 0.78)
                    let rect = CGRect(x: CGFloat(i) * (barW + spacing), y: h - barH, width: barW, height: barH)
                    let hue = 0.52 + Double(i) * 0.004
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barW * 0.4),
                        with: .color(Color(hue: hue.truncatingRemainder(dividingBy: 1.0), saturation: 0.75, brightness: 0.95, opacity: 0.42 + Double(amp) * 0.45))
                    )
                }

                // 8-Voice MPE Pitch (X) / CC74 Timbre (Y) / Aftertouch Pressure (Radius) Constellation Nodes
                for point in model.voiceConstellation where point.isActive {
                    let continuousNote = Float(point.midiNote) + point.pitchBendSemitones
                    let normPitch = CGFloat(min(max((continuousNote - 36.0) / 60.0, 0.04), 0.96))
                    let normTimbre = CGFloat(min(max(0.5 - point.timbreSlideNormalized * 0.44, 0.06), 0.94))
                    let px = normPitch * w
                    let py = normTimbre * h
                    let radius = CGFloat(5.0 + point.pressureNormalized * 10.0 + point.envelopeAmplitude * 5.0)
                    let voiceHue = Double(point.voiceIndex) / 8.0

                    let haloRect = CGRect(x: px - radius * 1.7, y: py - radius * 1.7, width: radius * 3.4, height: radius * 3.4)
                    context.fill(
                        Path(ellipseIn: haloRect),
                        with: .color(Color(hue: voiceHue, saturation: 0.78, brightness: 1.0, opacity: 0.25))
                    )

                    let coreRect = CGRect(x: px - radius * 0.5, y: py - radius * 0.5, width: radius, height: radius)
                    context.fill(
                        Path(ellipseIn: coreRect),
                        with: .color(Color(hue: voiceHue, saturation: 0.65, brightness: 1.0, opacity: 0.95))
                    )
                }
            }
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Interactive 24dB Cytomic TPT SVF Cutoff / Resonance XY Pad

    private var svfCutoffResonanceXYPad: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TPT SVF CUTOFF / Q")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(String(format: "%.0fHz · Q%.2f", model.filterCutoffHz, model.filterResonance))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }

            GeometryReader { geo in
                let size = geo.size
                let minLog = logf(80.0)
                let maxLog = logf(16_000.0)
                let clampedCut = min(max(model.filterCutoffHz, 80.0), 16_000.0)
                let normX = CGFloat((logf(clampedCut) - minLog) / (maxLog - minLog))
                let normY = CGFloat(1.0 - (model.filterResonance - 0.05) / 0.89)
                let puck = CGPoint(
                    x: min(max(normX * size.width, 10), max(10, size.width - 10)),
                    y: min(max(normY * size.height, 10), max(10, size.height - 10))
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.36))

                    Path { p in
                        p.move(to: CGPoint(x: puck.x, y: 0))
                        p.addLine(to: CGPoint(x: puck.x, y: size.height))
                        p.move(to: CGPoint(x: 0, y: puck.y))
                        p.addLine(to: CGPoint(x: size.width, y: puck.y))
                    }
                    .stroke(.cyan.opacity(0.32), lineWidth: 0.8)

                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 18, height: 18)
                        .shadow(color: .cyan.opacity(0.8), radius: 8)
                        .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
                        .position(puck)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let rx = Float(min(max(drag.location.x / max(size.width, 1), 0), 1))
                            let ry = Float(min(max(drag.location.y / max(size.height, 1), 0), 1))
                            let cutoff = expf(minLog + rx * (maxLog - minLog))
                            let resonance = 0.05 + (1.0 - ry) * 0.89
                            model.setParameter(.filterCutoffHz, value: cutoff)
                            model.setParameter(.filterResonance, value: resonance)
                        }
                )
            }
        }
        .padding(10)
        .frame(width: 158)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Interactive Binaural / KEMAR HRTF Spatial Puck

    private var binauralHRTFSpatialPuck: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("KEMAR HRTF PUCK")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(String(format: "%+.0f° · %.1fm", model.hrtfAzimuthDeg, model.hrtfDistanceMeters))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.purple)
            }

            GeometryReader { geo in
                let size = geo.size
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                let maxRadius = max(12.0, min(size.width, size.height) * 0.44)
                let normDist = CGFloat(min(max((model.hrtfDistanceMeters - 0.15) / 9.85, 0.08), 1.0))
                let azRad = CGFloat(model.hrtfAzimuthDeg) * (.pi / 180.0)
                let puck = CGPoint(
                    x: center.x + sin(azRad) * normDist * maxRadius,
                    y: center.y - cos(azRad) * normDist * maxRadius
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.36))

                    Circle()
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
                        .frame(width: maxRadius * 2.0, height: maxRadius * 2.0)

                    Circle()
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
                        .frame(width: maxRadius, height: maxRadius)

                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .position(center)

                    Circle()
                        .fill(Color.purple)
                        .frame(width: 16, height: 16)
                        .shadow(color: .purple.opacity(0.85), radius: 8)
                        .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
                        .position(puck)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let dx = drag.location.x - center.x
                            let dy = center.y - drag.location.y
                            let distRatio = Float(min(max(hypot(dx, dy) / maxRadius, 0.02), 1.0))
                            let azimuth = Float(atan2(dx, dy) * (180.0 / .pi))
                            let meters = 0.15 + distRatio * 9.85
                            model.setParameter(.hrtfAzimuthDeg, value: azimuth)
                            model.setParameter(.hrtfDistanceMeters, value: meters)
                        }
                )
            }
        }
        .padding(10)
        .frame(width: 152)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Bottom Parameter Macro Strip

    private var macroStripBar: some View {
        HStack(spacing: 12) {
            compactSlider(
                label: "Beat",
                text: String(format: "%.1fHz", model.binauralBeatHz),
                value: Binding(
                    get: { Double(model.binauralBeatHz) },
                    set: { model.setParameter(.binauralBeatHz, value: Float($0)) }
                ),
                range: 0.5...48.0
            )
            compactSlider(
                label: "FM β",
                text: String(format: "%.2f", model.fmModulationIndex),
                value: Binding(
                    get: { Double(model.fmModulationIndex) },
                    set: { model.setParameter(.fmModulationIndex, value: Float($0)) }
                ),
                range: 0.0...8.0
            )
            compactSlider(
                label: "FDN Wet",
                text: "\(Int((model.reverbWetMix * 100).rounded()))%",
                value: Binding(
                    get: { Double(model.reverbWetMix) },
                    set: { model.setParameter(.reverbWetMix, value: Float($0)) }
                ),
                range: 0.0...1.0
            )
            compactSlider(
                label: "Gain",
                text: "\(Int((model.masterGain * 100).rounded()))%",
                value: Binding(
                    get: { Double(model.masterGain) },
                    set: { model.setParameter(.masterGain, value: Float($0)) }
                ),
                range: 0.0...1.0
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func compactSlider(
        label: String,
        text: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(text)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
            Slider(value: value, in: range)
                .tint(.cyan)
        }
    }
}

// MARK: - 3. Principal AUViewController & Nonisolated AUAudioUnitFactory

public final class AetherAUv3ViewController: AUViewController, AUAudioUnitFactory {
    nonisolated private let audioUnitSlot = Mutex<AetherSynthAudioUnit?>(nil)
    private let viewModel = AetherAUv3ViewModel()

    #if canImport(UIKit)
    private var hostingController: UIHostingController<AetherAUv3PluginView>?
    #elseif canImport(AppKit)
    private var hostingController: NSHostingController<AetherAUv3PluginView>?
    #endif

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 720, height: 380)
        embedHostedSwiftUIView()

        if let existingUnit = audioUnitSlot.withLock({ $0 }) {
            viewModel.attach(audioUnit: existingUnit)
        }
    }

    private func embedHostedSwiftUIView() {
        let rootView = AetherAUv3PluginView(model: viewModel)

        #if canImport(UIKit)
        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        self.hostingController = host
        #elseif canImport(AppKit)
        let host = NSHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.hostingController = host
        #endif
    }

    /// Invoked by CoreAudio / DAW host (potentially off the main thread) to instantiate the AUv3 DSP unit.
    nonisolated public func createAudioUnit(
        with componentDescription: AudioComponentDescription
    ) throws -> AUAudioUnit {
        if let existing = audioUnitSlot.withLock({ $0 }) {
            return existing
        }

        let unit = try AetherSynthAudioUnit(componentDescription: componentDescription, options: [])
        audioUnitSlot.withLock { $0 = unit }

        Task { @MainActor [weak self] in
            self?.viewModel.attach(audioUnit: unit)
        }
        return unit
    }
}
#endif
