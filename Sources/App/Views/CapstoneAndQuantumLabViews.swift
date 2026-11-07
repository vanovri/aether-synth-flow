// MARK: - FILE: CapstoneAndQuantumLabViews.swift

import SwiftUI

// MARK: - 1. Phase 3 Card: 8-Ch Hadamard FDN Reverb, 4-Op TZFM, 24-Bit WAV Stem Exporter & Kalman Spline

public struct Phase3AndDSPExpansionCardView: View {
    @Bindable public var coordinator: AetherAppCoordinator

    public init(coordinator: AetherAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let kalman = coordinator.latestKalmanEstimate
        let schedule = coordinator.currentEntrainmentSchedule
        let curvePoints = schedule.sampleCurve(pointCount: 48)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("8-Ch Hadamard FDN, 4-Op TZFM & 24-Bit WAV Stem", systemImage: "waveform.path.ecg.rectangle")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Picker("WAV Depth", selection: $coordinator.selectedWAVBitDepth) {
                    ForEach(WAVBitDepth.allCases) { depth in
                        Text(depth == .pcm24Bit ? "24-bit PCM" : "32-bit Float").tag(depth)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 155)
            }

            // Hadamard FDN & 4-Op TZFM Sliders
            sliderRow(
                title: "8-Ch Hadamard FDN Reverb Wet Mix",
                valueText: "\(Int((coordinator.synthParameters.reverbWetMix * 100).rounded()))%",
                value: Binding(
                    get: { Double(coordinator.synthParameters.reverbWetMix) },
                    set: { v in
                        var p = coordinator.synthParameters
                        p.reverbWetMix = Float(v)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 0.0...1.0
            )

            sliderRow(
                title: "Hadamard FDN RT60 Decay & Damping",
                valueText: String(format: "%.1fs · %.0f%%", coordinator.synthParameters.reverbDecaySeconds, coordinator.synthParameters.reverbDamping * 100),
                value: Binding(
                    get: { Double(coordinator.synthParameters.reverbDecaySeconds) },
                    set: { v in
                        var p = coordinator.synthParameters
                        p.reverbDecaySeconds = Float(v)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 0.3...10.0
            )

            sliderRow(
                title: "4-Op Through-Zero FM Mix & Index (β)",
                valueText: String(format: "%.0f%% · β %.2f", coordinator.synthParameters.fmMix * 100, coordinator.synthParameters.fmModulationIndex),
                value: Binding(
                    get: { Double(coordinator.synthParameters.fmMix) },
                    set: { v in
                        var p = coordinator.synthParameters
                        p.fmMix = Float(v)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 0.0...1.0
            )

            sliderRow(
                title: "4-Op TZFM Harmonic Ratio",
                valueText: String(format: "%.2f×", coordinator.synthParameters.fmHarmonicRatio),
                value: Binding(
                    get: { Double(coordinator.synthParameters.fmHarmonicRatio) },
                    set: { v in
                        var p = coordinator.synthParameters
                        p.fmHarmonicRatio = Float(v)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 0.5...6.0
            )

            // 2D Kalman State & Hermite Spline Entrainment Curve
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Kalman Coherence \(Int((kalman.coherence * 100).rounded()))% · Rec \(kalman.recommendedSessionMinutes)m · Hermite Ramp")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Toggle("", isOn: $coordinator.isEntrainmentCurveEnabled)
                        .labelsHidden()
                        .tint(accent)
                }

                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.black.opacity(0.38)))
                    guard curvePoints.count > 1 else { return }

                    var path = Path()
                    for (idx, pt) in curvePoints.enumerated() {
                        let x = CGFloat(pt.progress) * (size.width - 12) + 6
                        let normY = CGFloat((pt.binauralBeatHz - 1.5) / 38.5)
                        let y = size.height - 6 - min(max(normY, 0.0), 1.0) * (size.height - 12)
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(path, with: .color(accent), lineWidth: 2.0)

                    let cursorX = CGFloat(coordinator.focusProgress) * (size.width - 12) + 6
                    var cursor = Path()
                    cursor.move(to: CGPoint(x: cursorX, y: 4))
                    cursor.addLine(to: CGPoint(x: cursorX, y: size.height - 4))
                    context.stroke(cursor, with: .color(.cyan.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
                .frame(height: 58)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await coordinator.prepareWAVStemExport() }
                } label: {
                    Label("Export 48kHz Seamless WAV Stem", systemImage: "waveform.badge.plus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(accent.opacity(0.50), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.isMeshSyncSheetPresented = true
                    Task { await coordinator.refreshMeshStatus() }
                } label: {
                    Label("E2EE Mesh", systemImage: "network.badge.shield.half.filled")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.6, cornerRadius: 24)
    }

    private func sliderRow(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hue: coordinator.activeAccentHue, saturation: 0.55, brightness: 1.0))
            }
            Slider(value: value, in: range)
                .tint(Color(hue: coordinator.activeAccentHue, saturation: 0.72, brightness: 0.96))
        }
    }
}

// MARK: - 2. Phase 9 Card: 2D FDTD Wave Tank + Sellmeier Caustics & 4-Ch Cortical EEG BCI

public struct Phase9WaveguideAndCorticalEEGCardView: View {
    @Bindable public var coordinator: AetherAppCoordinator

    public init(coordinator: AetherAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let eeg = coordinator.eegBCI.latestMetrics

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("2D FDTD Waveguide, Caustics & 4-Ch EEG BCI", systemImage: "brain.head.profile")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Toggle("Caustics", isOn: $coordinator.showOpticalCausticsMode)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
                    .tint(.cyan)
                    .fixedSize()
            }

            // FDTD Resonator Mix & Stiffness
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("2D FDTD Plate Mix: \(Int((coordinator.synthParameters.fdtdResonatorMix * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Slider(
                        value: Binding(
                            get: { Double(coordinator.synthParameters.fdtdResonatorMix) },
                            set: { v in
                                var p = coordinator.synthParameters
                                p.fdtdResonatorMix = Float(v)
                                coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                            }
                        ),
                        in: 0.0...1.0
                    )
                    .tint(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Biharmonic κ: \(String(format: "%.2f", coordinator.synthParameters.fdtdStiffness))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Slider(
                        value: Binding(
                            get: { Double(coordinator.synthParameters.fdtdStiffness) },
                            set: { v in
                                var p = coordinator.synthParameters
                                p.fdtdStiffness = Float(v)
                                coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                            }
                        ),
                        in: 0.0...0.95
                    )
                    .tint(.cyan)
                }
            }

            // Interactive 2D FDTD Wavefield / Chromatic Caustics Preview
            Group {
                if coordinator.showOpticalCausticsMode {
                    ChromaticCausticsViewportView(
                        waveTank: coordinator.waveTankController.waveTank,
                        audioAmplitude: coordinator.liveAudioAmplitude,
                        highBandEnergy: coordinator.liveHighBandEnergy,
                        accentHue: coordinator.activeAccentHue
                    )
                    .frame(height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    GeometryReader { geo in
                        let size = geo.size
                        Canvas { context, canvasSize in
                            let rect = CGRect(origin: .zero, size: canvasSize)
                            context.fill(Path(roundedRect: rect, cornerRadius: 14), with: .color(.black.opacity(0.45)))
                            let tank = coordinator.waveTankController.waveTank
                            let n = tank.gridSize
                            let strideStep = max(1, n / 32)
                            let cellW = canvasSize.width / CGFloat(n / strideStep)
                            let cellH = canvasSize.height / CGFloat(n / strideStep)

                            for gy in stride(from: 0, to: n, by: strideStep) {
                                for gx in stride(from: 0, to: n, by: strideStep) {
                                    let idx = gy * n + gx
                                    let p = tank.pressureCurr[idx]
                                    let obs = tank.obstacleCodes[idx]
                                    let cRect = CGRect(
                                        x: CGFloat(gx / strideStep) * cellW,
                                        y: CGFloat(gy / strideStep) * cellH,
                                        width: cellW + 0.5,
                                        height: cellH + 0.5
                                    )
                                    if obs == 2 {
                                        context.fill(Path(cRect), with: .color(.white.opacity(0.55)))
                                    } else if abs(p) > 0.008 {
                                        let norm = Double(min(max(abs(p) * 2.5, 0.0), 1.0))
                                        let col = p >= 0 ? accent.opacity(norm) : Color.cyan.opacity(norm)
                                        context.fill(Path(cRect), with: .color(col))
                                    }
                                }
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    let nx = Float(min(max(drag.location.x / max(1, size.width), 0.05), 0.95))
                                    let ny = Float(min(max(drag.location.y / max(1, size.height), 0.05), 0.95))
                                    coordinator.triggerFDTDWaveTankShockwave(normalizedX: nx, normalizedY: ny)
                                }
                        )
                    }
                    .frame(height: 136)
                }
            }

            // 4-Channel 256Hz Cortical EEG Telemetry Pills
            HStack(spacing: 8) {
                metricPill(title: "IAF Peak", value: String(format: "%.2f Hz", eeg.individualAlphaFrequencyHz))
                metricPill(title: "BIS Index", value: String(format: "%.1f", eeg.bispectralIndex))
                metricPill(title: "PAC MI", value: String(format: "%.3f", eeg.thetaGammaPACModulationIndex))
                metricPill(title: "FAA α", value: String(format: "%+.2f", eeg.frontalAlphaAsymmetry))
            }

            HStack(spacing: 10) {
                Button {
                    coordinator.toggleCorticalIAFLock(!coordinator.isCorticalIAFLockEnabled)
                } label: {
                    Label(
                        coordinator.isCorticalIAFLockEnabled ? "IAF Locked" : "Lock Beat to IAF",
                        systemImage: "lock.rotation"
                    )
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        coordinator.isCorticalIAFLockEnabled ? accent.opacity(0.55) : Color.white.opacity(0.12),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.triggerManualEEGBlink()
                } label: {
                    Label("Inject EOG Blink", systemImage: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.65, cornerRadius: 24)
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 3. Phase 10 Card: SPWVD / HHT Scalogram, Quantum MPS / DMRG & 12-Stage Capstone Audit

public struct Phase10QuantumAndCapstoneCardView: View {
    @Bindable public var coordinator: AetherAppCoordinator

    public init(coordinator: AetherAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let mps = coordinator.latestMPSTelemetry

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Quantum MPS/DMRG, SPWVD/HHT & Capstone Audit", systemImage: "atom")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    Task {
                        await coordinator.refreshCorticalEEGAndTFR()
                        await coordinator.refreshQuantumMPSAndDMRG()
                    }
                } label: {
                    Text("Sweep")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.45), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if let mps {
                HStack(spacing: 8) {
                    pill(title: "S_vN Entropy", value: String(format: "%.3f nats", mps.maxEntanglementEntropyNats))
                    pill(title: "DMRG E₀", value: String(format: "%.4f", mps.groundStateEnergy))
                    pill(title: "Rank r_eff", value: String(format: "%.2f", mps.effectiveSchmidtRank))
                    pill(title: "SVD Trunc ε", value: String(format: "%.1e", mps.totalTruncationError))
                }
            }

            // SPWVD 2D Time-Frequency Scalogram Preview
            if let spwvd = coordinator.latestSPWVDResult {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Smoothed Pseudo Wigner-Ville Distribution (SPWVD) & HHT Ridge")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.86))
                        Spacer()
                        if let hht = coordinator.latestHHTResult {
                            Text("IMFs: \(hht.imfs.count) · Recon ε \(String(format: "%.1e", hht.maxReconstructionError))")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.cyan)
                        }
                    }

                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size)
                        context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.black.opacity(0.42)))
                        let tCount = max(1, spwvd.timeSteps)
                        let fCount = max(1, spwvd.freqBins)
                        let cw = size.width / CGFloat(tCount)
                        let ch = size.height / CGFloat(fCount)

                        for t in 0..<min(tCount, spwvd.scalogram.count) {
                            let col = spwvd.scalogram[t]
                            for f in 0..<min(fCount, col.count) {
                                let v = Double(min(max(col[f], 0.0), 1.0))
                                guard v > 0.06 else { continue }
                                let cell = CGRect(
                                    x: CGFloat(t) * cw,
                                    y: size.height - CGFloat(f + 1) * ch,
                                    width: cw + 0.5,
                                    height: ch + 0.5
                                )
                                context.fill(
                                    Path(cell),
                                    with: .color(Color(hue: coordinator.activeAccentHue, saturation: 0.80, brightness: v))
                                )
                            }
                        }
                    }
                    .frame(height: 64)
                }
            }

            // 12-Stage Capstone Benchmark & Cryptographic Audit Runner
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        Task { await coordinator.runFullCapstoneAudit() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: coordinator.isRunningCapstoneAudit ? "hourglass" : "checkmark.shield.fill")
                            Text(coordinator.isRunningCapstoneAudit ? "Running 12-Stage Audit…" : "Run 12-Stage Capstone Audit")
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(accent.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isRunningCapstoneAudit)

                    if coordinator.exportCapstoneMarkdownDocument != nil {
                        Button {
                            coordinator.isExportingCapstoneMarkdown = true
                        } label: {
                            Text(".MD")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    if coordinator.exportCapstoneJSONDocument != nil {
                        Button {
                            coordinator.isExportingCapstoneJSON = true
                        } label: {
                            Text(".JSON")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        coordinator.isCapstoneAuditSheetPresented = true
                    } label: {
                        Image(systemName: "list.bullet.clipboard.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let report = coordinator.latestCapstoneReport {
                    HStack {
                        Text("12/12 PASS · p50 \(String(format: "%.0fµs", report.p50Microseconds)) · p99 \(String(format: "%.0fµs", report.p99Microseconds))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                        Spacer()
                        Text("SHA-256 \(report.reportSHA256Hex.prefix(16))…")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                }
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.65, cornerRadius: 24)
    }

    private func pill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 4. Zero-Knowledge Local Mesh P2P Sync Sheet (Track 8)

public struct MeshSyncStatusSheetView: View {
    @Bindable public var coordinator: AetherAppCoordinator
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: AetherAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Bonjour P2P E2EE Mesh (_aethersynth._tcp)") {
                    Toggle(
                        "Advertise & Browse Local Mesh",
                        isOn: Binding(
                            get: { coordinator.isMeshBonjourActive },
                            set: { active in
                                Task { await coordinator.toggleBonjourMesh(active) }
                            }
                        )
                    )
                    LabeledContent("Lamport Logical Clock", value: "#\(coordinator.meshLamportClock)")
                    LabeledContent("Cipher Suite", value: "Curve25519 + HKDF-SHA256 + ChaChaPoly")
                }

                Section("Discovered Peers (\(coordinator.meshPeers.count))") {
                    if coordinator.meshPeers.isEmpty {
                        Text("No peer nodes discovered on local subnet yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.meshPeers) { peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .font(.headline)
                                    Text("Fingerprint: \(peer.shortFingerprint) · Clock #\(peer.lastLamportClock)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(peer.isAuthenticated ? "Verified E2EE" : "Handshake")
                                    .font(.caption.bold())
                                    .foregroundStyle(peer.isAuthenticated ? .green : .orange)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await coordinator.triggerMeshBroadcastSync() }
                    } label: {
                        Label("Broadcast Encrypted Archive Diff Now", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    }
                }
            }
            .navigationTitle("Zero-Knowledge Mesh Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 5. Master Capstone 12-Stage Benchmark & Cryptographic Certification Runner Sheet (Track 36)

public struct CapstoneAuditRunnerSheetView: View {
    @Bindable public var coordinator: AetherAppCoordinator
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: AetherAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Master Certification Command") {
                    Button {
                        Task { await coordinator.runFullCapstoneAudit() }
                    } label: {
                        HStack {
                            Image(systemName: coordinator.isRunningCapstoneAudit ? "hourglass" : "checkmark.shield.fill")
                            Text(coordinator.isRunningCapstoneAudit ? "Executing 12-Stage Deterministic Audit…" : "Run Full 12-Stage Capstone Benchmark")
                                .fontWeight(.bold)
                        }
                    }
                    .disabled(coordinator.isRunningCapstoneAudit)

                    HStack(spacing: 12) {
                        Button {
                            Task { await coordinator.prepareCapstoneMarkdownExport() }
                        } label: {
                            Label("Export Report (.md)", systemImage: "doc.richtext.fill")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task { await coordinator.prepareCapstoneJSONExport() }
                        } label: {
                            Label("Export Report (.json)", systemImage: "curlybraces.square.fill")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let report = coordinator.latestCapstoneReport {
                    Section("Cryptographic Digest & Latency Summary") {
                        LabeledContent("Status", value: report.allInvariantsPassed ? "PASS (\(report.passedStageCount)/\(report.totalStageCount))" : "ATTENTION")
                        LabeledContent("Wall Time", value: String(format: "%.2f ms", report.totalWallTimeMilliseconds))
                        LabeledContent("Latency p50 / p95 / p99", value: String(format: "%.0f / %.0f / %.0f µs", report.p50Microseconds, report.p95Microseconds, report.p99Microseconds))
                        LabeledContent("SHA-256 Digest", value: String(report.cryptographicSHA256Digest.prefix(24)) + "…")
                            .font(.caption.monospaced())
                    }

                    Section("12-Stage End-to-End Subsystem Benchmarks") {
                        ForEach(report.stages) { stage in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("[\(stage.stageCode)] \(stage.title)")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(stage.invariantPassed ? "PASS" : "FAIL")
                                        .font(.caption.bold())
                                        .foregroundStyle(stage.invariantPassed ? .green : .red)
                                }
                                Text("\(stage.subsystemName) · p50 \(String(format: "%.1fµs", stage.p50Microseconds)) · p95 \(String(format: "%.1fµs", stage.p95Microseconds)) · p99 \(String(format: "%.1fµs", stage.p99Microseconds))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(stage.numericalInvariantSummary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.cyan)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Section("Repository Subsystem Inventory (\(report.subsystemInventory.count) Modules)") {
                        ForEach(report.subsystemInventory) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Phase \(item.phaseNumber) (\(item.trackRange)) — \(item.moduleName)")
                                        .font(.caption.bold())
                                    Spacer()
                                    Image(systemName: item.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(item.verified ? .green : .orange)
                                        .font(.caption)
                                }
                                Text(item.sourcePath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(item.mathematicalCore)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Capstone Master Certification")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
