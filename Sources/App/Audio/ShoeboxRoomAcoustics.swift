// MARK: - FILE: ShoeboxRoomAcoustics.swift

import Foundation
import simd

// MARK: - 1. Shoebox Acoustic Room Presets & Physical Geometry Configuration

public struct ShoeboxRoomConfiguration: Sendable, Equatable, Codable {
    public let dimensionsMeters: SIMD3<Float>   // (Lx, Ly, Lz) in meters
    public let wallAbsorption: Float            // Mean Sabine/Eyring energy absorption alpha in (0, 1)
    public let airAbsorptionPerMeter: Float     // High-frequency air damping factor (Np/m)
    public let earlyReflectionLevel: Float      // Linear early reflection bus Trim
    public let lateFDNWetMix: Float             // 8-channel Hadamard FDN late reverb send/return mix
    public let rt60Seconds: Float               // Late reverberation decay time T60 (seconds)

    public init(
        dimensionsMeters: SIMD3<Float>,
        wallAbsorption: Float,
        airAbsorptionPerMeter: Float,
        earlyReflectionLevel: Float,
        lateFDNWetMix: Float,
        rt60Seconds: Float
    ) {
        self.dimensionsMeters = SIMD3<Float>(
            max(2.5, dimensionsMeters.x),
            max(2.2, dimensionsMeters.y),
            max(2.5, dimensionsMeters.z)
        )
        self.wallAbsorption = min(max(wallAbsorption, 0.001), 0.9995)
        self.airAbsorptionPerMeter = min(max(airAbsorptionPerMeter, 0.0), 0.05)
        self.earlyReflectionLevel = min(max(earlyReflectionLevel, 0.0), 1.5)
        self.lateFDNWetMix = min(max(lateFDNWetMix, 0.0), 1.0)
        self.rt60Seconds = min(max(rt60Seconds, 0.08), 12.0)
    }

    @inline(__always)
    public var wallPressureReflectance: Float {
        sqrtf(max(0.0, 1.0 - wallAbsorption))
    }
}

public enum ShoeboxRoomPreset: Int, CaseIterable, Codable, Sendable, Identifiable {
    case anechoicChamber = 0
    case obsidianStudio = 1
    case glassConservatory = 2
    case cathedralVault = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .anechoicChamber:
            return "Anechoic Chamber"
        case .obsidianStudio:
            return "Obsidian Studio"
        case .glassConservatory:
            return "Glass Conservatory"
        case .cathedralVault:
            return "Cathedral Vault"
        }
    }

    public var shortLabel: String {
        switch self {
        case .anechoicChamber:
            return "Anechoic"
        case .obsidianStudio:
            return "Studio"
        case .glassConservatory:
            return "Conservatory"
        case .cathedralVault:
            return "Cathedral"
        }
    }

    public var configuration: ShoeboxRoomConfiguration {
        switch self {
        case .anechoicChamber:
            return ShoeboxRoomConfiguration(
                dimensionsMeters: SIMD3<Float>(6.0, 4.0, 6.0),
                wallAbsorption: 0.9985,
                airAbsorptionPerMeter: 0.0010,
                earlyReflectionLevel: 0.02,
                lateFDNWetMix: 0.0,
                rt60Seconds: 0.10
            )
        case .obsidianStudio:
            return ShoeboxRoomConfiguration(
                dimensionsMeters: SIMD3<Float>(7.2, 3.4, 8.4),
                wallAbsorption: 0.62,
                airAbsorptionPerMeter: 0.0014,
                earlyReflectionLevel: 0.42,
                lateFDNWetMix: 0.16,
                rt60Seconds: 0.65
            )
        case .glassConservatory:
            return ShoeboxRoomConfiguration(
                dimensionsMeters: SIMD3<Float>(9.0, 4.4, 10.5),
                wallAbsorption: 0.34,
                airAbsorptionPerMeter: 0.0012,
                earlyReflectionLevel: 0.56,
                lateFDNWetMix: 0.30,
                rt60Seconds: 1.75
            )
        case .cathedralVault:
            return ShoeboxRoomConfiguration(
                dimensionsMeters: SIMD3<Float>(10.2, 5.2, 12.4),
                wallAbsorption: 0.05,
                airAbsorptionPerMeter: 0.0009,
                earlyReflectionLevel: 0.68,
                lateFDNWetMix: 0.48,
                rt60Seconds: 4.20
            )
        }
    }
}

// MARK: - 2. Solved 3D Image-Source Reflection Tap & Summary

public struct ImageSourceReflectionTap: Sendable, Equatable, Identifiable {
    public var id: Int { tapIndex }
    public let tapIndex: Int
    public let reflectionOrder: Int             // 1 (6 axial walls) or 2 (12 dihedral edges)
    public let latticeIndices: SIMD3<Int32>     // (nx, ny, nz) in {-1, 0, +1}^3
    public let imagePositionMeters: SIMD3<Float>
    public let pathLengthMeters: Float          // d_m
    public let propagationDelaySeconds: Float   // tau_m = d_m / c
    public let linearGain: Float                // 0 < g_m <= 1 / d_m
    public let airLowPassCoeff: Float           // One-pole air absorption LP pole in [0, 0.92]
    public let incidenceAzimuthDeg: Float       // Head-relative azimuth in [-180, 180]
    public let incidenceElevationDeg: Float     // Head-relative elevation in [-90, 90]
    public let itdSeconds: Float                // Woodworth-Schlosberg ITD for (theta_m, phi_m)
    public let leftEarGain: Float               // Gain * ipsilateral/contralateral head-shadow weight
    public let rightEarGain: Float

    public init(
        tapIndex: Int,
        reflectionOrder: Int,
        latticeIndices: SIMD3<Int32>,
        imagePositionMeters: SIMD3<Float>,
        pathLengthMeters: Float,
        propagationDelaySeconds: Float,
        linearGain: Float,
        airLowPassCoeff: Float,
        incidenceAzimuthDeg: Float,
        incidenceElevationDeg: Float,
        itdSeconds: Float,
        leftEarGain: Float,
        rightEarGain: Float
    ) {
        self.tapIndex = tapIndex
        self.reflectionOrder = reflectionOrder
        self.latticeIndices = latticeIndices
        self.imagePositionMeters = imagePositionMeters
        self.pathLengthMeters = pathLengthMeters
        self.propagationDelaySeconds = propagationDelaySeconds
        self.linearGain = linearGain
        self.airLowPassCoeff = airLowPassCoeff
        self.incidenceAzimuthDeg = incidenceAzimuthDeg
        self.incidenceElevationDeg = incidenceElevationDeg
        self.itdSeconds = itdSeconds
        self.leftEarGain = leftEarGain
        self.rightEarGain = rightEarGain
    }
}

public struct SolvedShoeboxReflections: Sendable, Equatable {
    public let listenerPositionMeters: SIMD3<Float>
    public let sourcePositionMeters: SIMD3<Float>
    public let directDistanceMeters: Float
    public let directDelaySeconds: Float
    public let taps: [ImageSourceReflectionTap]

    public var totalReflectionEnergy: Float {
        var energy: Float = 0.0
        for tap in taps {
            energy += tap.linearGain * tap.linearGain
        }
        return energy
    }
}

// MARK: - 3. Allen & Berkley 3D Shoebox Image-Source Early Reflection Solver + 8-Ch Hadamard FDN

public struct ShoeboxRoomSimulator: Sendable {
    public static let speedOfSound: Float = 343.0
    public static let firstOrderCount: Int = 6
    public static let secondOrderEdgeCount: Int = 12
    public static let totalImageSourceCount: Int = 18

    // Pre-allocated power-of-two circular delay line for 18 early reflections (~682 ms @ 48 kHz)
    private static let earlyDelayCapacity: Int = 32_768
    private static let earlyDelayMask: Int = 32_767

    // Pre-allocated 8-channel Sylvester-Hadamard FDN late reverb lines
    private static let fdnChannels: Int = 8
    private static let fdnLineCapacity: Int = 8_192
    private static let fdnLineMask: Int = 8_191
    private static let fdnBasePrimeDelays48k: (Int, Int, Int, Int, Int, Int, Int, Int) = (
        1_103, 1_327, 1_571, 1_823, 2_089, 2_381, 2_693, 3_019
    )

    // Precomputed 18 lattice offsets: 6 first-order + 12 second-order edge images
    private static let imageLattice: [SIMD3<Int32>] = {
        var coords: [SIMD3<Int32>] = []
        coords.reserveCapacity(18)
        for nx: Int32 in -1...1 {
            for ny: Int32 in -1...1 {
                for nz: Int32 in -1...1 {
                    let order = abs(nx) + abs(ny) + abs(nz)
                    if order == 1 {
                        coords.append(SIMD3<Int32>(nx, ny, nz))
                    }
                }
            }
        }
        for nx: Int32 in -1...1 {
            for ny: Int32 in -1...1 {
                for nz: Int32 in -1...1 {
                    let order = abs(nx) + abs(ny) + abs(nz)
                    if order == 2 {
                        coords.append(SIMD3<Int32>(nx, ny, nz))
                    }
                }
            }
        }
        return coords
    }()

    private struct RuntimeReflectionSlot: Sendable {
        var delaySamplesLeft: Float = 64.0
        var delaySamplesRight: Float = 64.0
        var gainLeft: Float = 0.0
        var gainRight: Float = 0.0
        var airPole: Float = 0.15
        var lpStateLeft: Float = 0.0
        var lpStateRight: Float = 0.0
    }

    public let sampleRate: Double
    public private(set) var activePreset: ShoeboxRoomPreset
    public private(set) var activeSourcePose: BinauralSourcePose
    public private(set) var activeHeadQuaternion: SIMD4<Float>

    // Early reflection delay line & 18 pre-allocated filter states
    private var earlyDelayBuffer: [Float]
    private var earlyWriteHead: Int = 0
    private var runtimeSlots: [RuntimeReflectionSlot]

    // 8-channel Hadamard FDN late reverb buffers (pre-allocated at init)
    private var fdnBuffer: [Float]
    private var fdnWriteHeads: (Int, Int, Int, Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0, 0, 0, 0)
    private var fdnDelayLengths: (Int, Int, Int, Int, Int, Int, Int, Int)
    private var fdnDampStates: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    private var fdnMeanDelaySeconds: Float = 0.042

    public init(
        sampleRate: Double = 48_000.0,
        initialPreset: ShoeboxRoomPreset = .obsidianStudio,
        initialPose: BinauralSourcePose = BinauralSourcePose()
    ) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.activePreset = initialPreset
        self.activeSourcePose = initialPose
        self.activeHeadQuaternion = SIMD4<Float>(0, 0, 0, 1)

        self.earlyDelayBuffer = [Float](repeating: 0.0, count: Self.earlyDelayCapacity)
        self.runtimeSlots = [RuntimeReflectionSlot](repeating: RuntimeReflectionSlot(), count: Self.totalImageSourceCount)

        self.fdnBuffer = [Float](repeating: 0.0, count: Self.fdnChannels * Self.fdnLineCapacity)
        let rateScale = safeRate / 48_000.0
        let primes = Self.fdnBasePrimeDelays48k
        let d0 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.0) * rateScale).rounded())))
        let d1 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.1) * rateScale).rounded())))
        let d2 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.2) * rateScale).rounded())))
        let d3 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.3) * rateScale).rounded())))
        let d4 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.4) * rateScale).rounded())))
        let d5 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.5) * rateScale).rounded())))
        let d6 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.6) * rateScale).rounded())))
        let d7 = min(Self.fdnLineCapacity - 8, max(64, Int((Double(primes.7) * rateScale).rounded())))
        self.fdnDelayLengths = (d0, d1, d2, d3, d4, d5, d6, d7)
        let sumDelays = d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7
        self.fdnMeanDelaySeconds = Float(Double(sumDelays) / (8.0 * safeRate))

        recomputeRuntimeSlots(
            configuration: initialPreset.configuration,
            sourcePose: initialPose,
            headQuaternion: SIMD4<Float>(0, 0, 0, 1)
        )
    }

    public mutating func reset() {
        for i in 0..<earlyDelayBuffer.count { earlyDelayBuffer[i] = 0.0 }
        for i in 0..<fdnBuffer.count { fdnBuffer[i] = 0.0 }
        earlyWriteHead = 0
        fdnWriteHeads = (0, 0, 0, 0, 0, 0, 0, 0)
        fdnDampStates = (0, 0, 0, 0, 0, 0, 0, 0)
        for idx in 0..<runtimeSlots.count {
            runtimeSlots[idx].lpStateLeft = 0.0
            runtimeSlots[idx].lpStateRight = 0.0
        }
    }

    @inline(__always)
    private static func clampInteriorPoint(
        _ point: SIMD3<Float>,
        dimensions: SIMD3<Float>,
        margin: Float = 0.25
    ) -> SIMD3<Float> {
        let mx = min(margin, dimensions.x * 0.25)
        let my = min(margin, dimensions.y * 0.25)
        let mz = min(margin, dimensions.z * 0.25)
        return SIMD3<Float>(
            min(max(point.x, mx), dimensions.x - mx),
            min(max(point.y, my), dimensions.y - my),
            min(max(point.z, mz), dimensions.z - mz)
        )
    }

    @inline(__always)
    private static func mirrorCoordinate(
        sourceCoord: Float,
        roomLength: Float,
        latticeIndex: Int32
    ) -> Float {
        switch latticeIndex {
        case -1:
            return -sourceCoord
        case 1:
            return 2.0 * roomLength - sourceCoord
        default:
            return sourceCoord
        }
    }

    @inline(__always)
    private static func normalizedHeadQuat(_ raw: SIMD4<Float>) -> simd_quatf {
        let lenSq = simd_length_squared(raw)
        guard lenSq > 1.0e-8 && lenSq.isFinite else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_quatf(vector: raw * (1.0 / sqrtf(lenSq)))
    }

    /// Solves the 6 first-order wall images and 12 second-order edge virtual image sources
    /// for a 3D rectangular shoebox enclosure relative to the listener's head orientation quaternion.
    public static func solveImageSources(
        configuration: ShoeboxRoomConfiguration,
        sourcePose: BinauralSourcePose,
        headOrientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) -> SolvedShoeboxReflections {
        let dims = configuration.dimensionsMeters
        let listenerPos = clampInteriorPoint(
            SIMD3<Float>(dims.x * 0.50, min(1.65, dims.y * 0.46), dims.z * 0.42),
            dimensions: dims,
            margin: 0.30
        )

        let rawSourceOffset = sourcePose.unitDirectionVector * sourcePose.distanceMeters
        var sourcePos = clampInteriorPoint(listenerPos + rawSourceOffset, dimensions: dims, margin: 0.22)
        if simd_distance(sourcePos, listenerPos) < 0.12 {
            sourcePos = clampInteriorPoint(listenerPos + SIMD3<Float>(0.0, 0.0, 0.25), dimensions: dims, margin: 0.22)
        }

        let directDist = max(0.05, simd_distance(sourcePos, listenerPos))
        let directDelay = directDist / speedOfSound
        let wallRefl = max(1.0e-4, configuration.wallPressureReflectance)
        let invHeadQuat = normalizedHeadQuat(headOrientation.vector).inverse

        var taps: [ImageSourceReflectionTap] = []
        taps.reserveCapacity(totalImageSourceCount)

        for (idx, nVec) in imageLattice.enumerated() {
            let order = Int(abs(nVec.x) + abs(nVec.y) + abs(nVec.z))
            let imgPos = SIMD3<Float>(
                mirrorCoordinate(sourceCoord: sourcePos.x, roomLength: dims.x, latticeIndex: nVec.x),
                mirrorCoordinate(sourceCoord: sourcePos.y, roomLength: dims.y, latticeIndex: nVec.y),
                mirrorCoordinate(sourceCoord: sourcePos.z, roomLength: dims.z, latticeIndex: nVec.z)
            )

            let delta = imgPos - listenerPos
            let pathLen = max(directDist + 1.0e-3, simd_length(delta))
            let delaySec = pathLen / speedOfSound

            let reflCoeff = (order == 1) ? wallRefl : (wallRefl * wallRefl)
            let airAtten = expf(-configuration.airAbsorptionPerMeter * pathLen)
            let rawGain = (reflCoeff * airAtten) / pathLen
            let safeGain = min(max(rawGain, 1.0e-7), 1.0 / pathLen)

            let worldDir = delta / pathLen
            let headDir = invHeadQuat.act(worldDir)
            let azRad = atan2f(headDir.x, headDir.z)
            let elRad = asinf(min(max(headDir.y, -1.0), 1.0))

            let azDeg = BinauralSourcePose.wrapAzimuthDegrees(azRad * (180.0 / .pi))
            let elDeg = min(max(elRad * (180.0 / .pi), -90.0), 90.0)
            let itd = KEMARHRIRSynthesizer.computeWoodworthITD(
                azimuthRadians: azRad,
                elevationRadians: elRad
            )

            // Directional Brown-Duda spherical head-shadow pan weights
            let lateral = cosf(elRad) * sinf(azRad) // +1 right ear, -1 left ear
            let rightWeight = 0.65 + 0.35 * lateral
            let leftWeight = 0.65 - 0.35 * lateral

            let airPole = min(max(0.12 + 0.024 * pathLen, 0.10), 0.86)

            taps.append(
                ImageSourceReflectionTap(
                    tapIndex: idx,
                    reflectionOrder: order,
                    latticeIndices: nVec,
                    imagePositionMeters: imgPos,
                    pathLengthMeters: pathLen,
                    propagationDelaySeconds: delaySec,
                    linearGain: safeGain,
                    airLowPassCoeff: airPole,
                    incidenceAzimuthDeg: azDeg,
                    incidenceElevationDeg: elDeg,
                    itdSeconds: itd,
                    leftEarGain: safeGain * leftWeight,
                    rightEarGain: safeGain * rightWeight
                )
            )
        }

        return SolvedShoeboxReflections(
            listenerPositionMeters: listenerPos,
            sourcePositionMeters: sourcePos,
            directDistanceMeters: directDist,
            directDelaySeconds: directDelay,
            taps: taps
        )
    }

    @inline(__always)
    private mutating func recomputeRuntimeSlots(
        configuration: ShoeboxRoomConfiguration,
        sourcePose: BinauralSourcePose,
        headQuaternion: SIMD4<Float>
    ) {
        let dims = configuration.dimensionsMeters
        let listenerPos = Self.clampInteriorPoint(
            SIMD3<Float>(dims.x * 0.50, min(1.65, dims.y * 0.46), dims.z * 0.42),
            dimensions: dims,
            margin: 0.30
        )
        let rawSourceOffset = sourcePose.unitDirectionVector * sourcePose.distanceMeters
        var sourcePos = Self.clampInteriorPoint(listenerPos + rawSourceOffset, dimensions: dims, margin: 0.22)
        if simd_distance(sourcePos, listenerPos) < 0.12 {
            sourcePos = Self.clampInteriorPoint(listenerPos + SIMD3<Float>(0.0, 0.0, 0.25), dimensions: dims, margin: 0.22)
        }

        let directDist = max(0.05, simd_distance(sourcePos, listenerPos))
        let wallRefl = max(1.0e-4, configuration.wallPressureReflectance)
        let invHeadQuat = Self.normalizedHeadQuat(headQuaternion).inverse
        let fs = Float(sampleRate)
        let maxDelaySamples = Float(Self.earlyDelayCapacity - 8)
        let trim = configuration.earlyReflectionLevel

        for idx in 0..<Self.totalImageSourceCount {
            let nVec = Self.imageLattice[idx]
            let order = abs(nVec.x) + abs(nVec.y) + abs(nVec.z)
            let imgPos = SIMD3<Float>(
                Self.mirrorCoordinate(sourceCoord: sourcePos.x, roomLength: dims.x, latticeIndex: nVec.x),
                Self.mirrorCoordinate(sourceCoord: sourcePos.y, roomLength: dims.y, latticeIndex: nVec.y),
                Self.mirrorCoordinate(sourceCoord: sourcePos.z, roomLength: dims.z, latticeIndex: nVec.z)
            )

            let delta = imgPos - listenerPos
            let pathLen = max(directDist + 1.0e-3, simd_length(delta))
            let baseDelaySec = pathLen / Self.speedOfSound

            let reflCoeff = (order == 1) ? wallRefl : (wallRefl * wallRefl)
            let airAtten = expf(-configuration.airAbsorptionPerMeter * pathLen)
            let gain = ((reflCoeff * airAtten) / pathLen) * trim

            let worldDir = delta / pathLen
            let headDir = invHeadQuat.act(worldDir)
            let azRad = atan2f(headDir.x, headDir.z)
            let elRad = asinf(min(max(headDir.y, -1.0), 1.0))
            let itd = KEMARHRIRSynthesizer.computeWoodworthITD(
                azimuthRadians: azRad,
                elevationRadians: elRad
            )

            let delaySecL = baseDelaySec + (itd >= 0.0 ? itd : 0.0)
            let delaySecR = baseDelaySec + (itd < 0.0 ? -itd : 0.0)

            let lateral = cosf(elRad) * sinf(azRad)
            let rightWeight = 0.65 + 0.35 * lateral
            let leftWeight = 0.65 - 0.35 * lateral

            runtimeSlots[idx].delaySamplesLeft = min(max(delaySecL * fs, 2.0), maxDelaySamples)
            runtimeSlots[idx].delaySamplesRight = min(max(delaySecR * fs, 2.0), maxDelaySamples)
            runtimeSlots[idx].gainLeft = gain * leftWeight
            runtimeSlots[idx].gainRight = gain * rightWeight
            runtimeSlots[idx].airPole = min(max(0.12 + 0.024 * pathLen, 0.10), 0.86)
        }
    }

    /// Zero-allocation parameter check & update safe for the real-time audio render thread.
    @inline(__always)
    public mutating func updateParametersIfNeeded(
        preset: ShoeboxRoomPreset,
        sourcePose: BinauralSourcePose,
        headQuaternion: SIMD4<Float>
    ) {
        let presetChanged = (preset != activePreset)
        let poseChanged = sourcePose.angularSeparationDegrees(from: activeSourcePose) > 1.5 ||
            abs(sourcePose.distanceMeters - activeSourcePose.distanceMeters) > 0.05
        let quatDelta = simd_length_squared(headQuaternion - activeHeadQuaternion)
        guard presetChanged || poseChanged || quatDelta > 1.0e-4 else { return }

        activePreset = preset
        activeSourcePose = sourcePose
        activeHeadQuaternion = headQuaternion
        recomputeRuntimeSlots(
            configuration: preset.configuration,
            sourcePose: sourcePose,
            headQuaternion: headQuaternion
        )
    }

    @inline(__always)
    private func readFractionalEarlyDelay(_ delaySamples: Float, writeHead: Int) -> Float {
        let intPart = Int(delaySamples)
        let frac = delaySamples - Float(intPart)
        let idx0 = (writeHead - intPart) & Self.earlyDelayMask
        let idx1 = (idx0 - 1) & Self.earlyDelayMask
        let s0 = earlyDelayBuffer[idx0]
        let s1 = earlyDelayBuffer[idx1]
        return s0 + frac * (s1 - s0)
    }

    /// Renders all 18 directional 3D early image-source reflections with air-absorption LP damping
    /// and feeds them into the 8-channel Sylvester-Hadamard FDN late reverberator with zero allocations.
    public mutating func processAndAccumulate(
        monoSource: UnsafePointer<Float>,
        leftInOut: UnsafeMutablePointer<Float>,
        rightInOut: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let config = activePreset.configuration
        guard config.earlyReflectionLevel > 0.001 || config.lateFDNWetMix > 0.001 else {
            return
        }

        let fdnWet = config.lateFDNWetMix
        let safeRT60 = max(0.10, config.rt60Seconds)
        let feedback = min(max(powf(10.0, (-3.0 * fdnMeanDelaySeconds) / safeRT60), 0.02), 0.965)
        let normHadamard: Float = 0.3535533906 * feedback // (1 / sqrt(8)) * feedback
        let fdnDamp: Float = 0.30
        let oneMinusFDNDamp: Float = 1.0 - fdnDamp
        let lineCap = Self.fdnLineCapacity
        let lineMask = Self.fdnLineMask

        for i in 0..<frameCount {
            let x = monoSource[i]
            let wh = earlyWriteHead
            earlyDelayBuffer[wh] = x

            var earlySumL: Float = 0.0
            var earlySumR: Float = 0.0

            for m in 0..<Self.totalImageSourceCount {
                let rawL = readFractionalEarlyDelay(runtimeSlots[m].delaySamplesLeft, writeHead: wh)
                let rawR = readFractionalEarlyDelay(runtimeSlots[m].delaySamplesRight, writeHead: wh)
                let pole = runtimeSlots[m].airPole
                let oneMinusPole = 1.0 - pole

                let lpL = oneMinusPole * rawL + pole * runtimeSlots[m].lpStateLeft
                let lpR = oneMinusPole * rawR + pole * runtimeSlots[m].lpStateRight
                runtimeSlots[m].lpStateLeft = lpL
                runtimeSlots[m].lpStateRight = lpR

                earlySumL += lpL * runtimeSlots[m].gainLeft
                earlySumR += lpR * runtimeSlots[m].gainRight
            }

            earlyWriteHead = (wh + 1) & Self.earlyDelayMask

            var lateL: Float = 0.0
            var lateR: Float = 0.0

            if fdnWet > 0.0005 {
                let r0 = (fdnWriteHeads.0 - fdnDelayLengths.0) & lineMask
                let r1 = (fdnWriteHeads.1 - fdnDelayLengths.1) & lineMask
                let r2 = (fdnWriteHeads.2 - fdnDelayLengths.2) & lineMask
                let r3 = (fdnWriteHeads.3 - fdnDelayLengths.3) & lineMask
                let r4 = (fdnWriteHeads.4 - fdnDelayLengths.4) & lineMask
                let r5 = (fdnWriteHeads.5 - fdnDelayLengths.5) & lineMask
                let r6 = (fdnWriteHeads.6 - fdnDelayLengths.6) & lineMask
                let r7 = (fdnWriteHeads.7 - fdnDelayLengths.7) & lineMask

                let d0 = oneMinusFDNDamp * fdnBuffer[0 * lineCap + r0] + fdnDamp * fdnDampStates.0
                let d1 = oneMinusFDNDamp * fdnBuffer[1 * lineCap + r1] + fdnDamp * fdnDampStates.1
                let d2 = oneMinusFDNDamp * fdnBuffer[2 * lineCap + r2] + fdnDamp * fdnDampStates.2
                let d3 = oneMinusFDNDamp * fdnBuffer[3 * lineCap + r3] + fdnDamp * fdnDampStates.3
                let d4 = oneMinusFDNDamp * fdnBuffer[4 * lineCap + r4] + fdnDamp * fdnDampStates.4
                let d5 = oneMinusFDNDamp * fdnBuffer[5 * lineCap + r5] + fdnDamp * fdnDampStates.5
                let d6 = oneMinusFDNDamp * fdnBuffer[6 * lineCap + r6] + fdnDamp * fdnDampStates.6
                let d7 = oneMinusFDNDamp * fdnBuffer[7 * lineCap + r7] + fdnDamp * fdnDampStates.7
                fdnDampStates = (d0, d1, d2, d3, d4, d5, d6, d7)

                // Fast 8x8 Walsh-Hadamard butterfly
                let a0 = d0 + d1; let a1 = d0 - d1
                let a2 = d2 + d3; let a3 = d2 - d3
                let a4 = d4 + d5; let a5 = d4 - d5
                let a6 = d6 + d7; let a7 = d6 - d7

                let b0 = a0 + a2; let b1 = a1 + a3
                let b2 = a0 - a2; let b3 = a1 - a3
                let b4 = a4 + a6; let b5 = a5 + a7
                let b6 = a4 - a6; let b7 = a5 - a7

                // Early reflections + gentle diffused direct feed excite the 8-channel FDN
                let fdnInL = (earlySumL + x * 0.14) * 0.24
                let fdnInR = (earlySumR + x * 0.14) * 0.24

                fdnBuffer[0 * lineCap + fdnWriteHeads.0] = (b0 + b4) * normHadamard + fdnInL
                fdnBuffer[1 * lineCap + fdnWriteHeads.1] = (b1 + b5) * normHadamard + fdnInR
                fdnBuffer[2 * lineCap + fdnWriteHeads.2] = (b2 + b6) * normHadamard + fdnInL
                fdnBuffer[3 * lineCap + fdnWriteHeads.3] = (b3 + b7) * normHadamard - fdnInR
                fdnBuffer[4 * lineCap + fdnWriteHeads.4] = (b0 - b4) * normHadamard - fdnInL
                fdnBuffer[5 * lineCap + fdnWriteHeads.5] = (b1 - b5) * normHadamard + fdnInR
                fdnBuffer[6 * lineCap + fdnWriteHeads.6] = (b2 - b6) * normHadamard + fdnInL
                fdnBuffer[7 * lineCap + fdnWriteHeads.7] = (b3 - b7) * normHadamard + fdnInR

                fdnWriteHeads = (
                    (fdnWriteHeads.0 + 1) & lineMask,
                    (fdnWriteHeads.1 + 1) & lineMask,
                    (fdnWriteHeads.2 + 1) & lineMask,
                    (fdnWriteHeads.3 + 1) & lineMask,
                    (fdnWriteHeads.4 + 1) & lineMask,
                    (fdnWriteHeads.5 + 1) & lineMask,
                    (fdnWriteHeads.6 + 1) & lineMask,
                    (fdnWriteHeads.7 + 1) & lineMask
                )

                lateL = (d0 + d2 + d4 + d6) * 0.36 * fdnWet
                lateR = (d1 + d3 + d5 + d7) * 0.36 * fdnWet
            }

            leftInOut[i] += earlySumL + lateL
            rightInOut[i] += earlySumR + lateR
        }
    }
}

// MARK: - 4. Multi-Source Orbital Habit Spatializer (Lock-Free Value Bank + Binaural Overtone Engine)

public struct OrbitalSatelliteVoice: Sendable, Equatable {
    public var azimuthRadians: Float
    public var elevationRadians: Float
    public var distanceMeters: Float
    public var angularVelocityRadPerSec: Float
    public var harmonicRatio: Float
    public var amplitude: Float

    public init(
        azimuthRadians: Float = 0.0,
        elevationRadians: Float = 0.0,
        distanceMeters: Float = 1.6,
        angularVelocityRadPerSec: Float = 0.32,
        harmonicRatio: Float = 1.5,
        amplitude: Float = 0.0
    ) {
        self.azimuthRadians = KEMARHRIRSynthesizer.wrapAngleToPi(azimuthRadians)
        self.elevationRadians = min(max(elevationRadians, -Float.pi * 0.35), Float.pi * 0.45)
        self.distanceMeters = min(max(distanceMeters, 0.4), 6.0)
        self.angularVelocityRadPerSec = angularVelocityRadPerSec
        self.harmonicRatio = min(max(harmonicRatio, 0.5), 6.0)
        self.amplitude = min(max(amplitude, 0.0), 0.5)
    }
}

/// Fixed-capacity inline value bank (0 heap allocations / 0 ARC retains when copied across RealtimeAudioBridge).
public struct OrbitalSatelliteBank: Sendable, Equatable {
    public static let maxVoices: Int = 6
    private static let harmonicSeries: (Float, Float, Float, Float, Float, Float) = (
        1.5, 2.0, 2.25, 2.5, 3.0, 3.375
    )

    public var activeCount: Int
    public var voices: (
        OrbitalSatelliteVoice,
        OrbitalSatelliteVoice,
        OrbitalSatelliteVoice,
        OrbitalSatelliteVoice,
        OrbitalSatelliteVoice,
        OrbitalSatelliteVoice
    )

    public init() {
        let idle = OrbitalSatelliteVoice()
        self.activeCount = 0
        self.voices = (idle, idle, idle, idle, idle, idle)
    }

    @inline(__always)
    public subscript(index: Int) -> OrbitalSatelliteVoice {
        get {
            switch index {
            case 0: return voices.0
            case 1: return voices.1
            case 2: return voices.2
            case 3: return voices.3
            case 4: return voices.4
            case 5: return voices.5
            default: return OrbitalSatelliteVoice()
            }
        }
        set {
            switch index {
            case 0: voices.0 = newValue
            case 1: voices.1 = newValue
            case 2: voices.2 = newValue
            case 3: voices.3 = newValue
            case 4: voices.4 = newValue
            case 5: voices.5 = newValue
            default: break
            }
        }
    }

    public static func build(
        from habits: [HabitNodeDTO],
        rotationRadians: Double,
        orbitalSpeedRadPerSec: Float
    ) -> OrbitalSatelliteBank {
        var bank = OrbitalSatelliteBank()
        let count = min(Self.maxVoices, habits.count)
        guard count > 0 else { return bank }

        bank.activeCount = count
        let ratios = [
            harmonicSeries.0, harmonicSeries.1, harmonicSeries.2,
            harmonicSeries.3, harmonicSeries.4, harmonicSeries.5
        ]
        let invCount = 1.0 / Double(count)

        for idx in 0..<count {
            let habit = habits[idx]
            let baseAngle = Double(idx) * 2.0 * Double.pi * invCount + rotationRadians
            let az = KEMARHRIRSynthesizer.wrapAngleToPi(Float(baseAngle))
            let el = Float(0.32 * sin(baseAngle * 1.5 + Double(idx) * 0.7))
            let massFactor = Float(min(max(habit.orbitalMass, 0.5), 2.4))
            let dist = min(max(1.25 + 0.35 * Float(idx % 3) + (2.0 - massFactor) * 0.25, 0.8), 3.6)
            let completionRatio = Float(min(1.0, Double(habit.completedMinutesToday) / Double(max(1, habit.targetMinutesPerDay))))
            let amp = (0.045 + 0.030 * completionRatio) * min(1.3, massFactor * 0.75)
            let speedSign: Float = (idx % 2 == 0) ? 1.0 : 0.78

            bank[idx] = OrbitalSatelliteVoice(
                azimuthRadians: az,
                elevationRadians: el,
                distanceMeters: dist,
                angularVelocityRadPerSec: orbitalSpeedRadPerSec * speedSign,
                harmonicRatio: ratios[idx],
                amplitude: amp
            )
        }

        return bank
    }
}

public struct OrbitalHabitSpatializer: Sendable {
    private static let itdBufferCapacity: Int = 128
    private static let itdBufferMask: Int = 127

    public let sampleRate: Double
    private let invSampleRate: Double
    private let twoPi: Double = .pi * 2.0

    // Pre-allocated oscillator phases, orbital angles, ITD fractional delay lines & head-shadow LP states
    private var oscPhases: (Double, Double, Double, Double, Double, Double) = (0.0, 0.13, 0.29, 0.47, 0.63, 0.81)
    private var orbitPhases: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)
    private var initializedPhases: Bool = false
    private var delayBuffer: [Float]
    private var writeHead: Int = 0
    private var shadowStateL: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)
    private var shadowStateR: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)

    public init(sampleRate: Double = 48_000.0) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.invSampleRate = 1.0 / safeRate
        self.delayBuffer = [Float](repeating: 0.0, count: OrbitalSatelliteBank.maxVoices * Self.itdBufferCapacity)
    }

    public mutating func reset() {
        for i in 0..<delayBuffer.count { delayBuffer[i] = 0.0 }
        writeHead = 0
        initializedPhases = false
        shadowStateL = (0, 0, 0, 0, 0, 0)
        shadowStateR = (0, 0, 0, 0, 0, 0)
    }

    @inline(__always)
    private func getOscPhase(_ idx: Int) -> Double {
        switch idx {
        case 0: return oscPhases.0
        case 1: return oscPhases.1
        case 2: return oscPhases.2
        case 3: return oscPhases.3
        case 4: return oscPhases.4
        default: return oscPhases.5
        }
    }

    @inline(__always)
    private mutating func setOscPhase(_ idx: Int, _ val: Double) {
        switch idx {
        case 0: oscPhases.0 = val
        case 1: oscPhases.1 = val
        case 2: oscPhases.2 = val
        case 3: oscPhases.3 = val
        case 4: oscPhases.4 = val
        default: oscPhases.5 = val
        }
    }

    @inline(__always)
    private func getOrbitPhase(_ idx: Int) -> Float {
        switch idx {
        case 0: return orbitPhases.0
        case 1: return orbitPhases.1
        case 2: return orbitPhases.2
        case 3: return orbitPhases.3
        case 4: return orbitPhases.4
        default: return orbitPhases.5
        }
    }

    @inline(__always)
    private mutating func setOrbitPhase(_ idx: Int, _ val: Float) {
        switch idx {
        case 0: orbitPhases.0 = val
        case 1: orbitPhases.1 = val
        case 2: orbitPhases.2 = val
        case 3: orbitPhases.3 = val
        case 4: orbitPhases.4 = val
        default: orbitPhases.5 = val
        }
    }

    @inline(__always)
    private mutating func stepShadowFilter(voice: Int, isLeft: Bool, input: Float, pole: Float) -> Float {
        let oneMinus = 1.0 - pole
        if isLeft {
            switch voice {
            case 0: shadowStateL.0 = oneMinus * input + pole * shadowStateL.0; return shadowStateL.0
            case 1: shadowStateL.1 = oneMinus * input + pole * shadowStateL.1; return shadowStateL.1
            case 2: shadowStateL.2 = oneMinus * input + pole * shadowStateL.2; return shadowStateL.2
            case 3: shadowStateL.3 = oneMinus * input + pole * shadowStateL.3; return shadowStateL.3
            case 4: shadowStateL.4 = oneMinus * input + pole * shadowStateL.4; return shadowStateL.4
            default: shadowStateL.5 = oneMinus * input + pole * shadowStateL.5; return shadowStateL.5
            }
        } else {
            switch voice {
            case 0: shadowStateR.0 = oneMinus * input + pole * shadowStateR.0; return shadowStateR.0
            case 1: shadowStateR.1 = oneMinus * input + pole * shadowStateR.1; return shadowStateR.1
            case 2: shadowStateR.2 = oneMinus * input + pole * shadowStateR.2; return shadowStateR.2
            case 3: shadowStateR.3 = oneMinus * input + pole * shadowStateR.3; return shadowStateR.3
            case 4: shadowStateR.4 = oneMinus * input + pole * shadowStateR.4; return shadowStateR.4
            default: shadowStateR.5 = oneMinus * input + pole * shadowStateR.5; return shadowStateR.5
            }
        }
    }

    /// Synthesizes harmonic overtones for active orbiting `HabitNode` satellites and spatializes them
    /// in 3D binaural space around the listener's head orientation with zero heap allocations.
    public mutating func renderSatellites(
        bank: OrbitalSatelliteBank,
        carrierFrequencyHz: Float,
        padMix: Float,
        headYawRadians: Float,
        headPitchRadians: Float,
        leftInOut: UnsafeMutablePointer<Float>,
        rightInOut: UnsafeMutablePointer<Float>,
        monoRoomSendInOut: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let count = min(OrbitalSatelliteBank.maxVoices, bank.activeCount)
        guard count > 0 && padMix > 0.001 && frameCount > 0 else { return }

        if !initializedPhases {
            for v in 0..<count {
                setOrbitPhase(v, bank[v].azimuthRadians)
            }
            initializedPhases = true
        } else {
            // Gently slew internal orbital phase toward coordinator's authoritative satellite angle
            for v in 0..<count {
                let err = KEMARHRIRSynthesizer.wrapAngleToPi(bank[v].azimuthRadians - getOrbitPhase(v))
                setOrbitPhase(v, KEMARHRIRSynthesizer.wrapAngleToPi(getOrbitPhase(v) + err * 0.15))
            }
        }

        let dt = Float(invSampleRate)
        let fs = Float(sampleRate)
        let baseCarrier = Double(max(60.0, carrierFrequencyHz))

        for i in 0..<frameCount {
            let wh = writeHead
            var sumL: Float = 0.0
            var sumR: Float = 0.0
            var roomSend: Float = 0.0

            for v in 0..<count {
                let voice = bank[v]
                let oscFreq = min(sampleRate * 0.42, baseCarrier * Double(voice.harmonicRatio))
                var phase = getOscPhase(v)
                let harmonicWave = Float(sin(twoPi * phase) + 0.28 * sin(twoPi * phase * 2.0))
                phase += oscFreq * invSampleRate
                if phase >= 1.0 { phase -= phase.rounded(.down) }
                setOscPhase(v, phase)

                let orbAz = KEMARHRIRSynthesizer.wrapAngleToPi(getOrbitPhase(v) + voice.angularVelocityRadPerSec * dt)
                setOrbitPhase(v, orbAz)

                let relAz = KEMARHRIRSynthesizer.wrapAngleToPi(orbAz - headYawRadians)
                let relEl = min(max(voice.elevationRadians - headPitchRadians, -Float.pi * 0.45), Float.pi * 0.45)

                let distAtten = 1.0 / max(0.6, voice.distanceMeters)
                let drySample = harmonicWave * voice.amplitude * padMix * distAtten

                let baseIdx = v * Self.itdBufferCapacity
                delayBuffer[baseIdx + wh] = drySample

                let itdSec = KEMARHRIRSynthesizer.computeWoodworthITD(
                    azimuthRadians: relAz,
                    elevationRadians: relEl
                )
                let delaySamplesL = min(max(2.0 + (itdSec >= 0.0 ? itdSec * fs : 0.0), 1.0), Float(Self.itdBufferCapacity - 4))
                let delaySamplesR = min(max(2.0 + (itdSec < 0.0 ? -itdSec * fs : 0.0), 1.0), Float(Self.itdBufferCapacity - 4))

                let intL = Int(delaySamplesL)
                let fracL = delaySamplesL - Float(intL)
                let rL0 = (wh - intL) & Self.itdBufferMask
                let rL1 = (rL0 - 1) & Self.itdBufferMask
                let delayedL = delayBuffer[baseIdx + rL0] + fracL * (delayBuffer[baseIdx + rL1] - delayBuffer[baseIdx + rL0])

                let intR = Int(delaySamplesR)
                let fracR = delaySamplesR - Float(intR)
                let rR0 = (wh - intR) & Self.itdBufferMask
                let rR1 = (rR0 - 1) & Self.itdBufferMask
                let delayedR = delayBuffer[baseIdx + rR0] + fracR * (delayBuffer[baseIdx + rR1] - delayBuffer[baseIdx + rR0])

                // Contralateral head-shadowing ILD + one-pole HF roll-off
                let lateral = cosf(relEl) * sinf(relAz)
                let gainL = 0.62 - 0.38 * lateral
                let gainR = 0.62 + 0.38 * lateral
                let poleL = 0.15 + 0.45 * max(0.0, lateral)
                let poleR = 0.15 + 0.45 * max(0.0, -lateral)

                sumL += stepShadowFilter(voice: v, isLeft: true, input: delayedL * gainL, pole: poleL)
                sumR += stepShadowFilter(voice: v, isLeft: false, input: delayedR * gainR, pole: poleR)
                roomSend += drySample * 0.45
            }

            writeHead = (wh + 1) & Self.itdBufferMask
            leftInOut[i] += sumL
            rightInOut[i] += sumR
            monoRoomSendInOut[i] += roomSend
        }
    }
}
