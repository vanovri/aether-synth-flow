// MARK: - FILE: SpatialHRTFConvolver.swift

import Foundation
import simd

// MARK: - 1. 3D Spherical Binaural Source Pose & 128-Tap Stereo HRIR Pair

public struct BinauralSourcePose: Sendable, Equatable, Codable {
    public var azimuthDeg: Float      // [-180.0 ... +180.0], +90° = right ear (+X), 0° = front (+Z)
    public var elevationDeg: Float    // [-45.0 ... +90.0], +90° = zenith (+Y)
    public var distanceMeters: Float  // [0.15 ... 10.0]

    public init(
        azimuthDeg: Float = 0.0,
        elevationDeg: Float = 0.0,
        distanceMeters: Float = 1.4
    ) {
        self.azimuthDeg = Self.wrapAzimuthDegrees(azimuthDeg)
        self.elevationDeg = min(max(elevationDeg, -45.0), 90.0)
        self.distanceMeters = min(max(distanceMeters, 0.15), 10.0)
    }

    @inline(__always)
    public static func wrapAzimuthDegrees(_ degrees: Float) -> Float {
        guard degrees.isFinite else { return 0.0 }
        var wrapped = fmodf(degrees, 360.0)
        if wrapped > 180.0 {
            wrapped -= 360.0
        } else if wrapped < -180.0 {
            wrapped += 360.0
        }
        if wrapped == -180.0 && degrees > 0.0 {
            return 180.0
        }
        return wrapped
    }

    @inline(__always)
    public var azimuthRadians: Float {
        azimuthDeg * (.pi / 180.0)
    }

    @inline(__always)
    public var elevationRadians: Float {
        elevationDeg * (.pi / 180.0)
    }

    /// Listener-centric unit direction vector (+X right, +Y up, +Z front).
    @inline(__always)
    public var unitDirectionVector: SIMD3<Float> {
        let az = azimuthRadians
        let el = elevationRadians
        let cosEl = cosf(el)
        return SIMD3<Float>(
            cosEl * sinf(az),
            sinf(el),
            cosEl * cosf(az)
        )
    }

    /// Great-circle angular separation in degrees between two spherical source directions.
    @inline(__always)
    public func angularSeparationDegrees(from other: BinauralSourcePose) -> Float {
        let dotVal = min(max(simd_dot(unitDirectionVector, other.unitDirectionVector), -1.0), 1.0)
        return acosf(dotVal) * (180.0 / .pi)
    }
}

public struct StereoHRIRPair: Sendable, Equatable {
    public static let tapCount: Int = 128

    public let leftTaps: [Float]
    public let rightTaps: [Float]
    public let itdSeconds: Float

    public init(leftTaps: [Float], rightTaps: [Float], itdSeconds: Float) {
        if leftTaps.count == Self.tapCount {
            self.leftTaps = leftTaps
        } else if leftTaps.count > Self.tapCount {
            self.leftTaps = Array(leftTaps.prefix(Self.tapCount))
        } else {
            self.leftTaps = leftTaps + [Float](repeating: 0.0, count: Self.tapCount - leftTaps.count)
        }

        if rightTaps.count == Self.tapCount {
            self.rightTaps = rightTaps
        } else if rightTaps.count > Self.tapCount {
            self.rightTaps = Array(rightTaps.prefix(Self.tapCount))
        } else {
            self.rightTaps = rightTaps + [Float](repeating: 0.0, count: Self.tapCount - rightTaps.count)
        }

        self.itdSeconds = itdSeconds
    }
}

public typealias KEMARHRIRPair = StereoHRIRPair

// MARK: - 2. Procedural KEMAR Anthropometric HRIR Synthesizer

public enum KEMARHRIRSynthesizer: Sendable {
    public static let headRadiusMeters: Float = 0.0875
    public static let speedOfSound: Float = 343.0
    public static let diffractionCutoffRadPerSec: Double = Double(343.0 / 0.0875) // w0 = c / a ≈ 3920 rad/s

    @inline(__always)
    public static func wrapAngleToPi(_ radians: Float) -> Float {
        guard radians.isFinite else { return 0.0 }
        var wrapped = fmodf(radians, 2.0 * Float.pi)
        if wrapped > Float.pi {
            wrapped -= 2.0 * Float.pi
        } else if wrapped < -Float.pi {
            wrapped += 2.0 * Float.pi
        }
        return wrapped
    }

    /// Exact Woodworth-Schlosberg spherical-head diffraction ITD in seconds:
    /// - `|theta| < pi/2`: `(a / c) * (sin|theta| + |theta|) * cos(phi)`
    /// - `|theta| >= pi/2`: `(a / c) * (pi - |theta| + sin|theta|) * cos(phi)`
    /// Positive ITD indicates right-ear lead (`theta > 0`); zero on the median plane (`theta == 0` or `±pi`).
    @inline(__always)
    public static func computeWoodworthITD(
        azimuthRadians: Float,
        elevationRadians: Float = 0.0
    ) -> Float {
        let theta = wrapAngleToPi(azimuthRadians)
        let absTheta = abs(theta)
        if absTheta < 1.0e-7 || abs(Float.pi - absTheta) < 1.0e-6 {
            return 0.0
        }

        let clampedPhi = min(max(elevationRadians, -Float.pi * 0.5), Float.pi * 0.5)
        let cosPhi = max(0.0, cosf(clampedPhi))
        let scale = headRadiusMeters / speedOfSound

        let angularTerm: Float
        if absTheta < Float.pi * 0.5 {
            angularTerm = sinf(absTheta) + absTheta
        } else {
            angularTerm = max(0.0, (Float.pi - absTheta) + sinf(absTheta))
        }

        let magnitude = scale * angularTerm * cosPhi
        return theta >= 0.0 ? magnitude : -magnitude
    }

    @inline(__always)
    public static func computeWoodworthITD(
        azimuthDeg: Float,
        elevationDeg: Float = 0.0
    ) -> Float {
        let wrappedAz = BinauralSourcePose.wrapAzimuthDegrees(azimuthDeg)
        if abs(wrappedAz) < 1.0e-6 || abs(abs(wrappedAz) - 180.0) < 1.0e-5 {
            return 0.0
        }
        return computeWoodworthITD(
            azimuthRadians: wrappedAz * (.pi / 180.0),
            elevationRadians: elevationDeg * (.pi / 180.0)
        )
    }

    /// Analytical KEMAR primary pinna spectral notch center frequency `f_N1(phi) = 6200 + 3800 * sin(phi)` Hz.
    @inline(__always)
    public static func primaryPinnaNotchFrequencyHz(elevationDeg: Float) -> Double {
        let clampedEl = min(max(Double(elevationDeg), -45.0), 90.0)
        let sinPhi = sin(clampedEl * Double.pi / 180.0)
        return 6_200.0 + 3_800.0 * sinPhi
    }

    /// Analytical KEMAR secondary pinna spectral notch center frequency `f_N2(phi) = 9800 + 2600 * sin(phi)` Hz.
    @inline(__always)
    public static func secondaryPinnaNotchFrequencyHz(elevationDeg: Float) -> Double {
        let clampedEl = min(max(Double(elevationDeg), -45.0), 90.0)
        let sinPhi = sin(clampedEl * Double.pi / 180.0)
        return 9_800.0 + 2_600.0 * sinPhi
    }

    // Stack-only Direct-Form II Transposed biquad section (zero heap allocations)
    private struct BiquadSection {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var z1: Double = 0.0
        var z2: Double = 0.0

        @inline(__always)
        static func identity() -> BiquadSection {
            BiquadSection(b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
        }

        @inline(__always)
        static func peakingEQ(
            frequencyHz: Double,
            q: Double,
            gainDB: Double,
            sampleRate: Double
        ) -> BiquadSection {
            if abs(gainDB) < 1.0e-6 {
                return identity()
            }
            let clampedHz = min(max(frequencyHz, 40.0), sampleRate * 0.465)
            let safeQ = max(0.25, q)
            let amp = pow(10.0, gainDB / 40.0)
            let omega = 2.0 * Double.pi * clampedHz / sampleRate
            let sinW = sin(omega)
            let cosW = cos(omega)
            let alpha = sinW / (2.0 * safeQ)

            let b0 = 1.0 + alpha * amp
            let b1 = -2.0 * cosW
            let b2 = 1.0 - alpha * amp
            let a0 = 1.0 + alpha / amp
            let a1 = -2.0 * cosW
            let a2 = 1.0 - alpha / amp

            let invA0 = 1.0 / a0
            return BiquadSection(
                b0: b0 * invA0,
                b1: b1 * invA0,
                b2: b2 * invA0,
                a1: a1 * invA0,
                a2: a2 * invA0
            )
        }

        @inline(__always)
        static func highShelf(
            frequencyHz: Double,
            slope: Double,
            gainDB: Double,
            sampleRate: Double
        ) -> BiquadSection {
            if abs(gainDB) < 1.0e-6 {
                return identity()
            }
            let clampedHz = min(max(frequencyHz, 200.0), sampleRate * 0.465)
            let amp = pow(10.0, gainDB / 40.0)
            let omega = 2.0 * Double.pi * clampedHz / sampleRate
            let sinW = sin(omega)
            let cosW = cos(omega)
            let safeSlope = max(0.2, slope)
            let radTerm = max(0.0, (amp + 1.0 / amp) * (1.0 / safeSlope - 1.0) + 2.0)
            let twoSqrtAAlpha = sinW * sqrt(radTerm)

            let aPlus1 = amp + 1.0
            let aMinus1 = amp - 1.0
            let b0 = amp * (aPlus1 + aMinus1 * cosW + twoSqrtAAlpha)
            let b1 = -2.0 * amp * (aMinus1 + aPlus1 * cosW)
            let b2 = amp * (aPlus1 + aMinus1 * cosW - twoSqrtAAlpha)
            let a0 = aPlus1 - aMinus1 * cosW + twoSqrtAAlpha
            let a1 = 2.0 * (aMinus1 - aPlus1 * cosW)
            let a2 = aPlus1 - aMinus1 * cosW - twoSqrtAAlpha

            let invA0 = 1.0 / a0
            return BiquadSection(
                b0: b0 * invA0,
                b1: b1 * invA0,
                b2: b2 * invA0,
                a1: a1 * invA0,
                a2: a2 * invA0
            )
        }

        @inline(__always)
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// Allocation-free synthesis directly into caller-provided 128-sample raw `Float` buffers.
    /// Safe to execute on the real-time audio render thread. Returns signed Woodworth-Schlosberg ITD (seconds).
    @discardableResult
    public static func synthesizeInto(
        pose: BinauralSourcePose,
        sampleRate: Double,
        outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>
    ) -> Float {
        return synthesizeRadiansInto(
            azimuthRadians: pose.azimuthRadians,
            elevationRadians: pose.elevationRadians,
            distanceMeters: pose.distanceMeters,
            sampleRate: sampleRate,
            outLeft: outLeft,
            outRight: outRight
        )
    }

    @discardableResult
    public static func synthesizeRadiansInto(
        azimuthRadians: Float,
        elevationRadians: Float,
        distanceMeters: Float,
        sampleRate: Double,
        outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>
    ) -> Float {
        let safeRate = max(8_000.0, sampleRate)
        let theta = wrapAngleToPi(azimuthRadians)
        let phi = min(max(elevationRadians, -Float.pi * 0.25), Float.pi * 0.5)
        let safeDist = min(max(distanceMeters, 0.15), 10.0)

        let itdSec = computeWoodworthITD(azimuthRadians: theta, elevationRadians: phi)
        let itdSamples = Double(abs(itdSec)) * safeRate

        // 6-sample baseline group delay ensures 4th-order Thiran parameter D stays strictly inside [3.5, 4.5)
        let baseDelaySamples = 6.0
        let leftTotalDelay = itdSec >= 0.0 ? (baseDelaySamples + itdSamples) : baseDelaySamples
        let rightTotalDelay = itdSec < 0.0 ? (baseDelaySamples + itdSamples) : baseDelaySamples

        // Exact median-plane guard guarantees bit-identical left/right ear synthesis when theta == 0 or ±pi
        let isMedianPlane = (itdSec == 0.0)
        let lateralProj = isMedianPlane ? 0.0 : Double(cosf(phi) * sinf(theta))
        let cosPsiLeft = -lateralProj
        let cosPsiRight = lateralProj

        let sinPhi = Double(sinf(phi))
        let absTheta = Double(abs(theta))
        let distanceMetersD = Double(safeDist)

        // Inverse-distance pressure scaling normalized to unity at r = 1.0 m (clamped in extreme near-field)
        let distanceGain = 1.0 / max(0.30, distanceMetersD)

        synthesizeSingleEarInto(
            totalDelaySamples: leftTotalDelay,
            earCosIncidence: cosPsiLeft,
            sinElevation: sinPhi,
            absAzimuthRadians: absTheta,
            distanceMeters: distanceMetersD,
            distanceGain: distanceGain,
            sampleRate: safeRate,
            output: outLeft
        )

        if isMedianPlane {
            for i in 0..<StereoHRIRPair.tapCount {
                outRight[i] = outLeft[i]
            }
        } else {
            synthesizeSingleEarInto(
                totalDelaySamples: rightTotalDelay,
                earCosIncidence: cosPsiRight,
                sinElevation: sinPhi,
                absAzimuthRadians: absTheta,
                distanceMeters: distanceMetersD,
                distanceGain: distanceGain,
                sampleRate: safeRate,
                output: outRight
            )
        }

        return itdSec
    }

    public static func synthesize(
        pose: BinauralSourcePose,
        sampleRate: Double = 48_000.0
    ) -> StereoHRIRPair {
        var left = [Float](repeating: 0.0, count: StereoHRIRPair.tapCount)
        var right = [Float](repeating: 0.0, count: StereoHRIRPair.tapCount)
        let itd = left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                synthesizeInto(
                    pose: pose,
                    sampleRate: sampleRate,
                    outLeft: lBuf.baseAddress!,
                    outRight: rBuf.baseAddress!
                )
            }
        }
        return StereoHRIRPair(leftTaps: left, rightTaps: right, itdSeconds: itd)
    }

    public static func synthesize(
        azimuthRadians: Float,
        elevationRadians: Float,
        distanceMeters: Float,
        sampleRate: Double = 48_000.0
    ) -> KEMARHRIRPair {
        var left = [Float](repeating: 0.0, count: StereoHRIRPair.tapCount)
        var right = [Float](repeating: 0.0, count: StereoHRIRPair.tapCount)
        let itd = left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                synthesizeRadiansInto(
                    azimuthRadians: azimuthRadians,
                    elevationRadians: elevationRadians,
                    distanceMeters: distanceMeters,
                    sampleRate: sampleRate,
                    outLeft: lBuf.baseAddress!,
                    outRight: rBuf.baseAddress!
                )
            }
        }
        return StereoHRIRPair(leftTaps: left, rightTaps: right, itdSeconds: itd)
    }

    @inline(__always)
    private static func thiranProduct(_ d: Double, k: Int) -> Double {
        let dMinus4 = d - 4.0
        let kd = Double(k)
        let p0 = (dMinus4 + 0.0) / (dMinus4 + kd + 0.0)
        let p1 = (dMinus4 + 1.0) / (dMinus4 + kd + 1.0)
        let p2 = (dMinus4 + 2.0) / (dMinus4 + kd + 2.0)
        let p3 = (dMinus4 + 3.0) / (dMinus4 + kd + 3.0)
        let p4 = (dMinus4 + 4.0) / (dMinus4 + kd + 4.0)
        return p0 * p1 * p2 * p3 * p4
    }

    private static func synthesizeSingleEarInto(
        totalDelaySamples: Double,
        earCosIncidence: Double,
        sinElevation: Double,
        absAzimuthRadians: Double,
        distanceMeters: Double,
        distanceGain: Double,
        sampleRate: Double,
        output: UnsafeMutablePointer<Float>
    ) {
        let tapCount = StereoHRIRPair.tapCount

        // 1. Integer delay + stable 4th-order Thiran all-pass fractional delay D in [3.5, 4.5)
        let clampedDelay = min(max(totalDelaySamples, 4.0), Double(tapCount - 28))
        let intShift = max(0, Int(floor(clampedDelay - 3.5)))
        let thiranD = clampedDelay - Double(intShift)

        let a1 = -4.0 * thiranProduct(thiranD, k: 1)
        let a2 =  6.0 * thiranProduct(thiranD, k: 2)
        let a3 = -4.0 * thiranProduct(thiranD, k: 3)
        let a4 =  1.0 * thiranProduct(thiranD, k: 4)

        var thiranX = (0.0, 0.0, 0.0, 0.0)
        var thiranY = (0.0, 0.0, 0.0, 0.0)

        // 2. Brown & Duda (1998) spherical head-shadow first-order high-shelf ILD filter:
        //    H_HS(s) = (alpha(psi)*s + w0) / (s + w0), w0 = c / a ≈ 3920 rad/s, alpha_min = 0.08
        let omega0 = diffractionCutoffRadPerSec
        let alphaMin = 0.08
        let alphaHS = (1.0 + 0.5 * alphaMin) + (1.0 - 0.5 * alphaMin) * earCosIncidence
        let bilinearK = 2.0 * sampleRate
        let invHSDenom = 1.0 / (bilinearK + omega0)
        let hsB0 = (alphaHS * bilinearK + omega0) * invHSDenom
        let hsB1 = (-alphaHS * bilinearK + omega0) * invHSDenom
        let hsA1 = (-bilinearK + omega0) * invHSDenom
        var hsPrevX = 0.0
        var hsPrevY = 0.0

        // Near-field acoustic proximity bass shelf for r < 1.0 m (Brungart & Rabinowitz spherical wave model)
        let proxB0: Double
        let proxB1: Double
        let proxA1: Double
        if distanceMeters < 1.0 {
            let proximityFactor = min(max((1.0 - distanceMeters) / 0.85, 0.0), 1.0)
            let ipsiWeight = max(0.25, 0.55 + 0.45 * earCosIncidence)
            let dcBoost = 1.0 + 0.85 * proximityFactor * ipsiWeight
            let omegaProx = 2.0 * Double.pi * 260.0
            let invProxDenom = 1.0 / (bilinearK + omegaProx)
            proxB0 = (bilinearK + dcBoost * omegaProx) * invProxDenom
            proxB1 = (-bilinearK + dcBoost * omegaProx) * invProxDenom
            proxA1 = (-bilinearK + omegaProx) * invProxDenom
        } else {
            proxB0 = 1.0
            proxB1 = 0.0
            proxA1 = 0.0
        }
        var proxPrevX = 0.0
        var proxPrevY = 0.0

        // 3. 4-Stage KEMAR Pinna Spectral Notch & Concha Resonance Cascade:
        //    Stage 1: Primary Concha Resonance peak at 4.3 kHz (+5.5 dB, Q = 2.2)
        //    Stage 2: Primary Pinna Notch f_N1(phi) = 6200 + 3800*sin(phi) Hz (-14 dB, Q = 6.5)
        //    Stage 3: Secondary Pinna Notch f_N2(phi) = 9800 + 2600*sin(phi) Hz (-11 dB, Q = 8.0)
        //    Stage 4: Front-Back Pinna Shadowing shelf attenuating > 7.5 kHz when |theta| > 90°
        let fNotch1 = 6_200.0 + 3_800.0 * sinElevation
        let fNotch2 = 9_800.0 + 2_600.0 * sinElevation
        let rearShadowDB: Double
        if absAzimuthRadians > Double.pi * 0.5 {
            let rearRatio = min(max((absAzimuthRadians - Double.pi * 0.5) / (Double.pi * 0.5), 0.0), 1.0)
            rearShadowDB = -6.5 * rearRatio
        } else {
            rearShadowDB = 0.0
        }

        var bqConcha = BiquadSection.peakingEQ(
            frequencyHz: 4_300.0,
            q: 2.2,
            gainDB: 5.5,
            sampleRate: sampleRate
        )
        var bqPinnaN1 = BiquadSection.peakingEQ(
            frequencyHz: fNotch1,
            q: 6.5,
            gainDB: -14.0,
            sampleRate: sampleRate
        )
        var bqPinnaN2 = BiquadSection.peakingEQ(
            frequencyHz: fNotch2,
            q: 8.0,
            gainDB: -11.0,
            sampleRate: sampleRate
        )
        var bqRearShadow = BiquadSection.highShelf(
            frequencyHz: 7_500.0,
            slope: 0.85,
            gainDB: rearShadowDB,
            sampleRate: sampleRate
        )

        let tailFadeLength = 12
        let tailFadeStart = tapCount - tailFadeLength

        for n in 0..<tapCount {
            let x0: Double = (n == intShift) ? distanceGain : 0.0

            // 4th-order Thiran all-pass fractional delay
            let yThiran = a4 * x0
                + a3 * thiranX.0
                + a2 * thiranX.1
                + a1 * thiranX.2
                + thiranX.3
                - a1 * thiranY.0
                - a2 * thiranY.1
                - a3 * thiranY.2
                - a4 * thiranY.3

            thiranX = (x0, thiranX.0, thiranX.1, thiranX.2)
            thiranY = (yThiran, thiranY.0, thiranY.1, thiranY.2)

            // Brown & Duda Spherical Head Shadow ILD
            let yHS = hsB0 * yThiran + hsB1 * hsPrevX - hsA1 * hsPrevY
            hsPrevX = yThiran
            hsPrevY = yHS

            // Near-Field Proximity Bass Boost (identity when r >= 1.0 m)
            let yProx = proxB0 * yHS + proxB1 * proxPrevX - proxA1 * proxPrevY
            proxPrevX = yHS
            proxPrevY = yProx

            // 4-stage KEMAR Concha & Pinna Biquad Cascade
            var pinnaOut = bqConcha.process(yProx)
            pinnaOut = bqPinnaN1.process(pinnaOut)
            pinnaOut = bqPinnaN2.process(pinnaOut)
            pinnaOut = bqRearShadow.process(pinnaOut)

            let window: Double
            if n >= tailFadeStart {
                let u = Double(n - tailFadeStart + 1) / Double(tailFadeLength + 1)
                window = 0.5 * (1.0 + cos(Double.pi * u))
            } else {
                window = 1.0
            }

            let sample = pinnaOut * window
            output[n] = sample.isFinite ? Float(sample) : 0.0
        }
    }
}

// MARK: - 3. Allocation-Free Uniformly Partitioned Overlap-Save (UPOLS) Fast FFT Convolver

public struct PartitionedOverlapSaveConvolver: Sendable {
    public static let blockSize: Int = 128
    public static let fftSize: Int = 256
    public static let partitionCount: Int = 4
    public static let maxImpulseLength: Int = 512

    // Precomputed Radix-2 bit-reversal & twiddle tables for N = 256
    private let bitReversedIndices: [Int]
    private let twiddleCos: [Float]
    private let twiddleSin: [Float]
    private let crossfadeWeights: [Float]

    // Dual-slot frequency-domain transfer functions (Active + Secondary/Previous for raised-cosine crossfade)
    private var activeFilterLeftRe: [Float]
    private var activeFilterLeftIm: [Float]
    private var activeFilterRightRe: [Float]
    private var activeFilterRightIm: [Float]
    private var activeHeadLeft: [Float]
    private var activeHeadRight: [Float]
    private var activePartitionCount: Int = 1

    private var prevFilterLeftRe: [Float]
    private var prevFilterLeftIm: [Float]
    private var prevFilterRightRe: [Float]
    private var prevFilterRightIm: [Float]
    private var prevHeadLeft: [Float]
    private var prevHeadRight: [Float]
    private var prevPartitionCount: Int = 1

    // Frequency-Domain Delay Line (FDDL) storing past 256-pt complex input spectra
    private var fdlReal: [Float]
    private var fdlImag: [Float]
    private var fdlHead: Int = 0

    // 128-sample sliding input block + zero-latency sub-block FIFO state
    private var prevInputBlock: [Float]
    private var currInputBlock: [Float]
    private var blockFill: Int = 0
    private var hasProcessedSamples: Bool = false

    private var tailValidActive: Bool = false
    private var precomputedTailActiveL: [Float]
    private var precomputedTailActiveR: [Float]

    private var tailValidPrev: Bool = false
    private var precomputedTailPrevL: [Float]
    private var precomputedTailPrevR: [Float]

    // Raised-cosine crossfade index across `blockSize = 128` samples
    private var crossfadeIndex: Int = 128

    // Pre-allocated split-complex FFT workspaces (zero heap allocations during render)
    private var scratchFFTRe: [Float]
    private var scratchFFTIm: [Float]
    private var accumLeftRe: [Float]
    private var accumLeftIm: [Float]
    private var accumRightRe: [Float]
    private var accumRightIm: [Float]
    private var prevOutScratchL: [Float]
    private var prevOutScratchR: [Float]
    private var setupScratchRe: [Float]
    private var setupScratchIm: [Float]

    public init(leftTaps: [Float] = [1.0], rightTaps: [Float] = [1.0]) {
        let n = Self.fftSize
        let b = Self.blockSize
        let p = Self.partitionCount
        let bankLen = p * n

        var rev = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var x = i
            var r = 0
            for _ in 0..<8 {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            rev[i] = r
        }
        self.bitReversedIndices = rev

        var tCos = [Float](repeating: 0.0, count: n / 2)
        var tSin = [Float](repeating: 0.0, count: n / 2)
        for k in 0..<(n / 2) {
            let angle = -2.0 * Double.pi * Double(k) / Double(n)
            tCos[k] = Float(cos(angle))
            tSin[k] = Float(sin(angle))
        }
        self.twiddleCos = tCos
        self.twiddleSin = tSin

        var xfade = [Float](repeating: 0.0, count: b)
        for i in 0..<b {
            let phase = Double.pi * (Double(i) + 0.5) / Double(b)
            xfade[i] = Float(0.5 * (1.0 - cos(phase)))
        }
        self.crossfadeWeights = xfade

        self.activeFilterLeftRe = [Float](repeating: 0.0, count: bankLen)
        self.activeFilterLeftIm = [Float](repeating: 0.0, count: bankLen)
        self.activeFilterRightRe = [Float](repeating: 0.0, count: bankLen)
        self.activeFilterRightIm = [Float](repeating: 0.0, count: bankLen)
        self.activeHeadLeft = [Float](repeating: 0.0, count: b)
        self.activeHeadRight = [Float](repeating: 0.0, count: b)

        self.prevFilterLeftRe = [Float](repeating: 0.0, count: bankLen)
        self.prevFilterLeftIm = [Float](repeating: 0.0, count: bankLen)
        self.prevFilterRightRe = [Float](repeating: 0.0, count: bankLen)
        self.prevFilterRightIm = [Float](repeating: 0.0, count: bankLen)
        self.prevHeadLeft = [Float](repeating: 0.0, count: b)
        self.prevHeadRight = [Float](repeating: 0.0, count: b)

        self.fdlReal = [Float](repeating: 0.0, count: bankLen)
        self.fdlImag = [Float](repeating: 0.0, count: bankLen)

        self.prevInputBlock = [Float](repeating: 0.0, count: b)
        self.currInputBlock = [Float](repeating: 0.0, count: b)

        self.precomputedTailActiveL = [Float](repeating: 0.0, count: b)
        self.precomputedTailActiveR = [Float](repeating: 0.0, count: b)
        self.precomputedTailPrevL = [Float](repeating: 0.0, count: b)
        self.precomputedTailPrevR = [Float](repeating: 0.0, count: b)

        self.scratchFFTRe = [Float](repeating: 0.0, count: n)
        self.scratchFFTIm = [Float](repeating: 0.0, count: n)
        self.accumLeftRe = [Float](repeating: 0.0, count: n)
        self.accumLeftIm = [Float](repeating: 0.0, count: n)
        self.accumRightRe = [Float](repeating: 0.0, count: n)
        self.accumRightIm = [Float](repeating: 0.0, count: n)
        self.prevOutScratchL = [Float](repeating: 0.0, count: b)
        self.prevOutScratchR = [Float](repeating: 0.0, count: b)
        self.setupScratchRe = [Float](repeating: 0.0, count: n)
        self.setupScratchIm = [Float](repeating: 0.0, count: n)

        setImpulseResponse(leftTaps: leftTaps, rightTaps: rightTaps)
    }

    public init(hrir: StereoHRIRPair) {
        self.init(leftTaps: hrir.leftTaps, rightTaps: hrir.rightTaps)
    }

    public var isCrossfading: Bool {
        crossfadeIndex < Self.blockSize
    }

    public mutating func reset() {
        for i in 0..<fdlReal.count {
            fdlReal[i] = 0.0
            fdlImag[i] = 0.0
        }
        for i in 0..<Self.blockSize {
            prevInputBlock[i] = 0.0
            currInputBlock[i] = 0.0
            precomputedTailActiveL[i] = 0.0
            precomputedTailActiveR[i] = 0.0
            precomputedTailPrevL[i] = 0.0
            precomputedTailPrevR[i] = 0.0
        }
        fdlHead = 0
        blockFill = 0
        tailValidActive = false
        tailValidPrev = false
        crossfadeIndex = Self.blockSize
        hasProcessedSamples = false
    }

    /// Allocation-free pointer-based impulse update used on the real-time audio render thread.
    public mutating func setImpulseResponse(
        leftPtr: UnsafePointer<Float>,
        leftCount: Int,
        rightPtr: UnsafePointer<Float>,
        rightCount: Int
    ) {
        let b = Self.blockSize
        let n = Self.fftSize
        let pMax = Self.partitionCount
        let maxLen = min(Self.maxImpulseLength, max(1, max(leftCount, rightCount)))
        let neededPartitions = min(pMax, max(1, (maxLen + b - 1) / b))

        if hasProcessedSamples {
            let prevCopyLen = activePartitionCount * n
            for i in 0..<prevCopyLen {
                prevFilterLeftRe[i] = activeFilterLeftRe[i]
                prevFilterLeftIm[i] = activeFilterLeftIm[i]
                prevFilterRightRe[i] = activeFilterRightRe[i]
                prevFilterRightIm[i] = activeFilterRightIm[i]
            }
            prevPartitionCount = activePartitionCount
            for i in 0..<b {
                prevHeadLeft[i] = activeHeadLeft[i]
                prevHeadRight[i] = activeHeadRight[i]
                precomputedTailPrevL[i] = precomputedTailActiveL[i]
                precomputedTailPrevR[i] = precomputedTailActiveR[i]
            }
            tailValidPrev = tailValidActive
            crossfadeIndex = 0
        } else {
            crossfadeIndex = b
        }

        activePartitionCount = neededPartitions

        for i in 0..<b {
            activeHeadLeft[i] = i < leftCount ? leftPtr[i] : 0.0
            activeHeadRight[i] = i < rightCount ? rightPtr[i] : 0.0
        }

        for part in 0..<neededPartitions {
            let tapBase = part * b
            let specBase = part * n

            for i in 0..<b {
                let tapIdx = tapBase + i
                setupScratchRe[i] = tapIdx < leftCount ? leftPtr[tapIdx] : 0.0
                setupScratchIm[i] = 0.0
                setupScratchRe[b + i] = 0.0
                setupScratchIm[b + i] = 0.0
            }
            fft256InPlace(real: &setupScratchRe, imag: &setupScratchIm, inverse: false)
            for k in 0..<n {
                activeFilterLeftRe[specBase + k] = setupScratchRe[k]
                activeFilterLeftIm[specBase + k] = setupScratchIm[k]
            }

            for i in 0..<b {
                let tapIdx = tapBase + i
                setupScratchRe[i] = tapIdx < rightCount ? rightPtr[tapIdx] : 0.0
                setupScratchIm[i] = 0.0
                setupScratchRe[b + i] = 0.0
                setupScratchIm[b + i] = 0.0
            }
            fft256InPlace(real: &setupScratchRe, imag: &setupScratchIm, inverse: false)
            for k in 0..<n {
                activeFilterRightRe[specBase + k] = setupScratchRe[k]
                activeFilterRightIm[specBase + k] = setupScratchIm[k]
            }
        }

        tailValidActive = false
    }

    public mutating func setImpulseResponse(leftTaps: [Float], rightTaps: [Float]) {
        leftTaps.withUnsafeBufferPointer { lBuf in
            rightTaps.withUnsafeBufferPointer { rBuf in
                let empty: Float = 0.0
                withUnsafePointer(to: empty) { fallbackPtr in
                    setImpulseResponse(
                        leftPtr: lBuf.baseAddress ?? fallbackPtr,
                        leftCount: lBuf.count,
                        rightPtr: rBuf.baseAddress ?? fallbackPtr,
                        rightCount: rBuf.count
                    )
                }
            }
        }
    }

    // MARK: - Radix-2 Split-Complex FFT / IFFT (N = 256)

    @inline(__always)
    private func fft256InPlace(real: inout [Float], imag: inout [Float], inverse: Bool) {
        let n = Self.fftSize

        for i in 0..<n {
            let j = bitReversedIndices[i]
            if i < j {
                let tr = real[i]; real[i] = real[j]; real[j] = tr
                let ti = imag[i]; imag[i] = imag[j]; imag[j] = ti
            }
        }

        let signIm: Float = inverse ? -1.0 : 1.0
        var len = 2
        while len <= n {
            let halfLen = len >> 1
            let twiddleStep = n / len
            var base = 0
            while base < n {
                var twIdx = 0
                for j in 0..<halfLen {
                    let uIdx = base + j
                    let vIdx = uIdx + halfLen
                    let wr = twiddleCos[twIdx]
                    let wi = twiddleSin[twIdx] * signIm

                    let vr = real[vIdx] * wr - imag[vIdx] * wi
                    let vi = real[vIdx] * wi + imag[vIdx] * wr

                    let ur = real[uIdx]
                    let ui = imag[uIdx]

                    real[uIdx] = ur + vr
                    imag[uIdx] = ui + vi
                    real[vIdx] = ur - vr
                    imag[vIdx] = ui - vi

                    twIdx += twiddleStep
                }
                base += len
            }
            len <<= 1
        }

        if inverse {
            let invN: Float = 1.0 / Float(n)
            for i in 0..<n {
                real[i] *= invN
                imag[i] *= invN
            }
        }
    }

    @inline(__always)
    private mutating func convolveCurrentSpectrumWithBank(
        isActiveBank: Bool,
        currentSpecRe: [Float],
        currentSpecIm: [Float]
    ) {
        let n = Self.fftSize

        if isActiveBank {
            for k in 0..<n {
                let xr = currentSpecRe[k]
                let xi = currentSpecIm[k]
                let hlRe = activeFilterLeftRe[k]
                let hlIm = activeFilterLeftIm[k]
                let hrRe = activeFilterRightRe[k]
                let hrIm = activeFilterRightIm[k]

                accumLeftRe[k] = xr * hlRe - xi * hlIm
                accumLeftIm[k] = xr * hlIm + xi * hlRe
                accumRightRe[k] = xr * hrRe - xi * hrIm
                accumRightIm[k] = xr * hrIm + xi * hrRe
            }

            if activePartitionCount > 1 {
                for p in 1..<activePartitionCount {
                    let fdlSlot = (fdlHead - (p - 1) + Self.partitionCount) & (Self.partitionCount - 1)
                    let fdlBase = fdlSlot * n
                    let hBase = p * n
                    for k in 0..<n {
                        let xr = fdlReal[fdlBase + k]
                        let xi = fdlImag[fdlBase + k]
                        let hlRe = activeFilterLeftRe[hBase + k]
                        let hlIm = activeFilterLeftIm[hBase + k]
                        let hrRe = activeFilterRightRe[hBase + k]
                        let hrIm = activeFilterRightIm[hBase + k]

                        accumLeftRe[k] += xr * hlRe - xi * hlIm
                        accumLeftIm[k] += xr * hlIm + xi * hlRe
                        accumRightRe[k] += xr * hrRe - xi * hrIm
                        accumRightIm[k] += xr * hrIm + xi * hrRe
                    }
                }
            }
        } else {
            for k in 0..<n {
                let xr = currentSpecRe[k]
                let xi = currentSpecIm[k]
                let hlRe = prevFilterLeftRe[k]
                let hlIm = prevFilterLeftIm[k]
                let hrRe = prevFilterRightRe[k]
                let hrIm = prevFilterRightIm[k]

                accumLeftRe[k] = xr * hlRe - xi * hlIm
                accumLeftIm[k] = xr * hlIm + xi * hlRe
                accumRightRe[k] = xr * hrRe - xi * hrIm
                accumRightIm[k] = xr * hrIm + xi * hrRe
            }

            if prevPartitionCount > 1 {
                for p in 1..<prevPartitionCount {
                    let fdlSlot = (fdlHead - (p - 1) + Self.partitionCount) & (Self.partitionCount - 1)
                    let fdlBase = fdlSlot * n
                    let hBase = p * n
                    for k in 0..<n {
                        let xr = fdlReal[fdlBase + k]
                        let xi = fdlImag[fdlBase + k]
                        let hlRe = prevFilterLeftRe[hBase + k]
                        let hlIm = prevFilterLeftIm[hBase + k]
                        let hrRe = prevFilterRightRe[hBase + k]
                        let hrIm = prevFilterRightIm[hBase + k]

                        accumLeftRe[k] += xr * hlRe - xi * hlIm
                        accumLeftIm[k] += xr * hlIm + xi * hlRe
                        accumRightRe[k] += xr * hrRe - xi * hrIm
                        accumRightIm[k] += xr * hrIm + xi * hrRe
                    }
                }
            }
        }

        fft256InPlace(real: &accumLeftRe, imag: &accumLeftIm, inverse: true)
        fft256InPlace(real: &accumRightRe, imag: &accumRightIm, inverse: true)
    }

    @inline(__always)
    private mutating func commitCompleted128BlockToFDL() {
        let b = Self.blockSize
        let n = Self.fftSize

        for i in 0..<b {
            scratchFFTRe[i] = prevInputBlock[i]
            scratchFFTIm[i] = 0.0
            scratchFFTRe[b + i] = currInputBlock[i]
            scratchFFTIm[b + i] = 0.0
        }
        fft256InPlace(real: &scratchFFTRe, imag: &scratchFFTIm, inverse: false)

        fdlHead = (fdlHead + 1) & (Self.partitionCount - 1)
        let fdlBase = fdlHead * n
        for k in 0..<n {
            fdlReal[fdlBase + k] = scratchFFTRe[k]
            fdlImag[fdlBase + k] = scratchFFTIm[k]
        }

        for i in 0..<b {
            prevInputBlock[i] = currInputBlock[i]
            currInputBlock[i] = 0.0
        }
        blockFill = 0
        tailValidActive = false
        tailValidPrev = false
    }

    @inline(__always)
    private mutating func ensurePrecomputedTailsValid() {
        let b = Self.blockSize
        guard !tailValidActive || (crossfadeIndex < b && !tailValidPrev) else { return }

        for i in 0..<b {
            scratchFFTRe[i] = prevInputBlock[i]
            scratchFFTIm[i] = 0.0
            scratchFFTRe[b + i] = 0.0
            scratchFFTIm[b + i] = 0.0
        }
        fft256InPlace(real: &scratchFFTRe, imag: &scratchFFTIm, inverse: false)

        for k in 0..<Self.fftSize {
            setupScratchRe[k] = scratchFFTRe[k]
            setupScratchIm[k] = scratchFFTIm[k]
        }

        if !tailValidActive {
            convolveCurrentSpectrumWithBank(isActiveBank: true, currentSpecRe: setupScratchRe, currentSpecIm: setupScratchIm)
            for i in 0..<b {
                precomputedTailActiveL[i] = accumLeftRe[b + i]
                precomputedTailActiveR[i] = accumRightRe[b + i]
            }
            tailValidActive = true
        }

        if crossfadeIndex < b && !tailValidPrev {
            convolveCurrentSpectrumWithBank(isActiveBank: false, currentSpecRe: setupScratchRe, currentSpecIm: setupScratchIm)
            for i in 0..<b {
                precomputedTailPrevL[i] = accumLeftRe[b + i]
                precomputedTailPrevR[i] = accumRightRe[b + i]
            }
            tailValidPrev = true
        }
    }

    @inline(__always)
    public mutating func processSample(_ monoIn: Float) -> (Float, Float) {
        hasProcessedSamples = true
        ensurePrecomputedTailsValid()

        let b = Self.blockSize
        let r = blockFill
        currInputBlock[r] = monoIn

        var actL = precomputedTailActiveL[r]
        var actR = precomputedTailActiveR[r]
        for j in 0...r {
            let xVal = currInputBlock[r - j]
            actL += activeHeadLeft[j] * xVal
            actR += activeHeadRight[j] * xVal
        }

        let outL: Float
        let outR: Float
        if crossfadeIndex < b {
            var prvL = precomputedTailPrevL[r]
            var prvR = precomputedTailPrevR[r]
            for j in 0...r {
                let xVal = currInputBlock[r - j]
                prvL += prevHeadLeft[j] * xVal
                prvR += prevHeadRight[j] * xVal
            }
            let alpha = crossfadeWeights[crossfadeIndex]
            let invAlpha = 1.0 - alpha
            outL = prvL * invAlpha + actL * alpha
            outR = prvR * invAlpha + actR * alpha
            crossfadeIndex += 1
        } else {
            outL = actL
            outR = actR
        }

        blockFill = r + 1
        if blockFill == b {
            commitCompleted128BlockToFDL()
        }

        return (outL, outR)
    }

    public mutating func processMonoToStereoBlock(
        monoInput: UnsafePointer<Float>,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        hasProcessedSamples = true

        let b = Self.blockSize
        let n = Self.fftSize
        var offset = 0

        while offset < frameCount && blockFill != 0 {
            let (l, r) = processSample(monoInput[offset])
            leftOutput[offset] = l
            rightOutput[offset] = r
            offset += 1
        }

        while frameCount - offset >= b {
            for i in 0..<b {
                let sample = monoInput[offset + i]
                currInputBlock[i] = sample
                scratchFFTRe[i] = prevInputBlock[i]
                scratchFFTIm[i] = 0.0
                scratchFFTRe[b + i] = sample
                scratchFFTIm[b + i] = 0.0
            }
            fft256InPlace(real: &scratchFFTRe, imag: &scratchFFTIm, inverse: false)

            for k in 0..<n {
                setupScratchRe[k] = scratchFFTRe[k]
                setupScratchIm[k] = scratchFFTIm[k]
            }

            if crossfadeIndex < b {
                convolveCurrentSpectrumWithBank(isActiveBank: false, currentSpecRe: setupScratchRe, currentSpecIm: setupScratchIm)
                for i in 0..<b {
                    prevOutScratchL[i] = accumLeftRe[b + i]
                    prevOutScratchR[i] = accumRightRe[b + i]
                }

                convolveCurrentSpectrumWithBank(isActiveBank: true, currentSpecRe: setupScratchRe, currentSpecIm: setupScratchIm)
                for i in 0..<b {
                    let actL = accumLeftRe[b + i]
                    let actR = accumRightRe[b + i]
                    if crossfadeIndex < b {
                        let alpha = crossfadeWeights[crossfadeIndex]
                        let invAlpha = 1.0 - alpha
                        leftOutput[offset + i] = prevOutScratchL[i] * invAlpha + actL * alpha
                        rightOutput[offset + i] = prevOutScratchR[i] * invAlpha + actR * alpha
                        crossfadeIndex += 1
                    } else {
                        leftOutput[offset + i] = actL
                        rightOutput[offset + i] = actR
                    }
                }
            } else {
                convolveCurrentSpectrumWithBank(isActiveBank: true, currentSpecRe: setupScratchRe, currentSpecIm: setupScratchIm)
                for i in 0..<b {
                    leftOutput[offset + i] = accumLeftRe[b + i]
                    rightOutput[offset + i] = accumRightRe[b + i]
                }
            }

            fdlHead = (fdlHead + 1) & (Self.partitionCount - 1)
            let fdlBase = fdlHead * n
            for k in 0..<n {
                fdlReal[fdlBase + k] = setupScratchRe[k]
                fdlImag[fdlBase + k] = setupScratchIm[k]
            }
            for i in 0..<b {
                prevInputBlock[i] = currInputBlock[i]
                currInputBlock[i] = 0.0
            }
            blockFill = 0
            tailValidActive = false
            tailValidPrev = false

            offset += b
        }

        while offset < frameCount {
            let (l, r) = processSample(monoInput[offset])
            leftOutput[offset] = l
            rightOutput[offset] = r
            offset += 1
        }
    }
}

// MARK: - 4. High-Level Real-Time Spatial HRTF Convolver (>1.5° Dual-Path Raised-Cosine Crossfader)

public struct SpatialHRTFConvolver: Sendable {
    public static let angularCrossfadeThresholdDeg: Float = 1.5
    public static let distanceCrossfadeThresholdMeters: Float = 0.05

    public let sampleRate: Double
    public private(set) var activePose: BinauralSourcePose
    public private(set) var convolver: PartitionedOverlapSaveConvolver

    // Pre-allocated 128-tap synthesis buffers (exchanged out of self during update for zero CoW allocations)
    private var stagingLeftHRIR: [Float]
    private var stagingRightHRIR: [Float]

    public init(
        sampleRate: Double = 48_000.0,
        initialPose: BinauralSourcePose = BinauralSourcePose()
    ) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.activePose = initialPose

        let initialPair = KEMARHRIRSynthesizer.synthesize(pose: initialPose, sampleRate: safeRate)
        self.convolver = PartitionedOverlapSaveConvolver(hrir: initialPair)
        self.stagingLeftHRIR = [Float](repeating: 0.0, count: StereoHRIRPair.tapCount)
        self.stagingRightHRIR = [Float](repeating: 0.0, count: StereoHRIRPair.tapCount)
    }

    public mutating func reset() {
        convolver.reset()
    }

    @inline(__always)
    public mutating func updatePoseIfNeeded(_ targetPose: BinauralSourcePose) {
        let angDelta = targetPose.angularSeparationDegrees(from: activePose)
        let distDelta = abs(targetPose.distanceMeters - activePose.distanceMeters)
        guard angDelta > Self.angularCrossfadeThresholdDeg || distDelta > Self.distanceCrossfadeThresholdMeters else {
            return
        }

        // Wait until any in-flight 128-sample crossfade completes before switching again
        guard !convolver.isCrossfading else { return }

        var localL = stagingLeftHRIR
        var localR = stagingRightHRIR
        stagingLeftHRIR = []
        stagingRightHRIR = []

        localL.withUnsafeMutableBufferPointer { lBuf in
            localR.withUnsafeMutableBufferPointer { rBuf in
                _ = KEMARHRIRSynthesizer.synthesizeInto(
                    pose: targetPose,
                    sampleRate: sampleRate,
                    outLeft: lBuf.baseAddress!,
                    outRight: rBuf.baseAddress!
                )
                convolver.setImpulseResponse(
                    leftPtr: lBuf.baseAddress!,
                    leftCount: StereoHRIRPair.tapCount,
                    rightPtr: rBuf.baseAddress!,
                    rightCount: StereoHRIRPair.tapCount
                )
            }
        }

        stagingLeftHRIR = localL
        stagingRightHRIR = localR
        activePose = targetPose
    }

    public mutating func processMonoToBinaural(
        monoInput: UnsafePointer<Float>,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int,
        pose: BinauralSourcePose
    ) {
        guard frameCount > 0 else { return }
        updatePoseIfNeeded(pose)
        convolver.processMonoToStereoBlock(
            monoInput: monoInput,
            leftOutput: leftOutput,
            rightOutput: rightOutput,
            frameCount: frameCount
        )
    }
}
