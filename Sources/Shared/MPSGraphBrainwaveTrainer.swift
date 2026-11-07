// MARK: - FILE: MPSGraphBrainwaveTrainer.swift

import Foundation
import simd
#if canImport(Metal) && canImport(MetalPerformanceShaders) && canImport(MetalPerformanceShadersGraph) && !os(watchOS)
import Metal
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

private extension MPSGraph {
    /// Bridges Objective-C `-[MPSGraph gradientForPrimaryTensor:withTensors:name:]` alongside Swift's `gradients(of:with:name:)`.
    func gradient(
        forPrimaryTensor primaryTensor: MPSGraphTensor,
        with tensors: [MPSGraphTensor],
        name: String?
    ) -> [MPSGraphTensor: MPSGraphTensor] {
        gradients(of: primaryTensor, with: tensors, name: name)
    }
}
#endif

// MARK: - 1. Compute Backend, Telemetry, Prediction & Checkpoint Models

public enum NeuralComputeBackend: String, Codable, Sendable, Equatable {
    case mpsGraphGPU
    case cpuSIMDFallback

    public var displayTitle: String {
        switch self {
        case .mpsGraphGPU:
            return "MPSGraph Metal GPU"
        case .cpuSIMDFallback:
            return "SIMD CPU"
        }
    }
}

public struct TrainingTelemetrySnapshot: Codable, Sendable, Equatable {
    public let epochCount: Int
    public let latestLoss: Float
    public let emaLoss: Float
    public let gradientL2Norm: Float
    public let gpuExecutionTimeMicroseconds: Double
    public let activeBackend: NeuralComputeBackend

    public init(
        epochCount: Int = 0,
        latestLoss: Float = 0.0,
        emaLoss: Float = 0.0,
        gradientL2Norm: Float = 0.0,
        gpuExecutionTimeMicroseconds: Double = 0.0,
        activeBackend: NeuralComputeBackend = .cpuSIMDFallback
    ) {
        self.epochCount = max(0, epochCount)
        self.latestLoss = latestLoss.isFinite ? max(0.0, latestLoss) : 0.0
        self.emaLoss = emaLoss.isFinite ? max(0.0, emaLoss) : 0.0
        self.gradientL2Norm = gradientL2Norm.isFinite ? max(0.0, gradientL2Norm) : 0.0
        self.gpuExecutionTimeMicroseconds = gpuExecutionTimeMicroseconds.isFinite ? max(0.0, gpuExecutionTimeMicroseconds) : 0.0
        self.activeBackend = activeBackend
    }
}

public struct BrainwavePrediction: Codable, Sendable, Equatable {
    public static let binauralBeatRange: ClosedRange<Float> = 1.5...42.0
    public static let carrierRange: ClosedRange<Float> = 110.0...432.0
    public static let filterCutoffRange: ClosedRange<Float> = 220.0...6_000.0
    public static let hrtfOrbitSpeedRange: ClosedRange<Float> = 0.05...1.50
    public static let coherenceRange: ClosedRange<Float> = 0.0...1.0

    public let binauralBeatHz: Float
    public let carrierHz: Float
    public let filterCutoffHz: Float
    public let hrtfOrbitSpeed: Float
    public let targetCoherence: Float
    public let normalizedActivations: [Float]

    public init(normalizedActivations raw: [Float]) {
        let u0 = min(max(raw.count > 0 && raw[0].isFinite ? raw[0] : 0.25, 0.0), 1.0)
        let u1 = min(max(raw.count > 1 && raw[1].isFinite ? raw[1] : 0.35, 0.0), 1.0)
        let u2 = min(max(raw.count > 2 && raw[2].isFinite ? raw[2] : 0.30, 0.0), 1.0)
        let u3 = min(max(raw.count > 3 && raw[3].isFinite ? raw[3] : 0.25, 0.0), 1.0)
        let u4 = min(max(raw.count > 4 && raw[4].isFinite ? raw[4] : 0.75, 0.0), 1.0)

        self.normalizedActivations = [u0, u1, u2, u3, u4]
        self.binauralBeatHz = 1.5 + u0 * (42.0 - 1.5)
        self.carrierHz = 110.0 + u1 * (432.0 - 110.0)
        self.filterCutoffHz = 220.0 + u2 * (6_000.0 - 220.0)
        self.hrtfOrbitSpeed = 0.05 + u3 * (1.50 - 0.05)
        self.targetCoherence = u4
    }
}

public struct BiometricTrainingBatch: Codable, Sendable, Equatable {
    public let batchSize: Int
    public let inputs: [Float]                  // Shape [Batch, T = 8, D = 12]
    public let targets: [Float]                 // Shape [Batch, 5] normalized in [0, 1]
    public let coherenceRewards: [Float]        // Shape [Batch] autonomic RSA coherence target in [0, 1]

    public init(
        batchSize: Int,
        inputs: [Float],
        targets: [Float],
        coherenceRewards: [Float]? = nil
    ) {
        let safeBatch = max(1, batchSize)
        self.batchSize = safeBatch
        let expectedIn = safeBatch * 8 * 12
        let expectedOut = safeBatch * 5

        if inputs.count == expectedIn {
            self.inputs = inputs.map { $0.isFinite ? $0 : 0.0 }
        } else {
            var padded = [Float](repeating: 0.0, count: expectedIn)
            for i in 0..<min(inputs.count, expectedIn) {
                padded[i] = inputs[i].isFinite ? inputs[i] : 0.0
            }
            self.inputs = padded
        }

        if targets.count == expectedOut {
            self.targets = targets.map { $0.isFinite ? min(max($0, 0.0), 1.0) : 0.5 }
        } else {
            var padded = [Float](repeating: 0.5, count: expectedOut)
            for i in 0..<min(targets.count, expectedOut) {
                padded[i] = targets[i].isFinite ? min(max(targets[i], 0.0), 1.0) : 0.5
            }
            self.targets = padded
        }

        if let rewards = coherenceRewards, rewards.count == safeBatch {
            self.coherenceRewards = rewards.map { $0.isFinite ? min(max($0, 0.0), 1.0) : 0.75 }
        } else {
            var extracted = [Float](repeating: 0.75, count: safeBatch)
            for b in 0..<safeBatch {
                let idx = b * 5 + 4
                if idx < self.targets.count {
                    extracted[b] = self.targets[idx]
                }
            }
            self.coherenceRewards = extracted
        }
    }

    /// Generates a deterministic 8-step autonomic HRV, Lomb-Scargle LF/HF & RSA coherence trajectory dataset.
    public static func makeSyntheticBiometricDataset(
        batchSize: Int = 8,
        seed: UInt64 = 0xAE74_0006_2026
    ) -> BiometricTrainingBatch {
        let bCount = max(1, batchSize)
        let tSteps = 8
        let fDim = 12
        var rng = seed == 0 ? 0xAE74_0006_2026 : seed

        func nextUnit() -> Float {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return Float(z >> 40) * (1.0 / 16_777_216.0)
        }

        var flatX = [Float](repeating: 0.0, count: bCount * tSteps * fDim)
        var flatY = [Float](repeating: 0.0, count: bCount * 5)
        var rewards = [Float](repeating: 0.0, count: bCount)

        for b in 0..<bCount {
            let archetype = Float(b % 4) / 3.0 // 0 = high stress beta -> theta calm, 1 = high coherence alpha/gamma
            let baseStress = min(max(0.78 - 0.56 * archetype + (nextUnit() - 0.5) * 0.08, 0.08), 0.92)
            let baseRMSSD = min(max(0.22 + 0.60 * archetype + (nextUnit() - 0.5) * 0.06, 0.10), 0.92)
            let baseCoherence = min(max(0.30 + 0.58 * archetype + (nextUnit() - 0.5) * 0.05, 0.12), 0.96)
            let circadianAngle = Float(b) * 0.65

            for t in 0..<tSteps {
                let progress = Float(t) / Float(tSteps - 1)
                let baseIdx = (b * tSteps + t) * fDim
                let hrNorm = min(max(0.68 - 0.25 * archetype - 0.08 * progress, 0.05), 0.95)
                let rmssdNorm = min(max(baseRMSSD + 0.10 * progress, 0.05), 0.98)
                let sdnnNorm = min(max(rmssdNorm * 0.92 + 0.04, 0.05), 0.98)
                let lfHfNorm = min(max(baseStress * 0.85 - 0.10 * progress, 0.05), 0.95)
                let rsaCoh = min(max(baseCoherence + 0.09 * progress, 0.05), 0.99)
                let stressSI = min(max(baseStress - 0.12 * progress, 0.04), 0.95)
                let respNorm = min(max(0.32 + 0.22 * baseStress, 0.10), 0.85)
                let cSin = sinf(circadianAngle) * 0.5 + 0.5
                let cCos = cosf(circadianAngle) * 0.5 + 0.5
                let beatState = min(max(0.20 + 0.45 * archetype, 0.05), 0.90)
                let cutoffState = min(max(0.22 + 0.38 * rsaCoh, 0.05), 0.90)

                flatX[baseIdx + 0] = hrNorm
                flatX[baseIdx + 1] = rmssdNorm
                flatX[baseIdx + 2] = sdnnNorm
                flatX[baseIdx + 3] = lfHfNorm
                flatX[baseIdx + 4] = rsaCoh
                flatX[baseIdx + 5] = stressSI
                flatX[baseIdx + 6] = respNorm
                flatX[baseIdx + 7] = cSin
                flatX[baseIdx + 8] = cCos
                flatX[baseIdx + 9] = beatState
                flatX[baseIdx + 10] = cutoffState
                flatX[baseIdx + 11] = progress
            }

            // Optimal acoustic entrainment target in normalized [0, 1]^5 space
            let targetBeat = min(max(0.14 + 0.36 * archetype - 0.10 * baseStress, 0.08), 0.78)
            let targetCarrier = min(max(0.28 + 0.32 * baseRMSSD, 0.12), 0.82)
            let targetCutoff = min(max(0.20 + 0.46 * baseCoherence - 0.12 * baseStress, 0.10), 0.85)
            let targetOrbit = min(max(0.16 + 0.34 * archetype, 0.08), 0.76)
            let targetCoh = min(max(0.52 + 0.40 * baseCoherence, 0.25), 0.95)

            let outIdx = b * 5
            flatY[outIdx + 0] = targetBeat
            flatY[outIdx + 1] = targetCarrier
            flatY[outIdx + 2] = targetCutoff
            flatY[outIdx + 3] = targetOrbit
            flatY[outIdx + 4] = targetCoh
            rewards[b] = targetCoh
        }

        return BiometricTrainingBatch(
            batchSize: bCount,
            inputs: flatX,
            targets: flatY,
            coherenceRewards: rewards
        )
    }
}

public struct BrainwaveModelWeights: Codable, Sendable, Equatable {
    public var wQ: [Float]      // [12, 32] = 384
    public var bQ: [Float]      // [32]
    public var wK: [Float]      // [12, 32] = 384
    public var bK: [Float]      // [32]
    public var wV: [Float]      // [12, 32] = 384
    public var bV: [Float]      // [32]
    public var wMLP: [Float]    // [32, 32] = 1024
    public var bMLP: [Float]    // [32]
    public var wOut: [Float]    // [32, 5]  = 160
    public var bOut: [Float]    // [5]

    public static func makeZeros() -> BrainwaveModelWeights {
        BrainwaveModelWeights(
            wQ: [Float](repeating: 0.0, count: 12 * 32),
            bQ: [Float](repeating: 0.0, count: 32),
            wK: [Float](repeating: 0.0, count: 12 * 32),
            bK: [Float](repeating: 0.0, count: 32),
            wV: [Float](repeating: 0.0, count: 12 * 32),
            bV: [Float](repeating: 0.0, count: 32),
            wMLP: [Float](repeating: 0.0, count: 32 * 32),
            bMLP: [Float](repeating: 0.0, count: 32),
            wOut: [Float](repeating: 0.0, count: 32 * 5),
            bOut: [Float](repeating: 0.0, count: 5)
        )
    }

    public static func makeGlorotSeeded(seed: UInt64 = 0xAE74_2200_2026) -> BrainwaveModelWeights {
        var rng = seed == 0 ? 0xAE74_2200_2026 : seed

        func nextUnit() -> Double {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return max(1.0e-9, min(1.0 - 1.0e-9, Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)))
        }

        func nextGaussian(scale: Double) -> Float {
            let u1 = nextUnit()
            let u2 = nextUnit()
            return Float(sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2) * scale)
        }

        let sAttn = sqrt(2.0 / Double(12 + 32))
        let sMLP = sqrt(2.0 / Double(32 + 32))
        let sOut = sqrt(2.0 / Double(32 + 5))

        return BrainwaveModelWeights(
            wQ: (0..<(12 * 32)).map { _ in nextGaussian(scale: sAttn) },
            bQ: [Float](repeating: 0.0, count: 32),
            wK: (0..<(12 * 32)).map { _ in nextGaussian(scale: sAttn) },
            bK: [Float](repeating: 0.0, count: 32),
            wV: (0..<(12 * 32)).map { _ in nextGaussian(scale: sAttn) },
            bV: [Float](repeating: 0.0, count: 32),
            wMLP: (0..<(32 * 32)).map { _ in nextGaussian(scale: sMLP) },
            bMLP: [Float](repeating: 0.0, count: 32),
            wOut: (0..<(32 * 5)).map { _ in nextGaussian(scale: sOut) },
            bOut: [0.35, -0.45, 0.30, -0.40, -0.35]
        )
    }
}

public struct BrainwaveModelCheckpoint: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let savedAt: Date
    public let weights: BrainwaveModelWeights
    public let firstMoments: BrainwaveModelWeights
    public let secondMoments: BrainwaveModelWeights
    public let telemetry: TrainingTelemetrySnapshot

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        savedAt: Date = .now,
        weights: BrainwaveModelWeights,
        firstMoments: BrainwaveModelWeights,
        secondMoments: BrainwaveModelWeights,
        telemetry: TrainingTelemetrySnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.weights = weights
        self.firstMoments = firstMoments
        self.secondMoments = secondMoments
        self.telemetry = telemetry
    }
}

// MARK: - 2. GPU MPSGraph + Deterministic SIMD CPU Temporal Self-Attention & Autodiff Trainer Actor

public actor MPSGraphBrainwaveTrainer {
    public static let sequenceLength: Int = 8
    public static let featureDim: Int = 12
    public static let hiddenDim: Int = 32
    public static let outputDim: Int = 5

    public static let huberDelta: Float = 0.20
    public static let coherenceRewardWeight: Float = 0.25
    public static let maxGradientL2Norm: Float = 1.0
    public static let adamBeta1: Float = 0.90
    public static let adamBeta2: Float = 0.999
    public static let adamEpsilon: Float = 1.0e-8
    public static let weightDecay: Float = 1.0e-4
    public static let defaultLearningRate: Float = 0.018
    public static let checkpointFilename: String = "MPSGraphBrainwaveTrainer.v1.json"

    private var weights: BrainwaveModelWeights
    private var adamM: BrainwaveModelWeights
    private var adamV: BrainwaveModelWeights
    private var telemetry: TrainingTelemetrySnapshot
    private let preferredBackend: NeuralComputeBackend
    private let customCheckpointURL: URL?

    #if canImport(Metal) && canImport(MetalPerformanceShaders) && canImport(MetalPerformanceShadersGraph) && !os(watchOS)
    private struct CompiledGPUTrainingGraph {
        let batchSize: Int
        let executable: MPSGraphExecutable
        let feedOrder: [MPSGraphTensor]
        let xPH: MPSGraphTensor
        let yPH: MPSGraphTensor
        let rPH: MPSGraphTensor
        let lrPH: MPSGraphTensor
        let b1CorrPH: MPSGraphTensor
        let b2CorrPH: MPSGraphTensor
        let decayFactorPH: MPSGraphTensor
        let weightPHs: [MPSGraphTensor]
        let mPHs: [MPSGraphTensor]
        let vPHs: [MPSGraphTensor]
    }

    private let mtlDevice: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var cachedCompiledGraph: CompiledGPUTrainingGraph?
    #endif

    public init(
        seed: UInt64 = 0xAE74_2200_2026,
        forceCPUFallback: Bool = false,
        customCheckpointURL: URL? = nil
    ) {
        self.weights = BrainwaveModelWeights.makeGlorotSeeded(seed: seed)
        self.adamM = BrainwaveModelWeights.makeZeros()
        self.adamV = BrainwaveModelWeights.makeZeros()
        self.customCheckpointURL = customCheckpointURL

        #if canImport(Metal) && canImport(MetalPerformanceShaders) && canImport(MetalPerformanceShadersGraph) && !os(watchOS)
        if !forceCPUFallback,
           let dev = MTLCreateSystemDefaultDevice(),
           let queue = dev.makeCommandQueue() {
            self.mtlDevice = dev
            self.commandQueue = queue
            self.preferredBackend = .mpsGraphGPU
        } else {
            self.mtlDevice = nil
            self.commandQueue = nil
            self.preferredBackend = .cpuSIMDFallback
        }
        #else
        _ = forceCPUFallback
        self.preferredBackend = .cpuSIMDFallback
        #endif

        self.telemetry = TrainingTelemetrySnapshot(
            epochCount: 0,
            latestLoss: 0.0,
            emaLoss: 0.0,
            gradientL2Norm: 0.0,
            gpuExecutionTimeMicroseconds: 0.0,
            activeBackend: self.preferredBackend
        )
    }

    // MARK: - Telemetry, Inference & Multi-Epoch Training Entrypoints

    public func snapshotTelemetry() -> TrainingTelemetrySnapshot {
        telemetry
    }

    public func currentWeightsSnapshot() -> BrainwaveModelWeights {
        weights
    }

    /// Predicts optimal `[binauralBeatHz, carrierHz, filterCutoffHz, hrtfOrbitSpeed, targetCoherence]`
    /// from a flattened `[T = 8, D = 12]` (96-element) biometric trajectory window.
    public func predictOptimalSetpoint(sequence8x12: [Float]) -> BrainwavePrediction {
        let expected = Self.sequenceLength * Self.featureDim
        var clean = [Float](repeating: 0.0, count: expected)
        for i in 0..<min(sequence8x12.count, expected) {
            clean[i] = sequence8x12[i].isFinite ? sequence8x12[i] : 0.0
        }
        let cache = Self.forwardSingleSequenceSIMD(flatSequence96: clean, weights: weights)
        return BrainwavePrediction(normalizedActivations: cache.outputs)
    }

    @discardableResult
    public func trainEpoch(
        batch: BiometricTrainingBatch,
        learningRate: Float = MPSGraphBrainwaveTrainer.defaultLearningRate
    ) -> TrainingTelemetrySnapshot {
        let lr = min(max(learningRate, 1.0e-5), 0.15)
        let nextStep = telemetry.epochCount + 1
        let startNs = DispatchTime.now().uptimeNanoseconds

        var stepLoss: Float = 0.0
        var clippedGradNorm: Float = 0.0
        var executedBackend: NeuralComputeBackend = .cpuSIMDFallback

        #if canImport(Metal) && canImport(MetalPerformanceShaders) && canImport(MetalPerformanceShadersGraph) && !os(watchOS)
        if preferredBackend == .mpsGraphGPU,
           let dev = mtlDevice,
           let queue = commandQueue,
           let gpuResult = executeMPSGraphTrainingStep(
               device: dev,
               commandQueue: queue,
               batch: batch,
               learningRate: lr,
               stepIndex: nextStep
           ) {
            stepLoss = gpuResult.loss
            clippedGradNorm = gpuResult.clippedGradL2Norm
            executedBackend = .mpsGraphGPU
        } else {
            let cpuResult = Self.executeSIMDCPUAutodiffStep(
                batch: batch,
                learningRate: lr,
                stepIndex: nextStep,
                weights: &weights,
                adamM: &adamM,
                adamV: &adamV
            )
            stepLoss = cpuResult.loss
            clippedGradNorm = cpuResult.clippedGradL2Norm
            executedBackend = .cpuSIMDFallback
        }
        #else
        let cpuResult = Self.executeSIMDCPUAutodiffStep(
            batch: batch,
            learningRate: lr,
            stepIndex: nextStep,
            weights: &weights,
            adamM: &adamM,
            adamV: &adamV
        )
        stepLoss = cpuResult.loss
        clippedGradNorm = cpuResult.clippedGradL2Norm
        executedBackend = .cpuSIMDFallback
        #endif

        let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000.0
        let prevEMA = telemetry.epochCount == 0 ? stepLoss : telemetry.emaLoss
        let nextEMA = 0.82 * prevEMA + 0.18 * stepLoss
        let boundedNorm = min(max(clippedGradNorm, 0.0), Self.maxGradientL2Norm)

        let snap = TrainingTelemetrySnapshot(
            epochCount: nextStep,
            latestLoss: stepLoss,
            emaLoss: nextEMA,
            gradientL2Norm: boundedNorm,
            gpuExecutionTimeMicroseconds: elapsedUs,
            activeBackend: executedBackend
        )
        telemetry = snap
        return snap
    }

    public func trainEpochs(
        batch: BiometricTrainingBatch,
        epochs: Int,
        learningRate: Float = MPSGraphBrainwaveTrainer.defaultLearningRate
    ) -> [TrainingTelemetrySnapshot] {
        let count = max(1, epochs)
        var history: [TrainingTelemetrySnapshot] = []
        history.reserveCapacity(count)
        for _ in 0..<count {
            history.append(trainEpoch(batch: batch, learningRate: learningRate))
        }
        return history
    }

    // MARK: - Checkpoint Serialization & Shared App Group Persistence

    public func exportCheckpointData() throws -> Data {
        let checkpoint = BrainwaveModelCheckpoint(
            savedAt: .now,
            weights: weights,
            firstMoments: adamM,
            secondMoments: adamV,
            telemetry: telemetry
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(checkpoint)
    }

    @discardableResult
    public func importCheckpointData(_ data: Data) throws -> TrainingTelemetrySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BrainwaveModelCheckpoint.self, from: data)
        self.weights = decoded.weights
        self.adamM = decoded.firstMoments
        self.adamV = decoded.secondMoments
        self.telemetry = TrainingTelemetrySnapshot(
            epochCount: decoded.telemetry.epochCount,
            latestLoss: decoded.telemetry.latestLoss,
            emaLoss: decoded.telemetry.emaLoss,
            gradientL2Norm: min(decoded.telemetry.gradientL2Norm, Self.maxGradientL2Norm),
            gpuExecutionTimeMicroseconds: decoded.telemetry.gpuExecutionTimeMicroseconds,
            activeBackend: preferredBackend
        )
        return self.telemetry
    }

    @discardableResult
    public func saveCheckpoint() throws -> URL {
        let targetURL = Self.resolveCheckpointURL(customURL: customCheckpointURL)
        let dir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try exportCheckpointData()
        try data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    @discardableResult
    public func loadCheckpoint() throws -> TrainingTelemetrySnapshot {
        let targetURL = Self.resolveCheckpointURL(customURL: customCheckpointURL)
        let data = try Data(contentsOf: targetURL)
        return try importCheckpointData(data)
    }

    private static func resolveCheckpointURL(customURL: URL?) -> URL {
        if let customURL { return customURL }
        if let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AetherPersistenceSchema.appGroupIdentifier
        ) {
            return groupContainer
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(checkpointFilename)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherSynthNeuralCheckpoints", isDirectory: true)
            .appendingPathComponent(checkpointFilename)
    }

    // MARK: - 3. Compiled MPSGraph GPU Autodiff & In-Graph AdamW Execution

    #if canImport(Metal) && canImport(MetalPerformanceShaders) && canImport(MetalPerformanceShadersGraph) && !os(watchOS)
    private func buildOrFetchCompiledGraph(
        device: MTLDevice,
        batchSize: Int
    ) -> CompiledGPUTrainingGraph? {
        if let existing = cachedCompiledGraph, existing.batchSize == batchSize {
            return existing
        }

        let bNS = NSNumber(value: batchSize)
        let graph = MPSGraph()
        let graphDevice = MPSGraphDevice(mtlDevice: device)

        // Input, target, coherence reward & scalar optimizer schedule placeholders
        let xPH = graph.placeholder(shape: [bNS, 8, 12], dataType: .float32, name: "X_seq")
        let yPH = graph.placeholder(shape: [bNS, 5], dataType: .float32, name: "Y_target")
        let rPH = graph.placeholder(shape: [bNS, 1], dataType: .float32, name: "R_coherence")

        let lrPH = graph.placeholder(shape: [1], dataType: .float32, name: "lr")
        let b1CorrPH = graph.placeholder(shape: [1], dataType: .float32, name: "b1_corr")
        let b2CorrPH = graph.placeholder(shape: [1], dataType: .float32, name: "b2_corr")
        let decayFactorPH = graph.placeholder(shape: [1], dataType: .float32, name: "decay_factor")

        // Trainable weight placeholders
        let wQPH = graph.placeholder(shape: [12, 32], dataType: .float32, name: "wQ")
        let bQPH = graph.placeholder(shape: [1, 1, 32], dataType: .float32, name: "bQ")
        let wKPH = graph.placeholder(shape: [12, 32], dataType: .float32, name: "wK")
        let bKPH = graph.placeholder(shape: [1, 1, 32], dataType: .float32, name: "bK")
        let wVPH = graph.placeholder(shape: [12, 32], dataType: .float32, name: "wV")
        let bVPH = graph.placeholder(shape: [1, 1, 32], dataType: .float32, name: "bV")
        let wMLPPH = graph.placeholder(shape: [32, 32], dataType: .float32, name: "wMLP")
        let bMLPPH = graph.placeholder(shape: [1, 32], dataType: .float32, name: "bMLP")
        let wOutPH = graph.placeholder(shape: [32, 5], dataType: .float32, name: "wOut")
        let bOutPH = graph.placeholder(shape: [1, 5], dataType: .float32, name: "bOut")

        // Layer 1: Single-Head Scaled Dot-Product Temporal Self-Attention [B, 8, 12] -> [B, 32]
        let qTensor = graph.addition(graph.matrixMultiplication(primary: xPH, secondary: wQPH, name: nil), bQPH, name: nil)
        let kTensor = graph.addition(graph.matrixMultiplication(primary: xPH, secondary: wKPH, name: nil), bKPH, name: nil)
        let vTensor = graph.addition(graph.matrixMultiplication(primary: xPH, secondary: wVPH, name: nil), bVPH, name: nil)

        let kTransposed = graph.transposeTensor(kTensor, dimension: 1, withDimension: 2, name: nil)
        let rawScores = graph.matrixMultiplication(primary: qTensor, secondary: kTransposed, name: nil)
        let invSqrtDk = graph.constant(1.0 / Double(Self.hiddenDim).squareRoot(), dataType: .float32)
        let scaledScores = graph.multiplication(rawScores, invSqrtDk, name: nil)
        let attnWeights = graph.softMax(with: scaledScores, axis: 2, name: nil)
        let attnContext = graph.matrixMultiplication(primary: attnWeights, secondary: vTensor, name: nil)

        let pooled3D = graph.mean(of: attnContext, axes: [1], name: nil)
        let pooled = graph.reshape(pooled3D, shape: [bNS, 32], name: nil)

        // Layer 2: Residual MLP (32 -> 32 with tanh) + Sigmoid Readout (32 -> 5)
        let mlpPre = graph.addition(graph.matrixMultiplication(primary: pooled, secondary: wMLPPH, name: nil), bMLPPH, name: nil)
        let mlpAct = graph.tanh(with: mlpPre, name: nil)
        let mlpRes = graph.addition(pooled, mlpAct, name: nil)
        let logits = graph.addition(graph.matrixMultiplication(primary: mlpRes, secondary: wOutPH, name: nil), bOutPH, name: nil)
        let yHat = graph.sigmoid(with: logits, name: "y_hat")

        // Smooth-L1 (Huber, delta = 0.20) + Autonomic Coherence Reward loss
        let deltaConst = graph.constant(Double(Self.huberDelta), dataType: .float32)
        let invTwoDeltaConst = graph.constant(0.5 / Double(Self.huberDelta), dataType: .float32)
        let halfDeltaConst = graph.constant(0.5 * Double(Self.huberDelta), dataType: .float32)

        let diff = graph.subtraction(yHat, yPH, name: nil)
        let absDiff = graph.absolute(with: diff, name: nil)
        let quadBranch = graph.multiplication(graph.multiplication(diff, diff, name: nil), invTwoDeltaConst, name: nil)
        let linBranch = graph.subtraction(absDiff, halfDeltaConst, name: nil)
        let isQuadMask = graph.lessThanOrEqualTo(absDiff, deltaConst, name: nil)
        let smoothL1 = graph.select(predicate: isQuadMask, trueTensor: quadBranch, falseTensor: linBranch, name: nil)
        let meanSmoothL1 = graph.mean(of: smoothL1, axes: [0, 1], name: nil)

        // Slice predicted targetCoherence column [B, 1] at index 4
        let predCoh = graph.sliceTensor(yHat, dimension: 1, start: 4, length: 1, name: nil)
        let cohDiff = graph.subtraction(predCoh, rPH, name: nil)
        let cohSq = graph.multiplication(cohDiff, cohDiff, name: nil)
        let cohWeightConst = graph.constant(Double(Self.coherenceRewardWeight), dataType: .float32)
        let cohPenalty = graph.multiplication(graph.mean(of: cohSq, axes: [0, 1], name: nil), cohWeightConst, name: nil)

        let lossTensor = graph.reshape(
            graph.addition(meanSmoothL1, cohPenalty, name: nil),
            shape: [1],
            name: "total_loss"
        )

        // Reverse-Mode GPU Autodiff via MPSGraph.gradient(forPrimaryTensor:with:name:)
        let trainableWeightTensors: [MPSGraphTensor] = [
            wQPH, bQPH, wKPH, bKPH, wVPH, bVPH, wMLPPH, bMLPPH, wOutPH, bOutPH
        ]
        let gradMap = graph.gradient(
            forPrimaryTensor: lossTensor,
            with: trainableWeightTensors,
            name: "backprop_grads"
        )
        guard trainableWeightTensors.allSatisfy({ gradMap[$0] != nil }) else {
            return nil
        }

        // Global L2 gradient norm & clipping (||grad||_2 <= 1.0)
        var totalSqNorm = graph.constant(1.0e-16, shape: [1], dataType: .float32)
        for paramT in trainableWeightTensors {
            guard let g = gradMap[paramT] else { return nil }
            let rank = paramT.shape?.count ?? 1
            let axes = (0..<rank).map { NSNumber(value: $0) }
            let sumSq = graph.reductionSum(with: graph.multiplication(g, g, name: nil), axes: axes, name: nil)
            totalSqNorm = graph.addition(totalSqNorm, graph.reshape(sumSq, shape: [1], name: nil), name: nil)
        }

        let rawGradNorm = graph.squareRoot(with: totalSqNorm, name: nil)
        let oneConst = graph.constant(1.0, shape: [1], dataType: .float32)
        let maxNormConst = graph.constant(Double(Self.maxGradientL2Norm), shape: [1], dataType: .float32)
        let clipScale = graph.minimum(
            oneConst,
            graph.division(maxNormConst, rawGradNorm, name: nil),
            name: nil
        )
        let clippedGradNorm = graph.minimum(rawGradNorm, maxNormConst, name: "clipped_grad_norm")

        // In-Graph Decoupled AdamW Optimizer Update
        let b1Const = graph.constant(Double(Self.adamBeta1), dataType: .float32)
        let oneMinusB1 = graph.constant(Double(1.0 - Self.adamBeta1), dataType: .float32)
        let b2Const = graph.constant(Double(Self.adamBeta2), dataType: .float32)
        let oneMinusB2 = graph.constant(Double(1.0 - Self.adamBeta2), dataType: .float32)
        let epsConst = graph.constant(Double(Self.adamEpsilon), dataType: .float32)

        let shapes: [[NSNumber]] = [
            [12, 32], [1, 1, 32],
            [12, 32], [1, 1, 32],
            [12, 32], [1, 1, 32],
            [32, 32], [1, 32],
            [32, 5],  [1, 5]
        ]
        let decayFlags: [Bool] = [
            true, false, true, false, true, false, true, false, true, false
        ]

        var mPHs: [MPSGraphTensor] = []
        var vPHs: [MPSGraphTensor] = []
        var nextWeights: [MPSGraphTensor] = []
        var nextMs: [MPSGraphTensor] = []
        var nextVs: [MPSGraphTensor] = []

        for idx in 0..<trainableWeightTensors.count {
            let pPH = trainableWeightTensors[idx]
            guard let rawG = gradMap[pPH] else { return nil }
            let mPH = graph.placeholder(shape: shapes[idx], dataType: .float32, name: "m_\(idx)")
            let vPH = graph.placeholder(shape: shapes[idx], dataType: .float32, name: "v_\(idx)")
            mPHs.append(mPH)
            vPHs.append(vPH)

            let clippedG = graph.multiplication(rawG, clipScale, name: nil)
            let nextM = graph.addition(
                graph.multiplication(mPH, b1Const, name: nil),
                graph.multiplication(clippedG, oneMinusB1, name: nil),
                name: nil
            )
            let gSq = graph.multiplication(clippedG, clippedG, name: nil)
            let nextV = graph.addition(
                graph.multiplication(vPH, b2Const, name: nil),
                graph.multiplication(gSq, oneMinusB2, name: nil),
                name: nil
            )

            let mHat = graph.division(nextM, b1CorrPH, name: nil)
            let vHat = graph.division(nextV, b2CorrPH, name: nil)
            let denom = graph.addition(graph.squareRoot(with: vHat, name: nil), epsConst, name: nil)
            let adamStep = graph.multiplication(lrPH, graph.division(mHat, denom, name: nil), name: nil)
            let decayedParam = decayFlags[idx]
                ? graph.multiplication(pPH, decayFactorPH, name: nil)
                : pPH
            let updatedParam = graph.subtraction(decayedParam, adamStep, name: nil)

            nextWeights.append(updatedParam)
            nextMs.append(nextM)
            nextVs.append(nextV)
        }

        var shapedFeeds: [MPSGraphTensor: MPSGraphShapedType] = [
            xPH: MPSGraphShapedType(shape: [bNS, 8, 12], dataType: .float32),
            yPH: MPSGraphShapedType(shape: [bNS, 5], dataType: .float32),
            rPH: MPSGraphShapedType(shape: [bNS, 1], dataType: .float32),
            lrPH: MPSGraphShapedType(shape: [1], dataType: .float32),
            b1CorrPH: MPSGraphShapedType(shape: [1], dataType: .float32),
            b2CorrPH: MPSGraphShapedType(shape: [1], dataType: .float32),
            decayFactorPH: MPSGraphShapedType(shape: [1], dataType: .float32)
        ]
        for idx in 0..<trainableWeightTensors.count {
            let st = MPSGraphShapedType(shape: shapes[idx], dataType: .float32)
            shapedFeeds[trainableWeightTensors[idx]] = st
            shapedFeeds[mPHs[idx]] = st
            shapedFeeds[vPHs[idx]] = st
        }

        let targetOutputs = [lossTensor, clippedGradNorm] + nextWeights + nextMs + nextVs
        let executable = graph.compile(
            with: graphDevice,
            feeds: shapedFeeds,
            targetTensors: targetOutputs,
            targetOperations: nil,
            compilationDescriptor: nil
        )
        guard let feedOrder = executable.feedTensors, feedOrder.count == shapedFeeds.count else {
            return nil
        }

        let compiled = CompiledGPUTrainingGraph(
            batchSize: batchSize,
            executable: executable,
            feedOrder: feedOrder,
            xPH: xPH,
            yPH: yPH,
            rPH: rPH,
            lrPH: lrPH,
            b1CorrPH: b1CorrPH,
            b2CorrPH: b2CorrPH,
            decayFactorPH: decayFactorPH,
            weightPHs: trainableWeightTensors,
            mPHs: mPHs,
            vPHs: vPHs
        )
        cachedCompiledGraph = compiled
        return compiled
    }

    private func executeMPSGraphTrainingStep(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        batch: BiometricTrainingBatch,
        learningRate: Float,
        stepIndex: Int
    ) -> (loss: Float, clippedGradL2Norm: Float)? {
        guard let compiled = buildOrFetchCompiledGraph(device: device, batchSize: batch.batchSize) else {
            return nil
        }

        let graphDevice = MPSGraphDevice(mtlDevice: device)
        let bNS = NSNumber(value: batch.batchSize)

        func makeTensorData(_ floats: [Float], shape: [NSNumber]) -> MPSGraphTensorData {
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            return MPSGraphTensorData(device: graphDevice, data: data, shape: shape, dataType: .float32)
        }

        let b1Corr = max(1.0e-7, 1.0 - powf(Self.adamBeta1, Float(stepIndex)))
        let b2Corr = max(1.0e-7, 1.0 - powf(Self.adamBeta2, Float(stepIndex)))
        let decayFactor = 1.0 - learningRate * Self.weightDecay

        let shapes: [[NSNumber]] = [
            [12, 32], [1, 1, 32],
            [12, 32], [1, 1, 32],
            [12, 32], [1, 1, 32],
            [32, 32], [1, 32],
            [32, 5],  [1, 5]
        ]
        let wArrays = [
            weights.wQ, weights.bQ, weights.wK, weights.bK, weights.wV, weights.bV,
            weights.wMLP, weights.bMLP, weights.wOut, weights.bOut
        ]
        let mArrays = [
            adamM.wQ, adamM.bQ, adamM.wK, adamM.bK, adamM.wV, adamM.bV,
            adamM.wMLP, adamM.bMLP, adamM.wOut, adamM.bOut
        ]
        let vArrays = [
            adamV.wQ, adamV.bQ, adamV.wK, adamV.bK, adamV.wV, adamV.bV,
            adamV.wMLP, adamV.bMLP, adamV.wOut, adamV.bOut
        ]

        var feedMap: [MPSGraphTensor: MPSGraphTensorData] = [
            compiled.xPH: makeTensorData(batch.inputs, shape: [bNS, 8, 12]),
            compiled.yPH: makeTensorData(batch.targets, shape: [bNS, 5]),
            compiled.rPH: makeTensorData(batch.coherenceRewards, shape: [bNS, 1]),
            compiled.lrPH: makeTensorData([learningRate], shape: [1]),
            compiled.b1CorrPH: makeTensorData([b1Corr], shape: [1]),
            compiled.b2CorrPH: makeTensorData([b2Corr], shape: [1]),
            compiled.decayFactorPH: makeTensorData([decayFactor], shape: [1])
        ]
        for idx in 0..<10 {
            feedMap[compiled.weightPHs[idx]] = makeTensorData(wArrays[idx], shape: shapes[idx])
            feedMap[compiled.mPHs[idx]] = makeTensorData(mArrays[idx], shape: shapes[idx])
            feedMap[compiled.vPHs[idx]] = makeTensorData(vArrays[idx], shape: shapes[idx])
        }

        var orderedInputs: [MPSGraphTensorData] = []
        orderedInputs.reserveCapacity(compiled.feedOrder.count)
        for ph in compiled.feedOrder {
            guard let td = feedMap[ph] else { return nil }
            orderedInputs.append(td)
        }

        let outputs = compiled.executable.run(
            with: commandQueue,
            inputs: orderedInputs,
            results: nil,
            executionDescriptor: nil
        )
        guard outputs.count == 32 else { return nil }

        func readFloats(at outIdx: Int, count: Int) -> [Float] {
            var arr = [Float](repeating: 0.0, count: count)
            arr.withUnsafeMutableBytes { rawBuf in
                if let base = rawBuf.baseAddress {
                    outputs[outIdx].mpsndarray().readBytes(base, strideBytes: nil)
                }
            }
            return arr
        }

        let lossVal = readFloats(at: 0, count: 1).first ?? .nan
        let gradNormVal = readFloats(at: 1, count: 1).first ?? .nan
        guard lossVal.isFinite && gradNormVal.isFinite else { return nil }

        let counts = [384, 32, 384, 32, 384, 32, 1024, 32, 160, 5]
        var nextW: [[Float]] = []
        var nextM: [[Float]] = []
        var nextV: [[Float]] = []
        for idx in 0..<10 {
            nextW.append(readFloats(at: 2 + idx, count: counts[idx]))
            nextM.append(readFloats(at: 12 + idx, count: counts[idx]))
            nextV.append(readFloats(at: 22 + idx, count: counts[idx]))
        }

        weights = BrainwaveModelWeights(
            wQ: nextW[0], bQ: nextW[1], wK: nextW[2], bK: nextW[3], wV: nextW[4], bV: nextW[5],
            wMLP: nextW[6], bMLP: nextW[7], wOut: nextW[8], bOut: nextW[9]
        )
        adamM = BrainwaveModelWeights(
            wQ: nextM[0], bQ: nextM[1], wK: nextM[2], bK: nextM[3], wV: nextM[4], bV: nextM[5],
            wMLP: nextM[6], bMLP: nextM[7], wOut: nextM[8], bOut: nextM[9]
        )
        adamV = BrainwaveModelWeights(
            wQ: nextV[0], bQ: nextV[1], wK: nextV[2], bK: nextV[3], wV: nextV[4], bV: nextV[5],
            wMLP: nextV[6], bMLP: nextV[7], wOut: nextV[8], bOut: nextV[9]
        )

        return (lossVal, min(max(gradNormVal, 0.0), Self.maxGradientL2Norm))
    }
    #endif

    // MARK: - 4. Bit-Accurate SIMD CPU Forward & Reverse-Mode Autodiff Mirror

    private struct ForwardSequenceCache {
        let x: [Float]          // [8 * 12]
        let q: [Float]          // [8 * 32]
        let k: [Float]          // [8 * 32]
        let v: [Float]          // [8 * 32]
        let attn: [Float]       // [8 * 8]
        let pooled: [Float]     // [32]
        let mlpTanh: [Float]    // [32]
        let mlpRes: [Float]     // [32]
        let outputs: [Float]    // [5]
    }

    @inline(__always)
    private static func simdDot32(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>) -> Float {
        var acc0 = SIMD4<Float>.zero
        var acc1 = SIMD4<Float>.zero
        for base in stride(from: 0, to: 32, by: 8) {
            let va0 = SIMD4<Float>(a[base], a[base + 1], a[base + 2], a[base + 3])
            let vb0 = SIMD4<Float>(b[base], b[base + 1], b[base + 2], b[base + 3])
            let va1 = SIMD4<Float>(a[base + 4], a[base + 5], a[base + 6], a[base + 7])
            let vb1 = SIMD4<Float>(b[base + 4], b[base + 5], b[base + 6], b[base + 7])
            acc0 += va0 * vb0
            acc1 += va1 * vb1
        }
        let sum = acc0 + acc1
        return sum[0] + sum[1] + sum[2] + sum[3]
    }

    private static func forwardSingleSequenceSIMD(
        flatSequence96 x: [Float],
        weights: BrainwaveModelWeights
    ) -> ForwardSequenceCache {
        let T = sequenceLength
        let D = featureDim
        let H = hiddenDim
        let O = outputDim
        let invSqrtDk: Float = 1.0 / sqrtf(Float(H))

        var q = [Float](repeating: 0.0, count: T * H)
        var k = [Float](repeating: 0.0, count: T * H)
        var v = [Float](repeating: 0.0, count: T * H)

        for t in 0..<T {
            let xOff = t * D
            let hOff = t * H
            for h in 0..<H {
                q[hOff + h] = weights.bQ[h]
                k[hOff + h] = weights.bK[h]
                v[hOff + h] = weights.bV[h]
            }
            for d in 0..<D {
                let xv = x[xOff + d]
                let wRow = d * H
                for h in 0..<H {
                    q[hOff + h] += xv * weights.wQ[wRow + h]
                    k[hOff + h] += xv * weights.wK[wRow + h]
                    v[hOff + h] += xv * weights.wV[wRow + h]
                }
            }
        }

        // Scaled Dot-Product Temporal Self-Attention: Softmax((Q * K^T) / sqrt(32))
        var attn = [Float](repeating: 0.0, count: T * T)
        q.withUnsafeBufferPointer { qBuf in
            k.withUnsafeBufferPointer { kBuf in
                guard let qBase = qBuf.baseAddress, let kBase = kBuf.baseAddress else { return }
                for t in 0..<T {
                    var maxScore: Float = -.greatestFiniteMagnitude
                    let rowOff = t * T
                    for s in 0..<T {
                        let score = simdDot32(qBase.advanced(by: t * H), kBase.advanced(by: s * H)) * invSqrtDk
                        attn[rowOff + s] = score
                        if score > maxScore { maxScore = score }
                    }
                    var sumExp: Float = 0.0
                    for s in 0..<T {
                        let e = expf(attn[rowOff + s] - maxScore)
                        attn[rowOff + s] = e
                        sumExp += e
                    }
                    let invSum = 1.0 / max(sumExp, 1.0e-12)
                    for s in 0..<T {
                        attn[rowOff + s] *= invSum
                    }
                }
            }
        }

        // Context C = A * V, followed by temporal mean pooling [32]
        var pooled = [Float](repeating: 0.0, count: H)
        let invT = 1.0 / Float(T)
        for t in 0..<T {
            let rowOff = t * T
            for s in 0..<T {
                let weight = attn[rowOff + s] * invT
                let vOff = s * H
                for h in 0..<H {
                    pooled[h] += weight * v[vOff + h]
                }
            }
        }

        // Residual MLP (32 -> 32 with tanh)
        var mlpTanh = [Float](repeating: 0.0, count: H)
        var mlpRes = [Float](repeating: 0.0, count: H)
        for j in 0..<H {
            var sum = weights.bMLP[j]
            for i in 0..<H {
                sum += pooled[i] * weights.wMLP[i * H + j]
            }
            let th = tanhf(sum)
            mlpTanh[j] = th
            mlpRes[j] = pooled[j] + th
        }

        // Readout Head (32 -> 5 with sigmoid)
        var outputs = [Float](repeating: 0.0, count: O)
        for o in 0..<O {
            var logit = weights.bOut[o]
            for j in 0..<H {
                logit += mlpRes[j] * weights.wOut[j * O + o]
            }
            let clamped = min(max(logit, -20.0), 20.0)
            outputs[o] = 1.0 / (1.0 + expf(-clamped))
        }

        return ForwardSequenceCache(
            x: x,
            q: q,
            k: k,
            v: v,
            attn: attn,
            pooled: pooled,
            mlpTanh: mlpTanh,
            mlpRes: mlpRes,
            outputs: outputs
        )
    }

    private static func executeSIMDCPUAutodiffStep(
        batch: BiometricTrainingBatch,
        learningRate: Float,
        stepIndex: Int,
        weights: inout BrainwaveModelWeights,
        adamM: inout BrainwaveModelWeights,
        adamV: inout BrainwaveModelWeights
    ) -> (loss: Float, clippedGradL2Norm: Float) {
        let B = batch.batchSize
        let T = sequenceLength
        let D = featureDim
        let H = hiddenDim
        let O = outputDim
        let seqStride = T * D
        let invSqrtDk: Float = 1.0 / sqrtf(Float(H))
        let invBatchOut = 1.0 / Float(B * O)
        let invBatch = 1.0 / Float(B)
        let invT = 1.0 / Float(T)
        let delta = huberDelta

        var grads = BrainwaveModelWeights.makeZeros()
        var totalLoss: Float = 0.0

        for b in 0..<B {
            let xSlice = Array(batch.inputs[(b * seqStride)..<((b + 1) * seqStride)])
            let cache = forwardSingleSequenceSIMD(flatSequence96: xSlice, weights: weights)

            // 1. Smooth-L1 (Huber) + Autonomic Coherence Reward loss & dLoss/dLogits
            var dLogits = [Float](repeating: 0.0, count: O)
            let yBase = b * O

            for o in 0..<O {
                let yHat = cache.outputs[o]
                let yTrue = batch.targets[yBase + o]
                let diff = yHat - yTrue
                let absDiff = abs(diff)

                let elemLoss: Float
                let dSmoothDy: Float
                if absDiff <= delta {
                    elemLoss = (0.5 * diff * diff) / delta
                    dSmoothDy = (diff / delta) * invBatchOut
                } else {
                    elemLoss = absDiff - 0.5 * delta
                    dSmoothDy = (diff >= 0.0 ? 1.0 : -1.0) * invBatchOut
                }
                totalLoss += elemLoss * invBatchOut

                var dDy = dSmoothDy
                if o == 4 {
                    let cohDiff = yHat - batch.coherenceRewards[b]
                    totalLoss += coherenceRewardWeight * (cohDiff * cohDiff) * invBatch
                    dDy += (2.0 * coherenceRewardWeight * cohDiff) * invBatch
                }

                dLogits[o] = dDy * yHat * (1.0 - yHat)
            }

            // 2. Backprop Readout Head (32 -> 5)
            var dMlpRes = [Float](repeating: 0.0, count: H)
            for o in 0..<O {
                let g = dLogits[o]
                grads.bOut[o] += g
                for j in 0..<H {
                    grads.wOut[j * O + o] += cache.mlpRes[j] * g
                    dMlpRes[j] += weights.wOut[j * O + o] * g
                }
            }

            // 3. Backprop Residual MLP: mlpRes = pooled + tanh(pooled * wMLP + bMLP)
            var dPooled = dMlpRes
            var dMlpPre = [Float](repeating: 0.0, count: H)
            for j in 0..<H {
                let th = cache.mlpTanh[j]
                let gPre = dMlpRes[j] * (1.0 - th * th)
                dMlpPre[j] = gPre
                grads.bMLP[j] += gPre
            }
            for i in 0..<H {
                let pVal = cache.pooled[i]
                let rowOff = i * H
                var backSum: Float = 0.0
                for j in 0..<H {
                    let gPre = dMlpPre[j]
                    grads.wMLP[rowOff + j] += pVal * gPre
                    backSum += weights.wMLP[rowOff + j] * gPre
                }
                dPooled[i] += backSum
            }

            // 4. Backprop Temporal Mean Pool & Attention Context C = A * V
            var dAttn = [Float](repeating: 0.0, count: T * T)
            var dV = [Float](repeating: 0.0, count: T * H)

            for t in 0..<T {
                let rowOff = t * T
                for s in 0..<T {
                    let prob = cache.attn[rowOff + s]
                    let vOff = s * H
                    var dotCV: Float = 0.0
                    for h in 0..<H {
                        let dp = dPooled[h] * invT
                        dotCV += dp * cache.v[vOff + h]
                        dV[vOff + h] += prob * dp
                    }
                    dAttn[rowOff + s] = dotCV
                }
            }

            // 5. Backprop Softmax((Q * K^T) / sqrt(32)) -> dQ, dK
            var dQ = [Float](repeating: 0.0, count: T * H)
            var dK = [Float](repeating: 0.0, count: T * H)

            for t in 0..<T {
                let rowOff = t * T
                var rowDot: Float = 0.0
                for s in 0..<T {
                    rowDot += cache.attn[rowOff + s] * dAttn[rowOff + s]
                }
                let qOff = t * H
                for s in 0..<T {
                    let dScore = cache.attn[rowOff + s] * (dAttn[rowOff + s] - rowDot) * invSqrtDk
                    let kOff = s * H
                    for h in 0..<H {
                        dQ[qOff + h] += dScore * cache.k[kOff + h]
                        dK[kOff + h] += dScore * cache.q[qOff + h]
                    }
                }
            }

            // 6. Backprop Q, K, V Linear Projections [T, 12] -> [T, 32]
            for t in 0..<T {
                let xOff = t * D
                let hOff = t * H
                for h in 0..<H {
                    grads.bQ[h] += dQ[hOff + h]
                    grads.bK[h] += dK[hOff + h]
                    grads.bV[h] += dV[hOff + h]
                }
                for d in 0..<D {
                    let xv = cache.x[xOff + d]
                    let wRow = d * H
                    for h in 0..<H {
                        grads.wQ[wRow + h] += xv * dQ[hOff + h]
                        grads.wK[wRow + h] += xv * dK[hOff + h]
                        grads.wV[wRow + h] += xv * dV[hOff + h]
                    }
                }
            }
        }

        // 7. Global L2 Gradient Norm Computation & Clipping (||grad||_2 <= 1.0)
        func sumSquares(_ arr: [Float]) -> Float {
            var s: Float = 0.0
            for v in arr { s += v * v }
            return s
        }

        let totalSqNorm = sumSquares(grads.wQ) + sumSquares(grads.bQ)
            + sumSquares(grads.wK) + sumSquares(grads.bK)
            + sumSquares(grads.wV) + sumSquares(grads.bV)
            + sumSquares(grads.wMLP) + sumSquares(grads.bMLP)
            + sumSquares(grads.wOut) + sumSquares(grads.bOut)

        let rawNorm = sqrtf(max(1.0e-16, totalSqNorm))
        let clipScale = min(1.0, maxGradientL2Norm / rawNorm)
        let clippedNorm = min(rawNorm, maxGradientL2Norm)

        // 8. Decoupled AdamW Optimizer Update (lambda = 1e-4)
        let b1 = adamBeta1
        let oneMinusB1 = 1.0 - b1
        let b2 = adamBeta2
        let oneMinusB2 = 1.0 - b2
        let b1Corr = max(1.0e-7, 1.0 - powf(b1, Float(stepIndex)))
        let b2Corr = max(1.0e-7, 1.0 - powf(b2, Float(stepIndex)))
        let decayFactor = 1.0 - learningRate * weightDecay

        func applyAdamW(
            param: inout [Float],
            grad: [Float],
            m: inout [Float],
            v: inout [Float],
            useWeightDecay: Bool
        ) {
            for i in 0..<param.count {
                let g = grad[i] * clipScale
                let nextM = b1 * m[i] + oneMinusB1 * g
                let nextV = b2 * v[i] + oneMinusB2 * g * g
                m[i] = nextM
                v[i] = nextV

                let mHat = nextM / b1Corr
                let vHat = nextV / b2Corr
                let stepDelta = learningRate * (mHat / (sqrtf(vHat) + adamEpsilon))
                let decayed = useWeightDecay ? (param[i] * decayFactor) : param[i]
                param[i] = decayed - stepDelta
            }
        }

        applyAdamW(param: &weights.wQ, grad: grads.wQ, m: &adamM.wQ, v: &adamV.wQ, useWeightDecay: true)
        applyAdamW(param: &weights.bQ, grad: grads.bQ, m: &adamM.bQ, v: &adamV.bQ, useWeightDecay: false)
        applyAdamW(param: &weights.wK, grad: grads.wK, m: &adamM.wK, v: &adamV.wK, useWeightDecay: true)
        applyAdamW(param: &weights.bK, grad: grads.bK, m: &adamM.bK, v: &adamV.bK, useWeightDecay: false)
        applyAdamW(param: &weights.wV, grad: grads.wV, m: &adamM.wV, v: &adamV.wV, useWeightDecay: true)
        applyAdamW(param: &weights.bV, grad: grads.bV, m: &adamM.bV, v: &adamV.bV, useWeightDecay: false)
        applyAdamW(param: &weights.wMLP, grad: grads.wMLP, m: &adamM.wMLP, v: &adamV.wMLP, useWeightDecay: true)
        applyAdamW(param: &weights.bMLP, grad: grads.bMLP, m: &adamM.bMLP, v: &adamV.bMLP, useWeightDecay: false)
        applyAdamW(param: &weights.wOut, grad: grads.wOut, m: &adamM.wOut, v: &adamV.wOut, useWeightDecay: true)
        applyAdamW(param: &weights.bOut, grad: grads.bOut, m: &adamM.bOut, v: &adamV.bOut, useWeightDecay: false)

        return (totalLoss, clippedNorm)
    }
}
