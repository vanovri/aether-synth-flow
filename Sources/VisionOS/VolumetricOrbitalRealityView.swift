// MARK: - FILE: VolumetricOrbitalRealityView.swift

import SwiftUI
import SwiftData
import simd
#if os(visionOS)
import RealityKit
import UIKit

// MARK: - Inclined 3D Keplerian Satellite Component

public struct OrbitalHabitSatelliteComponent: Component, Codable, Sendable, Equatable {
    public var habitID: UUID
    public var habitTitle: String
    public var accentHue: Double
    public var semiMajorAxisMeters: Float
    public var eccentricity: Float
    public var inclination: Float
    public var longitudeOfAscendingNode: Float
    public var trueAnomaly: Float
    public var baseAngularVelocity: Float
    public var flingAngularImpulse: Float
    public var harmonicRatio: Float

    public init(
        habitID: UUID,
        habitTitle: String,
        accentHue: Double,
        semiMajorAxisMeters: Float,
        eccentricity: Float,
        inclination: Float,
        longitudeOfAscendingNode: Float,
        trueAnomaly: Float,
        baseAngularVelocity: Float,
        flingAngularImpulse: Float = 0.0,
        harmonicRatio: Float = 1.5
    ) {
        self.habitID = habitID
        self.habitTitle = habitTitle
        self.accentHue = accentHue
        self.semiMajorAxisMeters = semiMajorAxisMeters
        self.eccentricity = eccentricity
        self.inclination = inclination
        self.longitudeOfAscendingNode = longitudeOfAscendingNode
        self.trueAnomaly = trueAnomaly
        self.baseAngularVelocity = baseAngularVelocity
        self.flingAngularImpulse = flingAngularImpulse
        self.harmonicRatio = harmonicRatio
    }
}

// MARK: - 3D Volumetric Orbital RealityView (0.85m x 0.85m x 0.85m Spatial Stage)

public struct VolumetricOrbitalRealityView: View {
    @Bindable public var coordinator: AetherAppCoordinator
    @Bindable public var handTracker: BimanualHandTrackingActor

    @Query(
        filter: #Predicate<HabitNode> { node in node.isArchived == false },
        sort: [SortDescriptor(\HabitNode.sortOrder, order: .forward)]
    )
    private var habits: [HabitNode]

    @State private var rootAnchorEntity = Entity()
    @State private var coreSunEntity: ModelEntity?
    @State private var torusKnotEntity: ModelEntity?
    @State private var satelliteEntities: [UUID: ModelEntity] = [:]
    @State private var audioControllers: [UUID: AudioPlaybackController] = [:]
    @State private var audioLoadTasks: [UUID: Task<Void, Never>] = [:]
    @State private var sceneUpdateSubscription: EventSubscription?
    @State private var cachedCoreMesh: MeshResource?
    @State private var cachedKnotMesh: MeshResource?
    @State private var cachedSatelliteMesh: MeshResource?

    @State private var draggedSatelliteID: UUID?
    @State private var previousDragWorldPos: SIMD3<Float>?
    @State private var previousDragTimestamp: TimeInterval = 0
    @State private var estimatedDragVelocity: SIMD3<Float> = .zero
    @State private var accumulatedSceneTime: Float = 0.0
    @State private var lastBuiltHabitSignature: String = ""

    public init(
        coordinator: AetherAppCoordinator,
        handTracker: BimanualHandTrackingActor
    ) {
        self.coordinator = coordinator
        self.handTracker = handTracker
    }

    public var body: some View {
        RealityView { content in
            OrbitalHabitSatelliteComponent.registerComponent()
            rootAnchorEntity.name = "AetherVolumetricOrbitalStage"
            rootAnchorEntity.position = SIMD3<Float>(0.0, -0.02, 0.0)
            content.add(rootAnchorEntity)

            rebuildProceduralCoreAndKnotIfNeeded()
            rebuildHabitSatellites(using: resolvedHabitDTOs())

            // 90Hz SceneEvents.Update subscription driven by SpectralFFTAnalyzer sub/low/high bands
            sceneUpdateSubscription?.cancel()
            sceneUpdateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                let dt = Float(min(max(event.deltaTime, 1.0 / 240.0), 0.050))
                stepOrbitalPhysicsAndSpectralCore(dt: dt)
            }
        } update: { _ in
            let sig = habitSignature(for: habits)
            if sig != lastBuiltHabitSignature {
                rebuildHabitSatellites(using: resolvedHabitDTOs())
            }
            syncSpatialAudioPlaybackStates()
        }
        .onDisappear {
            tearDownVolumetricScene()
        }
        .gesture(spatialSatelliteTapGesture)
        .gesture(spatialSatelliteDragAndFlingGesture)
        .ornament(attachmentAnchor: .scene(.bottomFront)) {
            volumetricControlOrnament
        }
    }

    // MARK: - Interactive SpatialTapGesture (+15m Focus Pulse) & 3D Drag/Fling Gesture

    private var spatialSatelliteTapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                let tapped = value.entity
                if var sat = tapped.components[OrbitalHabitSatelliteComponent.self] {
                    if let matchedHabit = habits.first(where: { $0.habitID == sat.habitID }) {
                        if coordinator.selectedHabitID == matchedHabit.habitID {
                            // Second tap on active habit triggers +15m focus pulse + angular boost
                            sat.flingAngularImpulse = min(sat.flingAngularImpulse + 2.4, 6.0)
                            tapped.components.set(sat)
                            Task {
                                await coordinator.logQuickHabitIncrement(matchedHabit, minutes: 15)
                            }
                            coordinator.presentTransientBanner("+15m Focus Pulse · \(matchedHabit.title)")
                        } else {
                            coordinator.selectHabitSatellite(matchedHabit)
                        }
                    } else {
                        coordinator.selectedHabitID = sat.habitID
                        coordinator.selectedHabitTitle = sat.habitTitle
                        coordinator.activeAccentHue = sat.accentHue
                    }

                    coordinator.triggerManualHarmonicBloom(intensity: 0.90)

                    var pulseTransform = tapped.transform
                    pulseTransform.scale = SIMD3<Float>(repeating: 1.38)
                    tapped.move(
                        to: pulseTransform,
                        relativeTo: tapped.parent,
                        duration: 0.16,
                        timingFunction: .easeOut
                    )
                } else if tapped.name == "CentralGeodesicSun" || tapped.name == "KeplerianTorusHarmonicRing" {
                    coordinator.triggerManualHarmonicBloom(intensity: 0.95)
                }
            }
    }

    private var spatialSatelliteDragAndFlingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToAnyEntity()
            .onChanged { value in
                let entity = value.entity
                guard var sat = entity.components[OrbitalHabitSatelliteComponent.self] else {
                    return
                }

                let localPos = value.convert(value.location3D, from: .local, to: rootAnchorEntity)
                let now = ProcessInfo.processInfo.systemUptime

                if draggedSatelliteID == sat.habitID, let prevPos = previousDragWorldPos {
                    let dt = Float(max(1.0e-3, now - previousDragTimestamp))
                    let rawVel = (localPos - prevPos) / dt
                    estimatedDragVelocity = estimatedDragVelocity * 0.55 + rawVel * 0.45
                } else {
                    draggedSatelliteID = sat.habitID
                    estimatedDragVelocity = .zero
                }
                previousDragWorldPos = localPos
                previousDragTimestamp = now

                let clampedRadius = min(max(simd_length(localPos), 0.11), 0.36)
                sat.semiMajorAxisMeters = clampedRadius
                sat.inclination = min(max(asinf(localPos.y / max(clampedRadius, 1e-3)), -1.05), 1.05)
                sat.trueAnomaly = atan2f(localPos.z, localPos.x) - sat.longitudeOfAscendingNode
                entity.components.set(sat)
                entity.position = localPos

                // Continuously modulate binaural beat, Cytomic SVF cutoff & neural latent guidance from radial/vertical 3D placement
                let normR = (clampedRadius - 0.11) / (0.36 - 0.11)
                let normElev = min(max((localPos.y + 0.25) / 0.50, 0.0), 1.0)
                var next = coordinator.synthParameters
                next.binauralBeatHz = 2.0 + normR * 34.0
                next.filterCutoffHz = 180.0 * powf(55.0, normR)
                next.latentGuidanceScale = 1.0 + normR * 3.0
                next.latentTemperature = 0.20 + normElev * 1.40
                coordinator.synthParameters = next
                if coordinator.isSynthPlaying || coordinator.isTimerRunning {
                    coordinator.audioEngine.updateParametersImmediate(next)
                }
            }
            .onEnded { value in
                let entity = value.entity
                if var sat = entity.components[OrbitalHabitSatelliteComponent.self] {
                    // Convert tangential 3D release velocity into Keplerian angular velocity fling impulse
                    let rVec = entity.position
                    let rLen = max(0.10, simd_length(rVec))
                    let angularMomentumVec = simd_cross(rVec, estimatedDragVelocity)
                    let signedSpeed = simd_length(angularMomentumVec) / (rLen * rLen)
                    let directionSign: Float = angularMomentumVec.y >= 0 ? 1.0 : -1.0
                    sat.flingAngularImpulse = min(max(directionSign * signedSpeed, -8.5), 8.5)
                    entity.components.set(sat)
                }
                draggedSatelliteID = nil
                previousDragWorldPos = nil
                estimatedDragVelocity = .zero
            }
    }

    // MARK: - 90Hz SceneEvents.Update Physics & Spectral Core Pulsation

    private func stepOrbitalPhysicsAndSpectralCore(dt: Float) {
        accumulatedSceneTime += dt

        let subEnergy = coordinator.liveSubBandEnergy
        let lowEnergy = coordinator.liveLowBandEnergy
        let highEnergy = coordinator.liveHighBandEnergy
        let bloom = coordinator.synthParameters.bloomBoost

        // 1. Central Geodesic Core driven by Sub + Low FFT bands
        if let core = coreSunEntity {
            let corePulse = 1.0 + subEnergy * 0.38 + lowEnergy * 0.24 + bloom * 0.22
            core.scale = SIMD3<Float>(
                corePulse,
                corePulse * (1.0 + 0.08 * sinf(accumulatedSceneTime * 3.2)),
                corePulse
            )
            let spinRate = 0.42 + highEnergy * 1.65
            let rotY = simd_quatf(angle: accumulatedSceneTime * spinRate, axis: SIMD3<Float>(0, 1, 0))
            let rotZ = simd_quatf(angle: 0.22 * sinf(accumulatedSceneTime * 0.9), axis: SIMD3<Float>(0, 0, 1))
            core.orientation = rotY * rotZ
        }

        // 2. Parametric Keplerian Torus-Knot Halo driven by Low + High FFT bands
        if let knot = torusKnotEntity {
            let haloScale = 1.0 + lowEnergy * 0.16 + highEnergy * 0.28 + bloom * 0.15
            knot.scale = SIMD3<Float>(repeating: haloScale)
            let qY = simd_quatf(
                angle: accumulatedSceneTime * (0.30 + coordinator.synthParameters.binauralBeatHz * 0.018),
                axis: SIMD3<Float>(0, 1, 0)
            )
            let qX = simd_quatf(
                angle: 0.48 * sinf(accumulatedSceneTime * 0.52) + highEnergy * 0.35,
                axis: SIMD3<Float>(1, 0, 0)
            )
            knot.orientation = qY * qX
        }

        // 3. Inclined 3D Keplerian Elliptical Orbit Satellites with Fling Impulse Decay
        let spanScale = Float(min(max(coordinator.orbitalRadiusScale, 0.70), 1.45))
        let transportMultiplier: Float = (coordinator.isTimerRunning || coordinator.isSynthPlaying) ? 1.45 : 0.65

        for (id, entity) in satelliteEntities {
            guard id != draggedSatelliteID,
                  var sat = entity.components[OrbitalHabitSatelliteComponent.self] else {
                continue
            }

            let effectiveOmega = sat.baseAngularVelocity * transportMultiplier + sat.flingAngularImpulse
            sat.trueAnomaly = (sat.trueAnomaly + effectiveOmega * dt).truncatingRemainder(dividingBy: 2.0 * .pi)
            sat.flingAngularImpulse *= expf(-1.85 * dt)
            if abs(sat.flingAngularImpulse) < 1e-3 {
                sat.flingAngularImpulse = 0.0
            }
            entity.components.set(sat)

            let kepler = KeplerianOrbitParameters(
                semiMajorAxisMeters: sat.semiMajorAxisMeters,
                eccentricity: sat.eccentricity,
                inclinationRadians: sat.inclination,
                longitudeOfAscendingNodeRadians: sat.longitudeOfAscendingNode,
                trueAnomalyRadians: sat.trueAnomaly
            )
            entity.position = kepler.worldPosition(radiusScale: spanScale)
            entity.orientation = simd_quatf(
                angle: accumulatedSceneTime * (0.85 + abs(sat.flingAngularImpulse) * 0.4),
                axis: simd_normalize(SIMD3<Float>(0.24, 0.94, 0.22))
            )

            let isSelected = (id == coordinator.selectedHabitID)
            let baseScale: Float = isSelected ? 1.24 : 0.96
            let spectralBounce = 1.0 + (isSelected ? lowEnergy * 0.25 : highEnergy * 0.14)
            entity.scale = SIMD3<Float>(repeating: baseScale * spectralBounce)
        }
    }

    // MARK: - Procedural RealityKit Mesh & Localized Harmonic Overtone Generation

    private func makeRealityKitMeshResource(
        from meshData: ProceduralMeshData,
        meshName: String
    ) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: meshName)
        descriptor.positions = MeshBuffers.Positions(meshData.positions)
        descriptor.normals = MeshBuffers.Normals(meshData.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(meshData.uvs)
        descriptor.primitives = .triangles(meshData.indices)
        return try MeshResource.generate(from: [descriptor])
    }

    private func rebuildProceduralCoreAndKnotIfNeeded() {
        guard coreSunEntity == nil else { return }

        let coreResource: MeshResource
        if let existingCoreMesh = cachedCoreMesh {
            coreResource = existingCoreMesh
        } else {
            let coreMeshData = ProceduralMeshGenerator.generateGeodesicIcosahedron(
                radius: 0.078,
                subdivisions: 3
            )
            let generated = (try? makeRealityKitMeshResource(
                from: coreMeshData,
                meshName: "GeodesicHarmonicCore"
            )) ?? .generateSphere(radius: 0.078)
            cachedCoreMesh = generated
            coreResource = generated
        }

        var coreMaterial = PhysicallyBasedMaterial()
        coreMaterial.baseColor = .init(tint: UIColor(red: 0.16, green: 0.86, blue: 0.99, alpha: 1.0))
        coreMaterial.metallic = .init(floatLiteral: 0.92)
        coreMaterial.roughness = .init(floatLiteral: 0.12)
        coreMaterial.emissiveColor = .init(color: UIColor(red: 0.08, green: 0.62, blue: 0.98, alpha: 1.0))
        coreMaterial.emissiveIntensity = 2.05

        let coreEntity = ModelEntity(mesh: coreResource, materials: [coreMaterial])
        coreEntity.name = "CentralGeodesicSun"
        coreEntity.components.set(InputTargetComponent(allowedInputTypes: .all))
        coreEntity.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.088)]))
        coreEntity.components.set(HoverEffectComponent())

        var coreSpatialAudio = SpatialAudioComponent()
        coreSpatialAudio.gain = -4.0
        coreSpatialAudio.directivity = .beam(focus: 0.25)
        coreEntity.components.set(coreSpatialAudio)

        rootAnchorEntity.addChild(coreEntity)
        self.coreSunEntity = coreEntity

        let knotResource: MeshResource?
        if let existingKnotMesh = cachedKnotMesh {
            knotResource = existingKnotMesh
        } else {
            let knotMeshData = ProceduralMeshGenerator.generateKeplerianTorusKnot(
                p: 2,
                q: 3,
                majorRadius: 0.135,
                tubeRadius: 0.013,
                tubularSegments: 128,
                radialSegments: 18
            )
            let generated = try? makeRealityKitMeshResource(
                from: knotMeshData,
                meshName: "KeplerianTorusKnotHalo"
            )
            cachedKnotMesh = generated
            knotResource = generated
        }

        if let knotResource {
            var knotMaterial = PhysicallyBasedMaterial()
            knotMaterial.baseColor = .init(tint: UIColor(red: 0.62, green: 0.42, blue: 0.98, alpha: 1.0))
            knotMaterial.metallic = .init(floatLiteral: 0.94)
            knotMaterial.roughness = .init(floatLiteral: 0.16)
            knotMaterial.emissiveColor = .init(color: UIColor(red: 0.46, green: 0.26, blue: 0.95, alpha: 1.0))
            knotMaterial.emissiveIntensity = 1.45

            let knotEntity = ModelEntity(mesh: knotResource, materials: [knotMaterial])
            knotEntity.name = "KeplerianTorusHarmonicRing"
            knotEntity.components.set(InputTargetComponent(allowedInputTypes: .all))
            knotEntity.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.155)]))
            knotEntity.components.set(HoverEffectComponent())
            rootAnchorEntity.addChild(knotEntity)
            self.torusKnotEntity = knotEntity
        }
    }

    private func rebuildHabitSatellites(using nodes: [HabitNodeDTO]) {
        for (_, task) in audioLoadTasks {
            task.cancel()
        }
        audioLoadTasks.removeAll()

        for (_, controller) in audioControllers {
            controller.stop()
        }
        audioControllers.removeAll()

        for (_, existing) in satelliteEntities {
            existing.stopAllAudio()
            existing.removeFromParent()
        }
        satelliteEntities.removeAll()

        let sharedSatelliteMesh: MeshResource
        if let existingSatMesh = cachedSatelliteMesh {
            sharedSatelliteMesh = existingSatMesh
        } else {
            let baseSatelliteMeshData = ProceduralMeshGenerator.generateGeodesicIcosahedron(
                radius: 0.028,
                subdivisions: 2
            )
            let generated = (try? makeRealityKitMeshResource(
                from: baseSatelliteMeshData,
                meshName: "HabitSatelliteGeodesic"
            )) ?? .generateSphere(radius: 0.028)
            cachedSatelliteMesh = generated
            sharedSatelliteMesh = generated
        }

        let justIntonationRatios: [Float] = [1.0, 1.25, 1.5, 1.875, 2.0, 2.5]
        let total = max(1, nodes.count)

        for (idx, habit) in nodes.enumerated() {
            let frac = Float(idx) / Float(total)
            let semiMajor: Float = 0.19 + Float(idx % 4) * 0.042
            let eccentricity: Float = 0.09 + Float(idx % 3) * 0.06
            let inclination: Float = (Float(idx % 3) - 1.0) * 0.38
            let ascendingNode: Float = frac * Float.pi * 2.0
            let angularSpeed: Float = 0.52 / powf(max(0.12, semiMajor * 4.2), 1.25)
            let harmonicRatio = justIntonationRatios[idx % justIntonationRatios.count]

            let uiTint = UIColor(
                hue: CGFloat(habit.accentHue),
                saturation: 0.80,
                brightness: 0.98,
                alpha: 1.0
            )
            let uiEmissive = UIColor(
                hue: CGFloat(habit.accentHue),
                saturation: 0.86,
                brightness: 0.88,
                alpha: 1.0
            )

            var satMaterial = PhysicallyBasedMaterial()
            satMaterial.baseColor = .init(tint: uiTint)
            satMaterial.metallic = .init(floatLiteral: 0.84)
            satMaterial.roughness = .init(floatLiteral: 0.20)
            satMaterial.emissiveColor = .init(color: uiEmissive)
            satMaterial.emissiveIntensity = habit.habitID == coordinator.selectedHabitID ? 2.3 : 1.15

            let satEntity = ModelEntity(mesh: sharedSatelliteMesh, materials: [satMaterial])
            satEntity.name = "HabitSatellite_\(habit.title)"

            let satComponent = OrbitalHabitSatelliteComponent(
                habitID: habit.habitID,
                habitTitle: habit.title,
                accentHue: habit.accentHue,
                semiMajorAxisMeters: semiMajor,
                eccentricity: eccentricity,
                inclination: inclination,
                longitudeOfAscendingNode: ascendingNode,
                trueAnomaly: frac * Float.pi * 2.0,
                baseAngularVelocity: angularSpeed,
                flingAngularImpulse: 0.0,
                harmonicRatio: harmonicRatio
            )
            satEntity.components.set(satComponent)
            satEntity.components.set(InputTargetComponent(allowedInputTypes: .all))
            satEntity.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.040)]))
            satEntity.components.set(HoverEffectComponent())

            var satAudio = SpatialAudioComponent()
            satAudio.gain = -14.0
            satAudio.directivity = .beam(focus: 0.35)
            satEntity.components.set(satAudio)

            rootAnchorEntity.addChild(satEntity)
            satelliteEntities[habit.habitID] = satEntity

            attachLocalizedHarmonicOvertone(
                to: satEntity,
                habitID: habit.habitID,
                frequencyHz: Double(216.0 * harmonicRatio)
            )
        }

        lastBuiltHabitSignature = habitSignature(for: habits)
    }

    private func attachLocalizedHarmonicOvertone(
        to entity: ModelEntity,
        habitID: UUID,
        frequencyHz: Double
    ) {
        audioLoadTasks[habitID]?.cancel()
        audioLoadTasks[habitID] = Task { @MainActor [weak entity] in
            guard !Task.isCancelled,
                  let wavURL = Self.writeSeamlessHarmonicOvertoneWAV(
                      habitID: habitID,
                      frequencyHz: frequencyHz
                  ) else { return }

            let config = AudioFileResource.Configuration(shouldLoop: true)
            guard let resource = try? await AudioFileResource(contentsOf: wavURL, configuration: config),
                  !Task.isCancelled,
                  let entity,
                  entity.parent != nil,
                  satelliteEntities[habitID] === entity else {
                return
            }

            let controller = entity.prepareAudio(resource)
            audioControllers[habitID] = controller
            if coordinator.isTimerRunning || coordinator.isSynthPlaying {
                controller.play()
            }
        }
    }

    private func tearDownVolumetricScene() {
        sceneUpdateSubscription?.cancel()
        sceneUpdateSubscription = nil

        for (_, task) in audioLoadTasks {
            task.cancel()
        }
        audioLoadTasks.removeAll()

        for (_, controller) in audioControllers {
            controller.stop()
        }
        audioControllers.removeAll()

        for (_, entity) in satelliteEntities {
            entity.stopAllAudio()
            entity.removeFromParent()
        }
        satelliteEntities.removeAll()

        coreSunEntity?.stopAllAudio()
        coreSunEntity?.removeFromParent()
        coreSunEntity = nil

        torusKnotEntity?.removeFromParent()
        torusKnotEntity = nil

        rootAnchorEntity.children.removeAll()
        draggedSatelliteID = nil
        previousDragWorldPos = nil
        estimatedDragVelocity = .zero
        lastBuiltHabitSignature = ""
    }

    private func syncSpatialAudioPlaybackStates() {
        let shouldPlay = coordinator.isTimerRunning || coordinator.isSynthPlaying
        for (_, controller) in audioControllers {
            if shouldPlay && !controller.isPlaying {
                controller.play()
            } else if !shouldPlay && controller.isPlaying {
                controller.pause()
            }
        }
    }

    /// Synthesizes an integer-period phase-continuous 16-bit mono WAV harmonic overtone for SpatialAudioComponent.
    private static func writeSeamlessHarmonicOvertoneWAV(
        habitID: UUID,
        frequencyHz: Double
    ) -> URL? {
        let sampleRate = 24_000
        let cycles = max(24, Int((frequencyHz * 0.5).rounded()))
        let frameCount = max(2_400, Int((Double(cycles) * Double(sampleRate) / max(40.0, frequencyHz)).rounded()))
        let exactFreq = (Double(cycles) * Double(sampleRate)) / Double(frameCount)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-harmonic-\(habitID.uuidString).wav")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        var pcmSamples = [Int16](repeating: 0, count: frameCount)
        let twoPi = 2.0 * Double.pi
        for i in 0..<frameCount {
            let phase = twoPi * exactFreq * Double(i) / Double(sampleRate)
            let fundamental = sin(phase) * 0.72
            let octave = sin(phase * 2.0) * 0.22
            let fifth = sin(phase * 3.0) * 0.06
            let normalized = max(-0.98, min(0.98, (fundamental + octave + fifth) * 0.22))
            pcmSamples[i] = Int16(normalized * Double(Int16.max))
        }

        let dataBytes = frameCount * 2
        let riffChunkSize = UInt32(36 + dataBytes)
        let byteRate = UInt32(sampleRate * 2)
        var wavData = Data(capacity: 44 + dataBytes)

        wavData.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: riffChunkSize.littleEndian) { wavData.append(contentsOf: $0) }
        wavData.append(contentsOf: "WAVEfmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { wavData.append(contentsOf: $0) }     // PCM
        withUnsafeBytes(of: UInt16(1).littleEndian) { wavData.append(contentsOf: $0) }     // Mono
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(2).littleEndian) { wavData.append(contentsOf: $0) }     // Block align
        withUnsafeBytes(of: UInt16(16).littleEndian) { wavData.append(contentsOf: $0) }    // 16-bit
        wavData.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: UInt32(dataBytes).littleEndian) { wavData.append(contentsOf: $0) }

        pcmSamples.withUnsafeBytes { rawBuf in
            wavData.append(contentsOf: rawBuf)
        }

        do {
            try wavData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Volumetric Front Ornament HUD & Helpers

    private var volumetricControlOrnament: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.selectedHabitTitle)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(
                    String(
                        format: "%@ · %.1f Hz Beat · %.0f Hz SVF",
                        coordinator.formattedRemainingTime,
                        coordinator.synthParameters.binauralBeatHz,
                        coordinator.synthParameters.filterCutoffHz
                    )
                )
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Button {
                coordinator.toggleFocusTimer(linkedHabitTitle: nil)
            } label: {
                Label(
                    coordinator.isTimerRunning ? "Pause" : "Focus",
                    systemImage: coordinator.isTimerRunning ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)

            Button {
                if let activeHabit = habits.first(where: { $0.habitID == coordinator.selectedHabitID }) ?? habits.first {
                    Task { await coordinator.logQuickHabitIncrement(activeHabit, minutes: 15) }
                    coordinator.triggerManualHarmonicBloom(intensity: 0.92)
                } else {
                    coordinator.triggerManualHarmonicBloom(intensity: 0.92)
                }
            } label: {
                Label("+15m Pulse", systemImage: "bolt.heart.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassBackgroundEffect()
    }

    private func resolvedHabitDTOs() -> [HabitNodeDTO] {
        if !habits.isEmpty {
            return habits.map(HabitNodeDTO.init(model:))
        }
        return [
            HabitNodeDTO(title: "Systems Architecture", symbolName: "cpu.fill", accentHue: 0.54, orbitalMass: 1.45),
            HabitNodeDTO(title: "Shader & Math Study", symbolName: "sparkles", accentHue: 0.78, orbitalMass: 1.25),
            HabitNodeDTO(title: "Breathwork & Stillness", symbolName: "wind", accentHue: 0.42, orbitalMass: 1.05),
            HabitNodeDTO(title: "Acoustic Synthesis", symbolName: "waveform.path.ecg", accentHue: 0.90, orbitalMass: 1.35)
        ]
    }

    private func habitSignature(for list: [HabitNode]) -> String {
        list.map {
            String(
                format: "%@:%@:%.3f",
                $0.habitID.uuidString,
                $0.title,
                $0.accentHue
            )
        }.joined(separator: "|")
    }
}
#endif
