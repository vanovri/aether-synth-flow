// MARK: - FILE: WignerVilleHilbertHuangAnalyzer.swift

import Foundation

// MARK: - 1. Smoothed Pseudo Wigner-Ville Distribution (SPWVD) Result & Analyzer

public struct SPWVDResult: Sendable, Equatable {
    public let timeSteps: Int
    public let freqBins: Int
    public let tfrMatrix: [[Float]]
    public let instantaneousFreqRidgeHz: [Float]
    public let renyiEntropyBits: Float
    public let corticalSpindlePowerRatio: Float

    public init(
        timeSteps: Int,
        freqBins: Int,
        tfrMatrix: [[Float]],
        instantaneousFreqRidgeHz: [Float],
        renyiEntropyBits: Float,
        corticalSpindlePowerRatio: Float = 0.0
    ) {
        self.timeSteps = timeSteps
        self.freqBins = freqBins
        self.tfrMatrix = tfrMatrix
        self.instantaneousFreqRidgeHz = instantaneousFreqRidgeHz
        self.renyiEntropyBits = renyiEntropyBits
        self.corticalSpindlePowerRatio = corticalSpindlePowerRatio.isFinite ? min(max(corticalSpindlePowerRatio, 0.0), 1.0) : 0.0
    }
}

public enum SPWVDAnalyzer: Sendable {
    public struct ComplexSample: Sendable, Equatable {
        public var real: Double
        public var imag: Double

        public init(real: Double, imag: Double) {
            self.real = real
            self.imag = imag
        }

        @inline(__always)
        public var conjugate: ComplexSample {
            ComplexSample(real: real, imag: -imag)
        }

        @inline(__always)
        public static func + (lhs: ComplexSample, rhs: ComplexSample) -> ComplexSample {
            ComplexSample(real: lhs.real + rhs.real, imag: lhs.imag + rhs.imag)
        }

        @inline(__always)
        public static func - (lhs: ComplexSample, rhs: ComplexSample) -> ComplexSample {
            ComplexSample(real: lhs.real - rhs.real, imag: lhs.imag - rhs.imag)
        }

        @inline(__always)
        public static func * (lhs: ComplexSample, rhs: ComplexSample) -> ComplexSample {
            ComplexSample(
                real: lhs.real * rhs.real - lhs.imag * rhs.imag,
                imag: lhs.real * rhs.imag + lhs.imag * rhs.real
            )
        }
    }

    /// Computes the discrete analytic signal `z[n] = x[n] + j * Hilbert(x[n])` via complex DFT / Radix-2 FFT.
    public static func computeAnalyticSignal(_ signal: [Float]) -> [ComplexSample] {
        let n = signal.count
        guard n > 0 else { return [] }
        guard n >= 2 else {
            return [ComplexSample(real: Double(signal[0]), imag: 0.0)]
        }

        let x = signal.map { $0.isFinite ? Double($0) : 0.0 }

        // Power-of-two fast path via iterative Cooley-Tukey Radix-2 FFT; exact DFT fallback otherwise
        if (n & (n - 1)) == 0 {
            var spectrum = x.map { ComplexSample(real: $0, imag: 0.0) }
            radix2FFT(&spectrum, inverse: false)
            applyHilbertFrequencyMask(&spectrum)
            radix2FFT(&spectrum, inverse: true)
            return spectrum
        } else {
            var spectrum = [ComplexSample](repeating: ComplexSample(real: 0.0, imag: 0.0), count: n)
            let twoPiOverN = 2.0 * Double.pi / Double(n)
            for k in 0..<n {
                var re = 0.0
                var im = 0.0
                for m in 0..<n {
                    let angle = twoPiOverN * Double(k * m)
                    re += x[m] * cos(angle)
                    im -= x[m] * sin(angle)
                }
                spectrum[k] = ComplexSample(real: re, imag: im)
            }

            applyHilbertFrequencyMask(&spectrum)

            var analytic = [ComplexSample](repeating: ComplexSample(real: 0.0, imag: 0.0), count: n)
            let invN = 1.0 / Double(n)
            for m in 0..<n {
                var re = 0.0
                var im = 0.0
                for k in 0..<n {
                    let angle = twoPiOverN * Double(k * m)
                    let c = cos(angle)
                    let s = sin(angle)
                    re += spectrum[k].real * c - spectrum[k].imag * s
                    im += spectrum[k].real * s + spectrum[k].imag * c
                }
                analytic[m] = ComplexSample(real: re * invN, imag: im * invN)
            }
            return analytic
        }
    }

    /// Evaluates the Smoothed Pseudo Wigner-Ville Distribution `W_z[n, k]` with Gaussian time-smoothing
    /// and Hann lag-windowing, extracts the instantaneous frequency ridge in Hz, and computes Order-3 Rényi entropy.
    public static func analyze(
        signal: [Float],
        sampleRate: Double = 256.0,
        freqBins: Int = 64,
        timeSigmaSamples: Double = 2.0,
        maxLagSamples: Int? = nil
    ) -> SPWVDResult {
        let n = signal.count
        let bins = max(8, freqBins)
        let fs = max(1.0, sampleRate)

        guard n >= 4 else {
            let emptyMatrix = [[Float]](repeating: [Float](repeating: 0.0, count: bins), count: max(0, n))
            return SPWVDResult(
                timeSteps: n,
                freqBins: bins,
                tfrMatrix: emptyMatrix,
                instantaneousFreqRidgeHz: [Float](repeating: 0.0, count: max(0, n)),
                renyiEntropyBits: 0.0
            )
        }

        // Remove DC mean prior to analytic projection to prevent 0 Hz cross-terms
        let meanVal = signal.reduce(Float(0.0), +) / Float(n)
        let centered = signal.map { ($0.isFinite ? $0 : 0.0) - meanVal }
        let z = computeAnalyticSignal(centered)

        // Normalized Gaussian time-smoothing kernel g[u] for u in -U...U
        let sigma = max(0.35, timeSigmaSamples)
        let halfTimeWin = min(max(1, Int(ceil(2.5 * sigma))), max(1, n / 4))
        var gKernel = [Double](repeating: 0.0, count: 2 * halfTimeWin + 1)
        var gSum = 0.0
        for idx in 0..<gKernel.count {
            let u = Double(idx - halfTimeWin)
            let w = exp(-0.5 * (u * u) / (sigma * sigma))
            gKernel[idx] = w
            gSum += w
        }
        for idx in 0..<gKernel.count {
            gKernel[idx] /= max(1e-12, gSum)
        }

        // Symmetric Hann lag window h[tau] for tau in 0...L
        let defaultLag = min(max(4, n / 4), bins - 1)
        let maxLag = min(max(2, maxLagSamples ?? defaultLag), max(2, n / 2 - 1))
        let hLag = (0...maxLag).map { tau -> Double in
            0.5 * (1.0 + cos(Double.pi * Double(tau) / Double(maxLag + 1)))
        }

        // Precompute cosine/sine WVD Fourier basis over [0, fs/2):
        // Since bilinear lag product z[n+tau]*z*[n-tau] oscillates at 2*f*tau,
        // mapping bin k -> f_k = k * fs / (2 * bins) yields exp(-j * 2 * pi * k * tau / bins).
        let twoPiOverBins = 2.0 * Double.pi / Double(bins)
        var cosTable = [[Double]](repeating: [Double](repeating: 0.0, count: maxLag + 1), count: bins)
        var sinTable = [[Double]](repeating: [Double](repeating: 0.0, count: maxLag + 1), count: bins)
        for k in 0..<bins {
            for tau in 0...maxLag {
                let angle = twoPiOverBins * Double(k * tau)
                cosTable[k][tau] = cos(angle)
                sinTable[k][tau] = sin(angle)
            }
        }

        var tfrMatrix = [[Float]](repeating: [Float](repeating: 0.0, count: bins), count: n)
        var ridgeHz = [Float](repeating: 0.0, count: n)

        var sumPositiveP = 0.0
        var sumPositiveP3 = 0.0
        var spindleBandEnergy = 0.0

        for timeIdx in 0..<n {
            let localMaxLag = min(maxLag, min(timeIdx, n - 1 - timeIdx))

            // Evaluate time-smoothed Hermitian autocorrelation R_smooth[timeIdx, tau] for tau >= 0
            var rSmoothRe = [Double](repeating: 0.0, count: localMaxLag + 1)
            var rSmoothIm = [Double](repeating: 0.0, count: localMaxLag + 1)

            for tau in 0...localMaxLag {
                var accRe = 0.0
                var accIm = 0.0
                var weightNorm = 0.0

                for gIdx in 0..<gKernel.count {
                    let u = gIdx - halfTimeWin
                    let m = timeIdx - u
                    let iPlus = m + tau
                    let iMinus = m - tau
                    if iPlus >= 0 && iPlus < n && iMinus >= 0 && iMinus < n {
                        let gw = gKernel[gIdx]
                        let prod = z[iPlus] * z[iMinus].conjugate
                        accRe += gw * prod.real
                        accIm += gw * prod.imag
                        weightNorm += gw
                    }
                }

                if weightNorm > 1e-12 {
                    let scale = hLag[tau] / weightNorm
                    rSmoothRe[tau] = accRe * scale
                    rSmoothIm[tau] = accIm * scale
                }
            }

            // Real-valued Hermitian lag transform:
            // W_z[n, k] = R[n, 0] + 2 * sum_{tau=1..L} Re(R[n, tau] * exp(-j * 2*pi*k*tau / bins))
            var peakBin = 0
            var peakVal = -Double.greatestFiniteMagnitude
            var slice = [Double](repeating: 0.0, count: bins)

            for k in 0..<bins {
                var val = rSmoothRe[0]
                if localMaxLag >= 1 {
                    for tau in 1...localMaxLag {
                        val += 2.0 * (rSmoothRe[tau] * cosTable[k][tau] + rSmoothIm[tau] * sinTable[k][tau])
                    }
                }
                slice[k] = val
                tfrMatrix[timeIdx][k] = Float(val)

                if val > peakVal {
                    peakVal = val
                    peakBin = k
                }

                let posP = max(0.0, val)
                sumPositiveP += posP
                sumPositiveP3 += posP * posP * posP

                let binFreqHz = (Double(k) / Double(2 * bins)) * fs
                if binFreqHz >= 11.0 && binFreqHz <= 16.0 {
                    spindleBandEnergy += posP
                }
            }

            // Sub-bin parabolic ridge refinement
            var refinedBin = Double(peakBin)
            if peakBin > 0 && peakBin + 1 < bins {
                let yL = slice[peakBin - 1]
                let yC = slice[peakBin]
                let yR = slice[peakBin + 1]
                let denom = yL - 2.0 * yC + yR
                if abs(denom) > 1e-12 && yC >= yL && yC >= yR {
                    let delta = min(max(0.5 * (yL - yR) / denom, -0.5), 0.5)
                    refinedBin += delta
                }
            }
            let freqHz = (refinedBin / Double(2 * bins)) * fs
            ridgeHz[timeIdx] = Float(min(max(freqHz, 0.0), 0.5 * fs))
        }

        // Order-3 Rényi Entropy: R_3 = -0.5 * log2( sum(P^3) / (sum(P))^3 )
        let renyiBits: Float
        if sumPositiveP > 1e-15 && sumPositiveP3 > 1e-30 {
            let denom = sumPositiveP * sumPositiveP * sumPositiveP
            let ratio = min(max(sumPositiveP3 / denom, 1e-30), 1.0)
            renyiBits = Float(max(0.0, -0.5 * log2(ratio)))
        } else {
            renyiBits = 0.0
        }

        let spindleRatio = sumPositiveP > 1e-15
            ? Float(min(max(spindleBandEnergy / sumPositiveP, 0.0), 1.0))
            : 0.0

        return SPWVDResult(
            timeSteps: n,
            freqBins: bins,
            tfrMatrix: tfrMatrix,
            instantaneousFreqRidgeHz: ridgeHz,
            renyiEntropyBits: renyiBits,
            corticalSpindlePowerRatio: spindleRatio
        )
    }

    private static func applyHilbertFrequencyMask(_ spectrum: inout [ComplexSample]) {
        let n = spectrum.count
        guard n >= 2 else { return }
        if n % 2 == 0 {
            let half = n / 2
            for k in 1..<half {
                spectrum[k].real *= 2.0
                spectrum[k].imag *= 2.0
            }
            for k in (half + 1)..<n {
                spectrum[k] = ComplexSample(real: 0.0, imag: 0.0)
            }
        } else {
            let lastPos = (n - 1) / 2
            for k in 1...lastPos {
                spectrum[k].real *= 2.0
                spectrum[k].imag *= 2.0
            }
            for k in (lastPos + 1)..<n {
                spectrum[k] = ComplexSample(real: 0.0, imag: 0.0)
            }
        }
    }

    private static func radix2FFT(_ buffer: inout [ComplexSample], inverse: Bool) {
        let n = buffer.count
        guard n >= 2 && (n & (n - 1)) == 0 else { return }

        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                buffer.swapAt(i, j)
            }
        }

        var len = 2
        let sign = inverse ? 1.0 : -1.0
        while len <= n {
            let half = len >> 1
            let angle = sign * 2.0 * Double.pi / Double(len)
            let wStep = ComplexSample(real: cos(angle), imag: sin(angle))
            for start in stride(from: 0, to: n, by: len) {
                var w = ComplexSample(real: 1.0, imag: 0.0)
                for k in 0..<half {
                    let u = buffer[start + k]
                    let v = buffer[start + k + half] * w
                    buffer[start + k] = u + v
                    buffer[start + k + half] = u - v
                    w = w * wStep
                }
            }
            len <<= 1
        }

        if inverse {
            let invN = 1.0 / Double(n)
            for idx in 0..<n {
                buffer[idx].real *= invN
                buffer[idx].imag *= invN
            }
        }
    }
}

// MARK: - 2. Hilbert-Huang Empirical Mode Decomposition (Thomas O(N) Natural Cubic Spline Sifter)

public struct IMFAnalytics: Sendable, Equatable {
    public let imfIndex: Int
    public let samples: [Float]
    public let instantaneousPhaseRad: [Float]
    public let instantaneousFrequencyHz: [Float]
    public let instantaneousEnergy: [Float]
    public let meanFrequencyHz: Float
    public let totalEnergy: Float

    public init(
        imfIndex: Int,
        samples: [Float],
        instantaneousPhaseRad: [Float],
        instantaneousFrequencyHz: [Float],
        instantaneousEnergy: [Float],
        meanFrequencyHz: Float,
        totalEnergy: Float
    ) {
        self.imfIndex = imfIndex
        self.samples = samples
        self.instantaneousPhaseRad = instantaneousPhaseRad
        self.instantaneousFrequencyHz = instantaneousFrequencyHz
        self.instantaneousEnergy = instantaneousEnergy
        self.meanFrequencyHz = meanFrequencyHz
        self.totalEnergy = totalEnergy
    }
}

public struct HilbertHuangResult: Sendable, Equatable {
    public let imfs: [[Float]]
    public let residual: [Float]
    public let maxReconstructionError: Float
    public let imfAnalytics: [IMFAnalytics]
    public let orthogonalityIndex: Float

    public init(
        imfs: [[Float]],
        residual: [Float],
        maxReconstructionError: Float,
        imfAnalytics: [IMFAnalytics] = [],
        orthogonalityIndex: Float = 0.0
    ) {
        self.imfs = imfs
        self.residual = residual
        self.maxReconstructionError = maxReconstructionError
        self.imfAnalytics = imfAnalytics
        self.orthogonalityIndex = orthogonalityIndex
    }
}

public enum HilbertHuangSifter: Sendable {
    /// Decomposes an arbitrary non-stationary signal into Intrinsic Mode Functions (`imfs`) and a monotonic/slow
    /// `residual` via Empirical Mode Decomposition with Thomas-algorithm O(N) natural cubic spline envelopes.
    /// Guarantees `sum(imfs) + residual == signal` within `< 1e-5` floating-point precision, and evaluates
    /// per-IMF Hilbert instantaneous phase `phi_k[n]`, unwrapped frequency `omega_k[n]`, and energy `A_k^2[n]`.
    public static func sift(
        signal: [Float],
        sampleRate: Double = 256.0,
        maxIMFs: Int = 4,
        maxSiftIterations: Int = 12,
        cauchyConvergenceThreshold: Double = 0.05
    ) -> HilbertHuangResult {
        let n = signal.count
        let sanitized = signal.map { $0.isFinite ? $0 : 0.0 }
        guard n >= 4, maxIMFs > 0 else {
            return HilbertHuangResult(
                imfs: [],
                residual: sanitized,
                maxReconstructionError: 0.0,
                imfAnalytics: [],
                orthogonalityIndex: 0.0
            )
        }

        let siftLimit = max(1, maxSiftIterations)
        let cauchyTol = min(max(1e-5, cauchyConvergenceThreshold), 0.05)
        var runningResidual = sanitized.map(Double.init)
        var extractedIMFs: [[Float]] = []
        extractedIMFs.reserveCapacity(maxIMFs)

        for _ in 0..<maxIMFs {
            let initialExtrema = detectLocalExtrema(in: runningResidual)
            // Stop sifting once residual has fewer than 2 interior maxima or minima (monotonic/trend)
            if initialExtrema.maxIndices.count < 2 || initialExtrema.minIndices.count < 2 {
                break
            }

            var protoIMF = runningResidual
            for _ in 0..<siftLimit {
                let extrema = detectLocalExtrema(in: protoIMF)
                if extrema.maxIndices.count < 1 || extrema.minIndices.count < 1 {
                    break
                }

                let upperKnots = buildBoundaryAnchoredKnots(
                    signal: protoIMF,
                    extremaIndices: extrema.maxIndices,
                    isUpper: true
                )
                let lowerKnots = buildBoundaryAnchoredKnots(
                    signal: protoIMF,
                    extremaIndices: extrema.minIndices,
                    isUpper: false
                )

                let upperEnv = evaluateNaturalCubicSpline(
                    knotX: upperKnots.xs,
                    knotY: upperKnots.ys,
                    sampleCount: n
                )
                let lowerEnv = evaluateNaturalCubicSpline(
                    knotX: lowerKnots.xs,
                    knotY: lowerKnots.ys,
                    sampleCount: n
                )

                var nextProto = [Double](repeating: 0.0, count: n)
                var diffSq = 0.0
                var prevSq = 0.0

                for i in 0..<n {
                    let meanEnv = 0.5 * (upperEnv[i] + lowerEnv[i])
                    let updated = protoIMF[i] - meanEnv
                    let d = protoIMF[i] - updated
                    diffSq += d * d
                    prevSq += protoIMF[i] * protoIMF[i]
                    nextProto[i] = updated
                }

                protoIMF = nextProto
                let cauchySD = diffSq / max(1e-15, prevSq)
                if cauchySD < min(0.02, cauchyTol) && satisfiesIMFZeroCrossingCondition(protoIMF) {
                    break
                }
            }

            let imfFloat = protoIMF.map(Float.init)
            extractedIMFs.append(imfFloat)

            // Subtract exact Float32 IMF representation so Float32 sum(imfs) + residual matches signal to ~1e-7
            for i in 0..<n {
                runningResidual[i] -= Double(imfFloat[i])
            }
        }

        let residualFloat = runningResidual.map(Float.init)
        var maxError: Float = 0.0
        for i in 0..<n {
            var sumSample = residualFloat[i]
            for imf in extractedIMFs {
                sumSample += imf[i]
            }
            let err = abs(sumSample - sanitized[i])
            if err > maxError {
                maxError = err
            }
        }

        let fs = max(1.0, sampleRate)
        let analytics = extractedIMFs.enumerated().map { idx, imf in
            computeIMFAnalytics(imfIndex: idx, imf: imf, sampleRate: fs)
        }
        let orthoIdx = computeOrthogonalityIndex(imfs: extractedIMFs, signal: sanitized)

        return HilbertHuangResult(
            imfs: extractedIMFs,
            residual: residualFloat,
            maxReconstructionError: maxError,
            imfAnalytics: analytics,
            orthogonalityIndex: orthoIdx
        )
    }

    private static func computeIMFAnalytics(
        imfIndex: Int,
        imf: [Float],
        sampleRate: Double
    ) -> IMFAnalytics {
        let n = imf.count
        let analytic = SPWVDAnalyzer.computeAnalyticSignal(imf)
        var phases = [Float](repeating: 0.0, count: n)
        var freqs = [Float](repeating: 0.0, count: n)
        var energies = [Float](repeating: 0.0, count: n)

        let scaleHz = sampleRate / (2.0 * Double.pi)
        let nyquist = 0.5 * sampleRate
        var prevPhase = 0.0
        var weightedFreqSum = 0.0
        var totalEnergy = 0.0

        for i in 0..<n {
            let z = analytic[i]
            let phase = atan2(z.imag, z.real)
            let energy = z.real * z.real + z.imag * z.imag
            phases[i] = Float(phase)
            energies[i] = Float(energy)
            totalEnergy += energy

            if i > 0 {
                let dPhi = atan2(sin(phase - prevPhase), cos(phase - prevPhase))
                let instHz = min(max(abs(dPhi * scaleHz), 0.0), nyquist)
                freqs[i] = Float(instHz)
                weightedFreqSum += instHz * energy
            }
            prevPhase = phase
        }
        if n > 1 {
            freqs[0] = freqs[1]
            weightedFreqSum += Double(freqs[0]) * Double(energies[0])
        }

        let meanFreq = totalEnergy > 1e-12 ? Float(weightedFreqSum / totalEnergy) : 0.0
        return IMFAnalytics(
            imfIndex: imfIndex,
            samples: imf,
            instantaneousPhaseRad: phases,
            instantaneousFrequencyHz: freqs,
            instantaneousEnergy: energies,
            meanFrequencyHz: meanFreq,
            totalEnergy: Float(totalEnergy)
        )
    }

    private static func computeOrthogonalityIndex(imfs: [[Float]], signal: [Float]) -> Float {
        guard imfs.count >= 2 else { return 0.0 }
        let n = signal.count
        var sigEnergy = 0.0
        for s in signal {
            sigEnergy += Double(s) * Double(s)
        }
        guard sigEnergy > 1e-12 else { return 0.0 }

        var crossSum = 0.0
        for j in 0..<imfs.count {
            for k in (j + 1)..<imfs.count {
                var dot = 0.0
                for i in 0..<n {
                    dot += Double(imfs[j][i]) * Double(imfs[k][i])
                }
                crossSum += abs(dot)
            }
        }
        return Float(crossSum / sigEnergy)
    }

    /// Exact O(N) Thomas-algorithm tridiagonal solver & evaluator for natural cubic spline (`S''(x_0) = S''(x_{K-1}) = 0`).
    public static func evaluateNaturalCubicSpline(
        knotX: [Double],
        knotY: [Double],
        sampleCount: Int
    ) -> [Double] {
        guard sampleCount > 0 else { return [] }
        let kCount = min(knotX.count, knotY.count)
        guard kCount >= 2 else {
            let fill = knotY.first ?? 0.0
            return [Double](repeating: fill, count: sampleCount)
        }

        if kCount == 2 {
            let x0 = knotX[0]
            let x1 = knotX[1]
            let span = max(1e-9, x1 - x0)
            let slope = (knotY[1] - knotY[0]) / span
            return (0..<sampleCount).map { i in
                knotY[0] + slope * (Double(i) - x0)
            }
        }

        let segCount = kCount - 1
        var h = [Double](repeating: 1.0, count: segCount)
        for i in 0..<segCount {
            h[i] = max(1e-9, knotX[i + 1] - knotX[i])
        }

        // Natural spline boundary conditions: second derivatives m[0] = 0, m[kCount - 1] = 0.
        // Interior unknowns m[1 ... kCount - 2] (count = mLen = kCount - 2):
        let mLen = kCount - 2
        var secondDeriv = [Double](repeating: 0.0, count: kCount)

        if mLen == 1 {
            let diag = 2.0 * (h[0] + h[1])
            let rhs = 6.0 * ((knotY[2] - knotY[1]) / h[1] - (knotY[1] - knotY[0]) / h[0])
            secondDeriv[1] = rhs / max(1e-12, diag)
        } else {
            var subDiag = [Double](repeating: 0.0, count: mLen)
            var mainDiag = [Double](repeating: 0.0, count: mLen)
            var supDiag = [Double](repeating: 0.0, count: mLen)
            var rhs = [Double](repeating: 0.0, count: mLen)

            for idx in 0..<mLen {
                let knotIdx = idx + 1
                let hPrev = h[knotIdx - 1]
                let hNext = h[knotIdx]
                subDiag[idx] = idx > 0 ? hPrev : 0.0
                mainDiag[idx] = 2.0 * (hPrev + hNext)
                supDiag[idx] = idx + 1 < mLen ? hNext : 0.0
                rhs[idx] = 6.0 * (
                    (knotY[knotIdx + 1] - knotY[knotIdx]) / hNext
                    - (knotY[knotIdx] - knotY[knotIdx - 1]) / hPrev
                )
            }

            // Thomas O(K) forward elimination
            for idx in 1..<mLen {
                let factor = subDiag[idx] / mainDiag[idx - 1]
                mainDiag[idx] -= factor * supDiag[idx - 1]
                rhs[idx] -= factor * rhs[idx - 1]
            }

            // Thomas O(K) back substitution
            secondDeriv[mLen] = rhs[mLen - 1] / mainDiag[mLen - 1]
            for idx in stride(from: mLen - 2, through: 0, by: -1) {
                secondDeriv[idx + 1] = (rhs[idx] - supDiag[idx] * secondDeriv[idx + 2]) / mainDiag[idx]
            }
        }

        // Evaluate piecewise cubic polynomial across integer sample indices 0 ..< sampleCount
        var output = [Double](repeating: 0.0, count: sampleCount)
        var seg = 0
        for sampleIdx in 0..<sampleCount {
            let x = Double(sampleIdx)
            while seg + 1 < segCount && x > knotX[seg + 1] {
                seg += 1
            }
            let xL = knotX[seg]
            let xR = knotX[seg + 1]
            let hi = h[seg]
            let a = (xR - x) / hi
            let b = (x - xL) / hi
            let cubicTermL = (a * a * a - a) * (hi * hi) / 6.0
            let cubicTermR = (b * b * b - b) * (hi * hi) / 6.0
            output[sampleIdx] = a * knotY[seg] + b * knotY[seg + 1]
                + cubicTermL * secondDeriv[seg] + cubicTermR * secondDeriv[seg + 1]
        }

        return output
    }

    private static func detectLocalExtrema(in signal: [Double]) -> (maxIndices: [Int], minIndices: [Int]) {
        let n = signal.count
        guard n >= 3 else { return ([], []) }

        var maxIndices: [Int] = []
        var minIndices: [Int] = []

        for i in 1..<(n - 1) {
            let prev = signal[i - 1]
            let curr = signal[i]
            let next = signal[i + 1]
            if curr > prev && curr >= next {
                maxIndices.append(i)
            } else if curr < prev && curr <= next {
                minIndices.append(i)
            }
        }
        return (maxIndices, minIndices)
    }

    private static func buildBoundaryAnchoredKnots(
        signal: [Double],
        extremaIndices: [Int],
        isUpper: Bool
    ) -> (xs: [Double], ys: [Double]) {
        let lastIdx = signal.count - 1
        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(extremaIndices.count + 2)
        ys.reserveCapacity(extremaIndices.count + 2)

        // Left boundary anchor at x = 0
        let leftAnchorY: Double
        if extremaIndices.count >= 2 {
            let x1 = Double(extremaIndices[0])
            let x2 = Double(extremaIndices[1])
            let y1 = signal[extremaIndices[0]]
            let y2 = signal[extremaIndices[1]]
            let extrap = y1 - x1 * (y2 - y1) / max(1.0, x2 - x1)
            leftAnchorY = isUpper ? max(signal[0], min(extrap, max(y1, y2))) : min(signal[0], max(extrap, min(y1, y2)))
        } else if let only = extremaIndices.first {
            leftAnchorY = isUpper ? max(signal[0], signal[only]) : min(signal[0], signal[only])
        } else {
            leftAnchorY = signal[0]
        }

        xs.append(0.0)
        ys.append(leftAnchorY)

        for idx in extremaIndices where idx > 0 && idx < lastIdx {
            xs.append(Double(idx))
            ys.append(signal[idx])
        }

        // Right boundary anchor at x = N - 1
        let rightAnchorY: Double
        if extremaIndices.count >= 2 {
            let k = extremaIndices.count
            let x1 = Double(extremaIndices[k - 2])
            let x2 = Double(extremaIndices[k - 1])
            let y1 = signal[extremaIndices[k - 2]]
            let y2 = signal[extremaIndices[k - 1]]
            let extrap = y2 + (Double(lastIdx) - x2) * (y2 - y1) / max(1.0, x2 - x1)
            rightAnchorY = isUpper
                ? max(signal[lastIdx], min(extrap, max(y1, y2)))
                : min(signal[lastIdx], max(extrap, min(y1, y2)))
        } else if let only = extremaIndices.last {
            rightAnchorY = isUpper ? max(signal[lastIdx], signal[only]) : min(signal[lastIdx], signal[only])
        } else {
            rightAnchorY = signal[lastIdx]
        }

        xs.append(Double(lastIdx))
        ys.append(rightAnchorY)

        return (xs, ys)
    }

    private static func satisfiesIMFZeroCrossingCondition(_ x: [Double]) -> Bool {
        let extrema = detectLocalExtrema(in: x)
        let totalExtrema = extrema.maxIndices.count + extrema.minIndices.count
        var zeroCrossings = 0
        for i in 0..<(x.count - 1) {
            if (x[i] <= 0.0 && x[i + 1] > 0.0) || (x[i] >= 0.0 && x[i + 1] < 0.0) {
                zeroCrossings += 1
            }
        }
        return abs(totalExtrema - zeroCrossings) <= 1
    }
}
