// MARK: - FILE: AetherCompositorRenderer.swift

import Foundation
import simd

#if os(visionOS) && canImport(CompositorServices)
import SwiftUI
import CompositorServices
import Metal
import ARKit
import QuartzCore

// MARK: - CompositorLayer Configuration (.rgba16Float HDR, .depth32Float, .layered, Foveated)

public struct AetherCompositorLayerConfiguration: CompositorLayerConfiguration {
    public init() {}

    public func makeConfiguration(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        configuration.colorFormat = .rgba16Float
        configuration.depthFormat = .depth32Float

        let foveationSupported = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationSupported

        let layoutOptions: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationSupported
            ? [.foveationEnabled]
            : []
        let supportedLayouts = capabilities.supportedLayouts(options: layoutOptions)

        if supportedLayouts.contains(.layered) {
            configuration.layout = .layered
        } else if supportedLayouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if let fallbackLayout = supportedLayouts.first {
            configuration.layout = fallbackLayout
        }
    }
}

// MARK: - Byte-Exact GPU Struct Mirrors (Matches AetherCompositorShaders.metal)

private struct GPUParticleRecord {
    var positionAndAge: SIMD4<Float>
    var velocityAndSeed: SIMD4<Float>
    var colorAndSize: SIMD4<Float>
}

private struct GPUCompositorUniforms {
    var viewProjectionMatrix: (simd_float4x4, simd_float4x4)
    var cameraRightWorld: (SIMD4<Float>, SIMD4<Float>)
    var cameraUpWorld: (SIMD4<Float>, SIMD4<Float>)
    var eyePositionWorld: (SIMD4<Float>, SIMD4<Float>)
    var attractorCenterAndRadius: SIMD4<Float>
    var leftPalmAndPinch: SIMD4<Float>
    var rightPalmAndPinch: SIMD4<Float>
    var simulationTiming: SIMD4<Float>
    var acousticModulation: SIMD4<Float>
    var spectralEnergyBands: SIMD4<Float>
    var fftBinsPacked: (
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
    )
    var eyeIndex: UInt32
    var isLayeredStereo: UInt32
    var particleCount: UInt32
    var frameCounter: UInt32
}

// MARK: - Dedicated Background-Thread CompositorServices Metal Compute & Stereo Render Engine

public final class AetherCompositorRenderer: @unchecked Sendable {
    public static let particleCount: Int = 16_384
    public static let maxFramesInFlight: Int = 3
    private static let auroraDomeVertexCount: Int = 32 * 16 * 6

    private let layerRenderer: LayerRenderer
    private let sharedState: VisionSpatialSharedState
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let particleRenderPipeline: MTLRenderPipelineState
    private let auroraDomeRenderPipeline: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private let particleBuffers: [MTLBuffer]
    private let inFlightSemaphore = DispatchSemaphore(value: AetherCompositorRenderer.maxFramesInFlight)

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    public init?(layerRenderer: LayerRenderer, sharedState: VisionSpatialSharedState) {
        self.layerRenderer = layerRenderer
        self.sharedState = sharedState
        self.device = layerRenderer.device

        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let computeFn = library.makeFunction(name: "aetherCurlNoiseParticleKernel"),
              let particleVertFn = library.makeFunction(name: "aetherStereoParticleVertex"),
              let particleFragFn = library.makeFunction(name: "aetherStereoParticleFragment"),
              let domeVertFn = library.makeFunction(name: "aetherStereoAuroraDomeVertex"),
              let domeFragFn = library.makeFunction(name: "aetherStereoAuroraDomeFragment") else {
            return nil
        }
        self.commandQueue = queue

        do {
            self.computePipeline = try device.makeComputePipelineState(function: computeFn)

            let particleDesc = MTLRenderPipelineDescriptor()
            particleDesc.label = "AetherStereoCurlParticlesPipeline"
            particleDesc.vertexFunction = particleVertFn
            particleDesc.fragmentFunction = particleFragFn
            particleDesc.inputPrimitiveTopology = .triangle
            particleDesc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
            particleDesc.colorAttachments[0].isBlendingEnabled = true
            particleDesc.colorAttachments[0].rgbBlendOperation = .add
            particleDesc.colorAttachments[0].alphaBlendOperation = .add
            particleDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            particleDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            particleDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            particleDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            particleDesc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
            self.particleRenderPipeline = try device.makeRenderPipelineState(descriptor: particleDesc)

            let domeDesc = MTLRenderPipelineDescriptor()
            domeDesc.label = "AetherStereoAuroraDomePipeline"
            domeDesc.vertexFunction = domeVertFn
            domeDesc.fragmentFunction = domeFragFn
            domeDesc.inputPrimitiveTopology = .triangle
            domeDesc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
            domeDesc.colorAttachments[0].isBlendingEnabled = true
            domeDesc.colorAttachments[0].rgbBlendOperation = .add
            domeDesc.colorAttachments[0].alphaBlendOperation = .add
            domeDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            domeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            domeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            domeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            domeDesc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
            self.auroraDomeRenderPipeline = try device.makeRenderPipelineState(descriptor: domeDesc)
        } catch {
            return nil
        }

        let depthDesc = MTLDepthStencilDescriptor()
        // Reverse-Z depth testing (.greaterEqual against clearDepth = 0.0) ensures visionOS 2 reprojection
        // receives accurate nearest-surface per-pixel depth while preserving additive blending.
        depthDesc.depthCompareFunction = .greaterEqual
        depthDesc.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
            return nil
        }
        self.depthStencilState = depthState

        let byteLength = MemoryLayout<GPUParticleRecord>.stride * Self.particleCount
        guard let slot0 = device.makeBuffer(length: byteLength, options: .storageModeShared),
              let slot1 = device.makeBuffer(length: byteLength, options: .storageModeShared),
              let slot2 = device.makeBuffer(length: byteLength, options: .storageModeShared) else {
            return nil
        }
        Self.seedInitialParticles(into: slot0)
        memcpy(slot1.contents(), slot0.contents(), byteLength)
        memcpy(slot2.contents(), slot0.contents(), byteLength)
        self.particleBuffers = [slot0, slot1, slot2]
    }

    public func startRenderLoop() {
        Task { [arSession, worldTracking] in
            if WorldTrackingProvider.isSupported {
                try? await arSession.run([worldTracking])
            }
        }

        // Strong capture is intentional: nothing else owns the renderer after the CompositorLayer closure
        // returns, so a weak capture lets it deallocate before the thread starts (black immersive space).
        // The loop exits on `.invalidated`, which releases the renderer deterministically.
        let renderThread = Thread {
            self.runDedicatedRenderThread()
        }
        renderThread.name = "com.aethersynth.vision.compositor-render-thread"
        renderThread.qualityOfService = .userInteractive
        renderThread.start()
    }

    // MARK: - Complete LayerRenderer.Frame Pacing & Submission Loop

    private func runDedicatedRenderThread() {
        var previousMediaTime = CACurrentMediaTime()
        let startMediaTime = previousMediaTime
        var frameCounter: UInt32 = 0
        var pingPongIndex: Int = 0

        while true {
            switch layerRenderer.state {
            case .paused:
                layerRenderer.waitUntilRunning()
                previousMediaTime = CACurrentMediaTime()
                continue
            case .invalidated:
                arSession.stop()
                return
            case .running:
                autoreleasepool {
                    renderStereoscopicFrame(
                        startMediaTime: startMediaTime,
                        previousMediaTime: &previousMediaTime,
                        frameCounter: &frameCounter,
                        pingPongIndex: &pingPongIndex
                    )
                }
            @unknown default:
                return
            }
        }
    }

    private func renderStereoscopicFrame(
        startMediaTime: CFTimeInterval,
        previousMediaTime: inout CFTimeInterval,
        frameCounter: inout UInt32,
        pingPongIndex: inout Int
    ) {
        guard let frame = layerRenderer.queryNextFrame() else {
            return
        }

        // 1. Frame Update Phase (input-independent work only; hand/pinch state is sampled after optimalInputTime)
        frame.startUpdate()
        frame.endUpdate()

        // 2. Optimal Input Latency Wait
        guard let timing = frame.predictTiming() else {
            return
        }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        // 3. Submission Phase & Triple-Buffered In-Flight Slot Acquisition
        frame.startSubmission()
        defer { frame.endSubmission() }

        guard let drawable = frame.queryDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        guard inFlightSemaphore.wait(timeout: .now() + .milliseconds(12)) == .success else {
            return
        }
        let semaphore = inFlightSemaphore
        var didScheduleCompletionSignal = false
        defer {
            if !didScheduleCompletionSignal {
                semaphore.signal()
            }
        }

        guard layerRenderer.state == .running else {
            return
        }

        let presentationTimestamp = Self.timeInterval(from: drawable.frameTiming.presentationTime)

        // Latest hand/pinch/FFT telemetry, sampled as late as possible (after optimalInputTime).
        let telemetry = sharedState.snapshot()
        // Simulation step follows photon (presentation) time, not CPU wake-up time, to avoid particle judder
        // when the compositor shifts cadence (90 / 96 / 100 Hz) or CPU scheduling jitters.
        let dt = Float(min(max(presentationTimestamp - previousMediaTime, 1.0 / 240.0), 0.050))
        let elapsed = Float(presentationTimestamp - startMediaTime)
        previousMediaTime = presentationTimestamp
        let deviceAnchor: DeviceAnchor? = WorldTrackingProvider.isSupported
            ? worldTracking.queryDeviceAnchor(atTimestamp: presentationTimestamp)
            : nil
        drawable.deviceAnchor = deviceAnchor

        let originFromDevice = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        sharedState.publishHeadTransform(originFromDevice)

        let views = drawable.views
        guard !views.isEmpty else {
            return
        }

        // Build per-eye ViewProjection, camera basis, and eye origins using visionOS 2 computeProjection(viewIndex:)
        var vp0 = matrix_identity_float4x4
        var vp1 = matrix_identity_float4x4
        var right0 = SIMD4<Float>(1, 0, 0, 0)
        var right1 = SIMD4<Float>(1, 0, 0, 0)
        var up0 = SIMD4<Float>(0, 1, 0, 0)
        var up1 = SIMD4<Float>(0, 1, 0, 0)
        var eyePos0 = SIMD4<Float>(0, 1.5, 0, 1)
        var eyePos1 = SIMD4<Float>(0, 1.5, 0, 1)

        for (eyeIdx, view) in views.prefix(2).enumerated() {
            let worldFromEye = simd_mul(originFromDevice, view.transform)
            let eyeFromWorld = simd_inverse(worldFromEye)
            let projection = drawable.computeProjection(viewIndex: eyeIdx)
            let vp = simd_mul(projection, eyeFromWorld)

            let worldRight = simd_normalize(SIMD3<Float>(
                worldFromEye.columns.0.x,
                worldFromEye.columns.0.y,
                worldFromEye.columns.0.z
            ))
            let worldUp = simd_normalize(SIMD3<Float>(
                worldFromEye.columns.1.x,
                worldFromEye.columns.1.y,
                worldFromEye.columns.1.z
            ))
            let worldEyeOrigin = SIMD4<Float>(
                worldFromEye.columns.3.x,
                worldFromEye.columns.3.y,
                worldFromEye.columns.3.z,
                1.0
            )

            if eyeIdx == 0 {
                vp0 = vp
                right0 = SIMD4<Float>(worldRight.x, worldRight.y, worldRight.z, 0)
                up0 = SIMD4<Float>(worldUp.x, worldUp.y, worldUp.z, 0)
                eyePos0 = worldEyeOrigin
                vp1 = vp
                right1 = right0
                up1 = up0
                eyePos1 = eyePos0
            } else {
                vp1 = vp
                right1 = SIMD4<Float>(worldRight.x, worldRight.y, worldRight.z, 0)
                up1 = SIMD4<Float>(worldUp.x, worldUp.y, worldUp.z, 0)
                eyePos1 = worldEyeOrigin
            }
        }

        let mod = telemetry.modulation
        let sample = telemetry.sample
        let bimanualMidpoint = 0.5 * (sample.leftPalm + sample.rightPalm)
        let attractorCenter = SIMD3<Float>(
            bimanualMidpoint.x * 0.45,
            1.42 + (bimanualMidpoint.y - 1.20) * 0.35,
            -1.35 + (bimanualMidpoint.z + 0.42) * 0.35
        )
        let cutoffNorm = min(max(logf(max(mod.filterCutoffHz, 120.0) / 120.0) / logf(12_000.0 / 120.0), 0.0), 1.0)
        let curlSpatialFreq: Float = 0.92 + cutoffNorm * 1.48
        let curlTurbulence: Float = 0.40 + mod.bloomBoost * 0.85 + telemetry.audioRMS * 0.58

        let bins = telemetry.fftBinsPacked16
        let useSinglePassLayered = (layerRenderer.configuration.layout == .layered)
            && drawable.colorTextures.count == 1
            && drawable.depthTextures.count == 1

        frameCounter &+= 1

        var uniforms = GPUCompositorUniforms(
            viewProjectionMatrix: (vp0, vp1),
            cameraRightWorld: (right0, right1),
            cameraUpWorld: (up0, up1),
            eyePositionWorld: (eyePos0, eyePos1),
            attractorCenterAndRadius: SIMD4<Float>(
                attractorCenter.x,
                attractorCenter.y,
                attractorCenter.z,
                1.12 * mod.orbitalRadiusScale
            ),
            leftPalmAndPinch: SIMD4<Float>(
                sample.leftPalm.x,
                sample.leftPalm.y,
                sample.leftPalm.z,
                mod.leftPinchEngaged ? 1.0 : 0.15
            ),
            rightPalmAndPinch: SIMD4<Float>(
                sample.rightPalm.x,
                sample.rightPalm.y,
                sample.rightPalm.z,
                mod.rightPinchEngaged ? 1.0 : 0.15
            ),
            simulationTiming: SIMD4<Float>(dt, elapsed, curlSpatialFreq, curlTurbulence),
            acousticModulation: SIMD4<Float>(
                mod.binauralBeatHz,
                cutoffNorm,
                mod.filterResonance,
                mod.bloomBoost
            ),
            spectralEnergyBands: SIMD4<Float>(
                telemetry.subBandEnergy,
                telemetry.lowBandEnergy,
                telemetry.highBandEnergy,
                telemetry.audioRMS
            ),
            fftBinsPacked: (
                bins[0], bins[1], bins[2], bins[3],
                bins[4], bins[5], bins[6], bins[7],
                bins[8], bins[9], bins[10], bins[11],
                bins[12], bins[13], bins[14], bins[15]
            ),
            eyeIndex: 0,
            isLayeredStereo: useSinglePassLayered ? 1 : 0,
            particleCount: UInt32(Self.particleCount),
            frameCounter: frameCounter
        )

        // 4. Triple-Buffered Metal Compute Pass (16,384 Curl-Noise + FFT Shockwave Particles)
        let ringCount = particleBuffers.count
        let srcBuffer = particleBuffers[pingPongIndex % ringCount]
        let dstIndex = (pingPongIndex + 1) % ringCount
        let dstBuffer = particleBuffers[dstIndex]
        pingPongIndex = dstIndex

        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.label = "AetherCurlNoiseParticleComputePass"
            computeEncoder.setComputePipelineState(computePipeline)
            computeEncoder.setBuffer(srcBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(dstBuffer, offset: 0, index: 1)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<GPUCompositorUniforms>.stride, index: 2)

            let tgWidth = min(256, max(32, computePipeline.maxTotalThreadsPerThreadgroup))
            computeEncoder.dispatchThreads(
                MTLSize(width: Self.particleCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tgWidth, height: 1, depth: 1)
            )
            computeEncoder.endEncoding()
        }

        // 5. Stereoscopic Render Pass (Single-Pass .layered Array Slice Routing OR Per-Eye Fallback)
        if useSinglePassLayered {
            let viewCount = min(views.count, 2)
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = drawable.colorTextures[0]
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            passDesc.depthAttachment.texture = drawable.depthTextures[0]
            passDesc.depthAttachment.loadAction = .clear
            passDesc.depthAttachment.storeAction = .store
            passDesc.depthAttachment.clearDepth = 0.0

            passDesc.renderTargetArrayLength = viewCount
            passDesc.rasterizationRateMap = drawable.rasterizationRateMaps.first

            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {
                renderEncoder.label = "AetherLayeredStereoRenderPass"
                renderEncoder.setDepthStencilState(depthStencilState)
                renderEncoder.setViewports(views.prefix(viewCount).map(\.textureMap.viewport))

                // Draw Stereoscopic Volumetric Aurora Dome
                renderEncoder.setRenderPipelineState(auroraDomeRenderPipeline)
                renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUCompositorUniforms>.stride, index: 0)
                renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUCompositorUniforms>.stride, index: 0)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: Self.auroraDomeVertexCount,
                    instanceCount: viewCount
                )

                // Draw 16,384 Stereoscopic Curl-Noise HDR Particles across both eye slices
                renderEncoder.setRenderPipelineState(particleRenderPipeline)
                renderEncoder.setVertexBuffer(dstBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUCompositorUniforms>.stride, index: 1)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: Self.particleCount * viewCount
                )

                renderEncoder.endEncoding()
            }
        } else {
            var clearedTextures: Set<Int> = []
            for (eyeIdx, view) in views.prefix(2).enumerated() {
                let texMap = view.textureMap
                let texIndex = texMap.textureIndex
                guard texIndex < drawable.colorTextures.count,
                      texIndex < drawable.depthTextures.count else {
                    continue
                }

                let isFirstUse = clearedTextures.insert(texIndex).inserted
                let passDesc = MTLRenderPassDescriptor()
                passDesc.colorAttachments[0].texture = drawable.colorTextures[texIndex]
                passDesc.colorAttachments[0].slice = texMap.sliceIndex
                passDesc.colorAttachments[0].loadAction = isFirstUse ? .clear : .load
                passDesc.colorAttachments[0].storeAction = .store
                passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

                passDesc.depthAttachment.texture = drawable.depthTextures[texIndex]
                passDesc.depthAttachment.slice = texMap.sliceIndex
                passDesc.depthAttachment.loadAction = isFirstUse ? .clear : .load
                passDesc.depthAttachment.storeAction = .store
                passDesc.depthAttachment.clearDepth = 0.0

                if texIndex < drawable.rasterizationRateMaps.count {
                    passDesc.rasterizationRateMap = drawable.rasterizationRateMaps[texIndex]
                }

                uniforms.eyeIndex = UInt32(eyeIdx)
                uniforms.isLayeredStereo = 0

                if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {
                    renderEncoder.label = "AetherDedicatedStereoEyePass_\(eyeIdx)"
                    renderEncoder.setDepthStencilState(depthStencilState)
                    renderEncoder.setViewport(texMap.viewport)

                    renderEncoder.setRenderPipelineState(auroraDomeRenderPipeline)
                    renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUCompositorUniforms>.stride, index: 0)
                    renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUCompositorUniforms>.stride, index: 0)
                    renderEncoder.drawPrimitives(
                        type: .triangle,
                        vertexStart: 0,
                        vertexCount: Self.auroraDomeVertexCount,
                        instanceCount: 1
                    )

                    renderEncoder.setRenderPipelineState(particleRenderPipeline)
                    renderEncoder.setVertexBuffer(dstBuffer, offset: 0, index: 0)
                    renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUCompositorUniforms>.stride, index: 1)
                    renderEncoder.drawPrimitives(
                        type: .triangle,
                        vertexStart: 0,
                        vertexCount: 6,
                        instanceCount: Self.particleCount
                    )

                    renderEncoder.endEncoding()
                }
            }
        }

        guard layerRenderer.state == .running else {
            return
        }

        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
        didScheduleCompletionSignal = true
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
    }

    // MARK: - Clock Conversion & Deterministic Fibonacci/SplitMix64 Sphere Seeding

    private static func timeInterval(from instant: LayerRenderer.Clock.Instant) -> TimeInterval {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: instant)
        let comps = duration.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) * 1.0e-18
    }

    private static func seedInitialParticles(into buffer: MTLBuffer) {
        let ptr = buffer.contents().bindMemory(to: GPUParticleRecord.self, capacity: particleCount)
        var rng: UInt64 = 0xAE74_E259_2026_8841

        func nextUnit() -> Float {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return Float(z >> 40) * (1.0 / 16_777_216.0)
        }

        let center = SIMD3<Float>(0.0, 1.42, -1.35)
        for idx in 0..<particleCount {
            let u = nextUnit()
            let v = nextUnit()
            let radius = 0.45 + 1.25 * powf(nextUnit(), 0.65)
            let theta = 2.0 * Float.pi * u
            let cosPhi = 1.0 - 2.0 * v
            let sinPhi = sqrtf(max(0.0, 1.0 - cosPhi * cosPhi))

            let offset = SIMD3<Float>(
                sinPhi * cosf(theta) * radius,
                cosPhi * radius * 0.72,
                sinPhi * sinf(theta) * radius
            )
            let pos = center + offset
            let age = nextUnit()
            let seed = nextUnit()

            ptr[idx] = GPUParticleRecord(
                positionAndAge: SIMD4<Float>(pos.x, pos.y, pos.z, age),
                velocityAndSeed: SIMD4<Float>(0.0, 0.0, 0.0, seed),
                colorAndSize: SIMD4<Float>(0.22, 0.76, 0.98, 0.007)
            )
        }
    }
}
#endif
