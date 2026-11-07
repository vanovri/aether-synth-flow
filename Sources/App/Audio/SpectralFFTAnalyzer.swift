// MARK: - FILE: SpectralFFTAnalyzer.swift

import Foundation
import Accelerate
import os

public struct SpectrumAnalysisFrame: Sendable, Equatable {
    public let bars: [Float]              // 64 logarithmically spaced perceptual bars in [0.0 ... 1.0]
    public let dominantFrequencyHz: Float

    public init(bars: [Float] = [Float](repeating: 0, count: 64), dominantFrequencyHz: Float = 0) {
        self.bars = bars
        self.dominantFrequencyHz = dominantFrequencyHz
    }

    public var subBandEnergy: Float {
        bandAverage(range: 0..<8)
    }

    public var lowBandEnergy: Float {
        bandAverage(range: 8..<24)
    }

    public var midBandEnergy: Float {
        bandAverage(range: 24..<44)
    }

    public var highBandEnergy: Float {
        bandAverage(range: 44..<64)
    }

    private func bandAverage(range: Range<Int>) -> Float {
        guard !bars.isEmpty else { return 0 }
        let start = max(0, min(range.lowerBound, bars.count))
        let end = max(start, min(range.upperBound, bars.count))
        guard end > start else { return 0 }
        var sum: Float = 0
        for idx in start..<end {
            sum += bars[idx]
        }
        return min(max(sum / Float(end - start), 0.0), 1.0)
    }
}

/// Hardware-accelerated vDSP 256-point Hann-windowed DFT mapped into 64 perceptual display bars.
public final class SpectralFFTAnalyzer: @unchecked Sendable {
    public static let fftLength: Int = 256
    public static let outputBarCount: Int = 64

    private let dftSetup: vDSP_DFT_Setup?
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    private var hannWindow: [Float]
    private var windowedReal: [Float]
    private var zeroImag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var smoothedBars: [Float]

    public init() {
        self.dftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(Self.fftLength),
            .FORWARD
        )
        self.lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock_s())

        var win = [Float](repeating: 0, count: Self.fftLength)
        vDSP_hann_window(&win, vDSP_Length(Self.fftLength), Int32(vDSP_HANN_NORM))
        self.hannWindow = win
        self.windowedReal = [Float](repeating: 0, count: Self.fftLength)
        self.zeroImag = [Float](repeating: 0, count: Self.fftLength)
        self.outReal = [Float](repeating: 0, count: Self.fftLength)
        self.outImag = [Float](repeating: 0, count: Self.fftLength)
        self.smoothedBars = [Float](repeating: 0, count: Self.outputBarCount)
    }

    deinit {
        if let setup = dftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    public func reset() {
        os_unfair_lock_lock(lock)
        for i in 0..<Self.outputBarCount {
            smoothedBars[i] = 0
        }
        os_unfair_lock_unlock(lock)
    }

    public func analyze(samples: [Float], sampleRate: Double) -> SpectrumAnalysisFrame {
        guard samples.count >= Self.fftLength, let setup = dftSetup else {
            return SpectrumAnalysisFrame()
        }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let n = Self.fftLength
        let nyquistBins = n / 2

        samples.withUnsafeBufferPointer { srcPtr in
            vDSP_vmul(
                srcPtr.baseAddress!,
                1,
                hannWindow,
                1,
                &windowedReal,
                1,
                vDSP_Length(n)
            )
        }

        vDSP_DFT_Execute(setup, windowedReal, zeroImag, &outReal, &outImag)

        let scale = 2.0 / Float(n)
        var binMagnitudes = [Float](repeating: 0, count: nyquistBins)
        var maxBinIndex = 1
        var maxBinMagnitude: Float = 0.0

        for k in 1..<nyquistBins {
            let mag = hypot(outReal[k], outImag[k]) * scale
            binMagnitudes[k] = mag
            if mag > maxBinMagnitude {
                maxBinMagnitude = mag
                maxBinIndex = k
            }
        }

        let binResolutionHz = Float(max(8_000.0, sampleRate)) / Float(n)
        let dominantHz = Float(maxBinIndex) * binResolutionHz

        // Logarithmic perceptual mapping across [1 ... nyquistBins-1] into 64 bars
        let minBin: Float = 1.0
        let maxBin = Float(nyquistBins - 1)
        let logRatio = log(maxBin / minBin)

        var nextBars = [Float](repeating: 0, count: Self.outputBarCount)
        for bar in 0..<Self.outputBarCount {
            let t0 = Float(bar) / Float(Self.outputBarCount)
            let t1 = Float(bar + 1) / Float(Self.outputBarCount)
            let bStart = max(1, Int(floor(minBin * exp(logRatio * t0))))
            let bEnd = min(nyquistBins - 1, max(bStart, Int(ceil(minBin * exp(logRatio * t1)))))

            var localPeak: Float = 0
            for b in bStart...bEnd {
                if binMagnitudes[b] > localPeak {
                    localPeak = binMagnitudes[b]
                }
            }

            // Convert amplitude to normalized decibels [-58 dB ... 0 dB] -> [0.0 ... 1.0]
            let db = 20.0 * log10(max(localPeak, 1.0e-5))
            let normalized = min(max((db + 58.0) / 58.0, 0.0), 1.0)

            // Fast attack (0.65), smooth musical release (0.28)
            let prev = smoothedBars[bar]
            let coeff: Float = normalized > prev ? 0.65 : 0.28
            let blended = prev + coeff * (normalized - prev)
            smoothedBars[bar] = blended
            nextBars[bar] = blended
        }

        return SpectrumAnalysisFrame(bars: nextBars, dominantFrequencyHz: dominantHz)
    }
}
