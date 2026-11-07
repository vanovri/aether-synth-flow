// MARK: - FILE: MetalAcousticRayTracer.swift

import Foundation
import simd
import Accelerate
import os
#if canImport(Metal)
import Metal
#endif

// MARK: - 1. Octave Bands, Acoustic Surface Materials & Architectural Chambers

public enum AcousticOctaveBand: Int, CaseIterable, Codable, Sendable, Identifiable {
    case hz125 = 0
    case hz500 = 1
    case hz2000 = 2
    case hz8000 = 3

    public var id: Int { rawValue }

    public var centerFrequencyHz: Float {
        switch self {
        case .hz125: return 125.0
        case .hz500: return 500.0
        case .hz2000: return 2_000.0
        case .hz8000: return 8_000.0
        }
    }

    public var shortLabel: String {
        switch self {
        case .hz125: return "125 Hz"
        case .hz500: return "500 Hz"
        case .hz2000: return "2 kHz"
        case .hz8000: return "8 kHz"
        }
    }
}

public struct AcousticSurfaceMaterial: Sendable, Equatable, Codable {
    public let name: String
    /// 4-band absorption coefficients alpha_b in [0.01, 0.95] at (125, 500, 2000, 8000 Hz)
    public let absorption: SIMD4<Float>
    /// 4-band Lambertian scattering coefficients s_b in [0.05, 0.95] at (125, 500, 2000, 8000 Hz)
    public let scattering: SIMD4<Float>

    public init(name: String, absorption: SIMD4<Float>, scattering: SIMD4<Float>) {
        self.name = name
        self.absorption = simd_clamp(
            absorption,
            SIMD4<Float>(repeating: 0.01),
            SIMD4<Float>(repeating: 0.95)
        )
        self.scattering = simd_clamp(
            scattering,
            SIMD4<Float>(repeating: 0.05),
            SIMD4<Float>(repeating: 0.95)
        )
    }

    public static func uniform(
        absorptionScalar: Float,
        scatteringScalar: Float = 0.35,
        name: String = "Uniform Calibration Surface"
    ) -> AcousticSurfaceMaterial {
        AcousticSurfaceMaterial(
            name: name,
            absorption: SIMD4<Float>(repeating: absorptionScalar),
            scattering: SIMD4<Float>(repeating: scatteringScalar)
        )
    }
}

public enum AcousticSurfaceMaterialPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case obsidianMarble = "obsidian_marble"
    case perforatedAcousticWood = "perforated_acoustic_wood"
    case brushedTitanium = "brushed_titanium"
    case velvetDiffuser = "velvet_diffuser"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .obsidianMarble: return "Obsidian Marble"
        case .perforatedAcousticWood: return "Perforated Acoustic Wood"
        case .brushedTitanium: return "Brushed Titanium"
        case .velvetDiffuser: return "Velvet Diffuser"
        }
    }

    public var material: AcousticSurfaceMaterial {
        switch self {
        case .obsidianMarble:
            return AcousticSurfaceMaterial(
                name: displayName,
                absorption: SIMD4<Float>(0.015, 0.024, 0.038, 0.058),
                scattering: SIMD4<Float>(0.05, 0.07, 0.11, 0.16)
            )
        case .perforatedAcousticWood:
            return AcousticSurfaceMaterial(
                name: displayName,
                absorption: SIMD4<Float>(0.16, 0.42, 0.56, 0.48),
                scattering: SIMD4<Float>(0.24, 0.44, 0.58, 0.52)
            )
        case .brushedTitanium:
            return AcousticSurfaceMaterial(
                name: displayName,
                absorption: SIMD4<Float>(0.03, 0.05, 0.08, 0.13),
                scattering: SIMD4<Float>(0.08, 0.14, 0.22, 0.30)
            )
        case .velvetDiffuser:
            return AcousticSurfaceMaterial(
                name: displayName,
                absorption: SIMD4<Float>(0.26, 0.64, 0.85, 0.94),
                scattering: SIMD4<Float>(0.54, 0.76, 0.88, 0.95)
            )
        }
    }
}

public enum AcousticChamberPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case geodesicSanctuary = "geodesic_sanctuary"
    case vaultedCathedral = "vaulted_cathedral"
    case hexagonalDiffuserStudio = "hexagonal_diffuser_studio"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .geodesicSanctuary: return "Geodesic Sanctuary"
        case .vaultedCathedral: return "Vaulted Cathedral"
        case .hexagonalDiffuserStudio: return "Hexagonal Studio"
        }
    }
}

public struct ListenerHeadPose3D: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var right: SIMD3<Float>
    public var up: SIMD3<Float>
    public var forward: SIMD3<Float>
    public var captureRadiusMeters: Float

    public init(
        position: SIMD3<Float> = SIMD3<Float>(0.0, 0.0, 0.0),
        yawRadians: Float = 0.0,
        pitchRadians: Float = 0.0,
        captureRadiusMeters: Float = 0.28
    ) {
        self.position = position
        self.captureRadiusMeters = max(0.08, captureRadiusMeters)

        let cy = cosf(yawRadians)
        let sy = sinf(yawRadians)
        let cp = cosf(pitchRadians)
        let sp = sinf(pitchRadians)

        let fwd = simd_normalize(SIMD3<Float>(sy * cp, sp, cy * cp))
        let worldUp = SIMD3<Float>(0.0, 1.0, 0.0)
        let rgt = simd_normalize(simd_cross(worldUp, fwd))
        let u = simd_normalize(simd_cross(fwd, rgt))

        self.right = rgt
        self.up = u
        self.forward = fwd
    }
}

public struct TracedAcousticRaySegment: Sendable, Equatable {
    public let start: SIMD3<Float>
    public let end: SIMD3<Float>
    public let bounceIndex: Int
    public let dominantBand: Int
    public let bandEnergy: SIMD4<Float>

    public init(
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        bounceIndex: Int,
        dominantBand: Int,
        bandEnergy: SIMD4<Float>
    ) {
        self.start = start
        self.end = end
        self.bounceIndex = bounceIndex
        self.dominantBand = dominantBand
        self.bandEnergy = bandEnergy
    }
}

public struct AcousticTraceReport: Sendable, Equatable {
    public let chamber: AcousticChamberPreset
    public let materialName: String
    public let usedHardwareRayTracing: Bool
    public let rayCount: Int
    public let maxBounces: Int
    public let triangleCount: Int
    public let leakedRayCount: Int
    public let chamberVolumeCubicMeters: Float
    public let chamberSurfaceAreaSqMeters: Float
    public let sabineRT60PerBand: SIMD4<Float>
    public let eyringRT60PerBand: SIMD4<Float>
    public let rayTracedRT60PerBand: SIMD4<Float>
    public let bounceMeanEnergyEnvelope: [SIMD4<Float>]
    public let directionalEDH: [SIMD4<Float>] // [dirSector * timeBinCount + timeBin]
    public let timeBinCount: Int
    public let directionSectorCount: Int
    public let timeBinDurationSeconds: Float
    public let leftDRIR: [Float]
    public let rightDRIR: [Float]
    public let raySegments: [TracedAcousticRaySegment]

    public init(
        chamber: AcousticChamberPreset,
        materialName: String,
        usedHardwareRayTracing: Bool,
        rayCount: Int,
        maxBounces: Int,
        triangleCount: Int,
        leakedRayCount: Int,
        chamberVolumeCubicMeters: Float,
        chamberSurfaceAreaSqMeters: Float,
        sabineRT60PerBand: SIMD4<Float>,
        eyringRT60PerBand: SIMD4<Float>,
        rayTracedRT60PerBand: SIMD4<Float>,
        bounceMeanEnergyEnvelope: [SIMD4<Float>],
        directionalEDH: [SIMD4<Float>],
        timeBinCount: Int,
        directionSectorCount: Int,
        timeBinDurationSeconds: Float,
        leftDRIR: [Float],
        rightDRIR: [Float],
        raySegments: [TracedAcousticRaySegment]
    ) {
        self.chamber = chamber
        self.materialName = materialName
        self.usedHardwareRayTracing = usedHardwareRayTracing
        self.rayCount = rayCount
        self.maxBounces = maxBounces
        self.triangleCount = triangleCount
        self.leakedRayCount = leakedRayCount
        self.chamberVolumeCubicMeters = chamberVolumeCubicMeters
        self.chamberSurfaceAreaSqMeters = chamberSurfaceAreaSqMeters
        self.sabineRT60PerBand = sabineRT60PerBand
        self.eyringRT60PerBand = eyringRT60PerBand
        self.rayTracedRT60PerBand = rayTracedRT60PerBand
        self.bounceMeanEnergyEnvelope = bounceMeanEnergyEnvelope
        self.directionalEDH = directionalEDH
        self.timeBinCount = timeBinCount
        self.directionSectorCount = directionSectorCount
        self.timeBinDurationSeconds = timeBinDurationSeconds
        self.leftDRIR = leftDRIR
        self.rightDRIR = rightDRIR
        self.raySegments = raySegments
    }
}

// MARK: - 2. Acoustic Chamber & Orbiting HabitNode Mesh Extensions on ProceduralMeshGenerator

public struct AcousticMeshTriangle: Sendable, Equatable {
    public let v0: SIMD3<Float>
    public let v1: SIMD3<Float>
    public let v2: SIMD3<Float>
    public let normal: SIMD3<Float>
    public let area: Float
    public let centroid: SIMD3<Float>
    public let boundsMin: SIMD3<Float>
    public let boundsMax: SIMD3<Float>
    public let materialIndex: Int

    public init(
        v0: SIMD3<Float>,
        v1: SIMD3<Float>,
        v2: SIMD3<Float>,
        preferredNormal: SIMD3<Float>? = nil,
        materialIndex: Int = 0
    ) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
        let crossVec = simd_cross(v1 - v0, v2 - v0)
        let crossLen = simd_length(crossVec)
        self.area = 0.5 * crossLen
        let rawN = crossLen > 1.0e-8 ? (crossVec / crossLen) : SIMD3<Float>(0.0, 1.0, 0.0)
        if let pref = preferredNormal, simd_dot(rawN, pref) < 0.0 {
            self.normal = -rawN
        } else {
            self.normal = rawN
        }
        self.centroid = (v0 + v1 + v2) * (1.0 / 3.0)
        let eps = SIMD3<Float>(repeating: 1.0e-4)
        self.boundsMin = simd_min(v0, simd_min(v1, v2)) - eps
        self.boundsMax = simd_max(v0, simd_max(v1, v2)) + eps
        self.materialIndex = max(0, materialIndex)
    }
}

public struct AcousticChamberGeometry: Sendable, Equatable {
    public let vertices: [SIMD3<Float>]
    public let indices: [UInt32]
    public let triangles: [AcousticMeshTriangle]
    public let enclosedVolumeCubicMeters: Float
    public let totalSurfaceAreaSqMeters: Float

    public init(
        vertices: [SIMD3<Float>],
        indices: [UInt32],
        triangles: [AcousticMeshTriangle],
        enclosedVolumeCubicMeters: Float,
        totalSurfaceAreaSqMeters: Float
    ) {
        self.vertices = vertices
        self.indices = indices
        self.triangles = triangles
        self.enclosedVolumeCubicMeters = enclosedVolumeCubicMeters
        self.totalSurfaceAreaSqMeters = totalSurfaceAreaSqMeters
    }
}

public struct OrbitingSatelliteAcousticInstance: Sendable, Equatable {
    public let habitID: UUID
    public let center: SIMD3<Float>
    public let radiusMeters: Float
    public let materialIndex: Int
    public let worldTransform: simd_float4x4

    public init(
        habitID: UUID,
        center: SIMD3<Float>,
        radiusMeters: Float,
        materialIndex: Int,
        worldTransform: simd_float4x4
    ) {
        self.habitID = habitID
        self.center = center
        self.radiusMeters = radiusMeters
        self.materialIndex = materialIndex
        self.worldTransform = worldTransform
    }
}

extension ProceduralMeshGenerator {
    /// Builds a watertight axis-aligned closed box centered at origin `[-hx..hx] x [-hy..hy] x [-hz..hz]`
    /// with inward-pointing normals for analytical ray-plane validation.
    public static func makeClosedBoxRoom(
        halfExtents h: SIMD3<Float> = SIMD3<Float>(5.0, 3.0, 6.0),
        materialIndex: Int = 0
    ) -> AcousticChamberGeometry {
        let sx = max(0.5, h.x)
        let sy = max(0.5, h.y)
        let sz = max(0.5, h.z)

        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(-sx, -sy, -sz), // 0
            SIMD3<Float>( sx, -sy, -sz), // 1
            SIMD3<Float>( sx,  sy, -sz), // 2
            SIMD3<Float>(-sx,  sy, -sz), // 3
            SIMD3<Float>(-sx, -sy,  sz), // 4
            SIMD3<Float>( sx, -sy,  sz), // 5
            SIMD3<Float>( sx,  sy,  sz), // 6
            SIMD3<Float>(-sx,  sy,  sz)  // 7
        ]

        let rawQuads: [(Int, Int, Int, Int, SIMD3<Float>)] = [
            (0, 4, 7, 3, SIMD3<Float>( 1,  0,  0)), // -X wall -> +X inward
            (1, 2, 6, 5, SIMD3<Float>(-1,  0,  0)), // +X wall -> -X inward
            (0, 1, 5, 4, SIMD3<Float>( 0,  1,  0)), // -Y floor -> +Y inward
            (3, 7, 6, 2, SIMD3<Float>( 0, -1,  0)), // +Y ceiling -> -Y inward
            (0, 3, 2, 1, SIMD3<Float>( 0,  0,  1)), // -Z back -> +Z inward
            (4, 5, 6, 7, SIMD3<Float>( 0,  0, -1))  // +Z front -> -Z inward
        ]

        var indices: [UInt32] = []
        var triangles: [AcousticMeshTriangle] = []
        indices.reserveCapacity(36)
        triangles.reserveCapacity(12)

        for (a, b, c, d, inN) in rawQuads {
            indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c), UInt32(a), UInt32(c), UInt32(d)])
            triangles.append(AcousticMeshTriangle(v0: verts[a], v1: verts[b], v2: verts[c], preferredNormal: inN, materialIndex: materialIndex))
            triangles.append(AcousticMeshTriangle(v0: verts[a], v1: verts[c], v2: verts[d], preferredNormal: inN, materialIndex: materialIndex))
        }

        let volume = 8.0 * sx * sy * sz
        let area = 8.0 * (sx * sy + sy * sz + sz * sx)
        return AcousticChamberGeometry(
            vertices: verts,
            indices: indices,
            triangles: triangles,
            enclosedVolumeCubicMeters: volume,
            totalSurfaceAreaSqMeters: area
        )
    }

    /// Builds a watertight Geodesic Sanctuary chamber (subdivided icosahedron scaled into an architectural dome).
    public static func makeGeodesicSanctuary(
        radiusMeters: Float = 7.5,
        verticalScale: Float = 0.78,
        subdivisions: Int = 2,
        materialIndex: Int = 0
    ) -> AcousticChamberGeometry {
        let mesh = makeGeodesicIcosahedron(radius: max(2.0, radiusMeters), subdivisions: min(max(subdivisions, 1), 3))
        let scaleVec = SIMD3<Float>(1.0, max(0.45, verticalScale), 1.0)
        let scaledPositions = mesh.positions.map { $0 * scaleVec }

        var triangles: [AcousticMeshTriangle] = []
        triangles.reserveCapacity(mesh.indices.count / 3)
        var signedVol6: Float = 0.0
        var totalArea: Float = 0.0

        var idx = 0
        while idx + 2 < mesh.indices.count {
            let i0 = Int(mesh.indices[idx])
            let i1 = Int(mesh.indices[idx + 1])
            let i2 = Int(mesh.indices[idx + 2])
            let p0 = scaledPositions[i0]
            let p1 = scaledPositions[i1]
            let p2 = scaledPositions[i2]
            let inwardDir = -simd_normalize((p0 + p1 + p2) * (1.0 / 3.0))
            let tri = AcousticMeshTriangle(v0: p0, v1: p1, v2: p2, preferredNormal: inwardDir, materialIndex: materialIndex)
            triangles.append(tri)
            totalArea += tri.area
            signedVol6 += abs(simd_dot(p0, simd_cross(p1, p2)))
            idx += 3
        }

        return AcousticChamberGeometry(
            vertices: scaledPositions,
            indices: mesh.indices,
            triangles: triangles,
            enclosedVolumeCubicMeters: max(12.0, signedVol6 / 6.0),
            totalSurfaceAreaSqMeters: max(16.0, totalArea)
        )
    }

    /// Builds a watertight polygonal prism + vaulted apex chamber used for Vaulted Cathedral & Hexagonal Diffuser Studio.
    private static func makeClosedArchitecturalVault(
        sides: Int,
        radiusX: Float,
        radiusZ: Float,
        floorY: Float,
        eaveY: Float,
        apexY: Float,
        corrugationDepth: Float,
        materialIndex: Int
    ) -> AcousticChamberGeometry {
        let n = max(6, sides)
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(2 * n + 2)

        for k in 0..<n {
            let angle = (2.0 * Float.pi * Float(k)) / Float(n)
            let ripple: Float = (k % 2 == 1) ? (1.0 - corrugationDepth) : 1.0
            let x = cosf(angle) * radiusX * ripple
            let z = sinf(angle) * radiusZ * ripple
            verts.append(SIMD3<Float>(x, floorY, z))
        }
        for k in 0..<n {
            let angle = (2.0 * Float.pi * Float(k)) / Float(n)
            let ripple: Float = (k % 2 == 1) ? (1.0 - corrugationDepth) : 1.0
            let x = cosf(angle) * radiusX * ripple
            let z = sinf(angle) * radiusZ * ripple
            verts.append(SIMD3<Float>(x, eaveY, z))
        }

        let floorCenterIdx = verts.count
        verts.append(SIMD3<Float>(0.0, floorY, 0.0))
        let apexCenterIdx = verts.count
        verts.append(SIMD3<Float>(0.0, apexY, 0.0))

        let interiorRef = SIMD3<Float>(0.0, 0.5 * (floorY + eaveY), 0.0)
        var indices: [UInt32] = []
        var triangles: [AcousticMeshTriangle] = []
        triangles.reserveCapacity(4 * n)

        func addTri(_ a: Int, _ b: Int, _ c: Int) {
            let pa = verts[a]
            let pb = verts[b]
            let pc = verts[c]
            let centroid = (pa + pb + pc) * (1.0 / 3.0)
            let toCenter = interiorRef - centroid
            let tri = AcousticMeshTriangle(v0: pa, v1: pb, v2: pc, preferredNormal: toCenter, materialIndex: materialIndex)
            triangles.append(tri)
            indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
        }

        for k in 0..<n {
            let next = (k + 1) % n
            let b0 = k
            let b1 = next
            let t0 = n + k
            let t1 = n + next

            // Perimeter wall quad (2 triangles)
            addTri(b0, b1, t1)
            addTri(b0, t1, t0)
            // Floor fan triangle
            addTri(floorCenterIdx, b1, b0)
            // Vaulted ceiling fan triangle
            addTri(apexCenterIdx, t0, t1)
        }

        var totalArea: Float = 0.0
        var volSum: Float = 0.0
        for tri in triangles {
            totalArea += tri.area
            let v0 = tri.v0 - interiorRef
            let v1 = tri.v1 - interiorRef
            let v2 = tri.v2 - interiorRef
            volSum += abs(simd_dot(v0, simd_cross(v1, v2))) * (1.0 / 6.0)
        }

        return AcousticChamberGeometry(
            vertices: verts,
            indices: indices,
            triangles: triangles,
            enclosedVolumeCubicMeters: max(20.0, volSum),
            totalSurfaceAreaSqMeters: max(20.0, totalArea)
        )
    }

    public static func makeVaultedCathedral(materialIndex: Int = 0) -> AcousticChamberGeometry {
        makeClosedArchitecturalVault(
            sides: 12,
            radiusX: 10.5,
            radiusZ: 18.0,
            floorY: -2.4,
            eaveY: 7.2,
            apexY: 12.8,
            corrugationDepth: 0.06,
            materialIndex: materialIndex
        )
    }

    public static func makeHexagonalDiffuserStudio(materialIndex: Int = 0) -> AcousticChamberGeometry {
        makeClosedArchitecturalVault(
            sides: 12,
            radiusX: 4.8,
            radiusZ: 5.4,
            floorY: -1.6,
            eaveY: 2.1,
            apexY: 2.8,
            corrugationDepth: 0.16,
            materialIndex: materialIndex
        )
    }

    public static func makeChamberGeometry(
        preset: AcousticChamberPreset,
        materialIndex: Int = 0
    ) -> AcousticChamberGeometry {
        switch preset {
        case .geodesicSanctuary:
            return makeGeodesicSanctuary(materialIndex: materialIndex)
        case .vaultedCathedral:
            return makeVaultedCathedral(materialIndex: materialIndex)
        case .hexagonalDiffuserStudio:
            return makeHexagonalDiffuserStudio(materialIndex: materialIndex)
        }
    }

    /// Generates dynamic orbiting `HabitNode` satellite polyhedra and world-space acoustic triangles.
    public static func buildOrbitingSatellites(
        habits: [HabitNodeDTO],
        orbitalPhaseRadians: Float,
        satelliteMaterialIndex: Int = 1
    ) -> (instances: [OrbitingSatelliteAcousticInstance], unitMesh: ProceduralMeshData, worldTriangles: [AcousticMeshTriangle]) {
        let unitMesh = makeGeodesicIcosahedron(radius: 1.0, subdivisions: 1)
        guard !habits.isEmpty else {
            return ([], unitMesh, [])
        }

        let capped = Array(habits.prefix(8))
        let count = capped.count
        var instances: [OrbitingSatelliteAcousticInstance] = []
        var worldTris: [AcousticMeshTriangle] = []
        instances.reserveCapacity(count)
        worldTris.reserveCapacity(count * (unitMesh.indices.count / 3))

        for (idx, habit) in capped.enumerated() {
            let angle = orbitalPhaseRadians + (2.0 * Float.pi * Float(idx)) / Float(count)
            let orbitRadius: Float = 2.05 + 0.22 * Float(idx % 3)
            let verticalOffset: Float = 0.42 * sinf(angle * 1.5 + Float(idx))
            let center = SIMD3<Float>(
                cosf(angle) * orbitRadius,
                verticalOffset,
                sinf(angle) * orbitRadius
            )
            let radius = min(max(0.18 + 0.08 * Float(habit.orbitalMass), 0.16), 0.42)

            let transform = simd_float4x4(
                SIMD4<Float>(radius, 0, 0, 0),
                SIMD4<Float>(0, radius, 0, 0),
                SIMD4<Float>(0, 0, radius, 0),
                SIMD4<Float>(center.x, center.y, center.z, 1.0)
            )

            instances.append(
                OrbitingSatelliteAcousticInstance(
                    habitID: habit.habitID,
                    center: center,
                    radiusMeters: radius,
                    materialIndex: satelliteMaterialIndex,
                    worldTransform: transform
                )
            )

            var tIdx = 0
            while tIdx + 2 < unitMesh.indices.count {
                let p0 = center + unitMesh.positions[Int(unitMesh.indices[tIdx])] * radius
                let p1 = center + unitMesh.positions[Int(unitMesh.indices[tIdx + 1])] * radius
                let p2 = center + unitMesh.positions[Int(unitMesh.indices[tIdx + 2])] * radius
                let outward = simd_normalize(((p0 + p1 + p2) * (1.0 / 3.0)) - center)
                worldTris.append(
                    AcousticMeshTriangle(
                        v0: p0,
                        v1: p1,
                        v2: p2,
                        preferredNormal: outward,
                        materialIndex: satelliteMaterialIndex
                    )
                )
                tIdx += 3
            }
        }

        return (instances, unitMesh, worldTris)
    }
}

// MARK: - 3. Deterministic CPU SIMD SAH-BVH & Möller–Trumbore Ray-Triangle Solver

public struct AcousticRayHit: Sendable, Equatable {
    public let distance: Float
    public let point: SIMD3<Float>
    public let normal: SIMD3<Float>
    public let triangleIndex: Int
    public let materialIndex: Int
}

public struct AcousticSAHBVH: Sendable {
    public struct Node: Sendable, Equatable {
        public let boundsMin: SIMD3<Float>
        public let boundsMax: SIMD3<Float>
        public let leftOrFirst: Int
        public let rightChild: Int
        public let count: Int

        public var isLeaf: Bool { count > 0 }
    }

    public let triangles: [AcousticMeshTriangle]
    public let nodes: [Node]

    public init(triangles: [AcousticMeshTriangle]) {
        guard !triangles.isEmpty else {
            self.triangles = []
            self.nodes = []
            return
        }

        var ordered = triangles
        var builtNodes: [Node] = []
        builtNodes.reserveCapacity(triangles.count * 2)

        @inline(__always)
        func boxArea(_ mn: SIMD3<Float>, _ mx: SIMD3<Float>) -> Float {
            let e = simd_max(mx - mn, .zero)
            return 2.0 * (e.x * e.y + e.y * e.z + e.z * e.x)
        }

        func build(start: Int, count: Int) -> Int {
            var bMin = ordered[start].boundsMin
            var bMax = ordered[start].boundsMax
            var cMin = ordered[start].centroid
            var cMax = ordered[start].centroid

            for i in (start + 1)..<(start + count) {
                bMin = simd_min(bMin, ordered[i].boundsMin)
                bMax = simd_max(bMax, ordered[i].boundsMax)
                cMin = simd_min(cMin, ordered[i].centroid)
                cMax = simd_max(cMax, ordered[i].centroid)
            }

            let myIndex = builtNodes.count
            builtNodes.append(Node(boundsMin: bMin, boundsMax: bMax, leftOrFirst: start, rightChild: -1, count: count))

            guard count > 4 else {
                return myIndex
            }

            let extent = cMax - cMin
            var axis = 0
            if extent.y > extent.x && extent.y >= extent.z { axis = 1 }
            else if extent.z > extent.x && extent.z > extent.y { axis = 2 }

            guard extent[axis] > 1.0e-5 else {
                return myIndex
            }

            // 8-Bucket Surface Area Heuristic (SAH) evaluation
            let bucketCount = 8
            var bucketCounts = [Int](repeating: 0, count: bucketCount)
            var bucketMin = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: .greatestFiniteMagnitude), count: bucketCount)
            var bucketMax = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: -.greatestFiniteMagnitude), count: bucketCount)

            let invExtent = Float(bucketCount) / extent[axis]
            for i in start..<(start + count) {
                let rel = (ordered[i].centroid[axis] - cMin[axis]) * invExtent
                let b = min(max(Int(rel), 0), bucketCount - 1)
                bucketCounts[b] += 1
                bucketMin[b] = simd_min(bucketMin[b], ordered[i].boundsMin)
                bucketMax[b] = simd_max(bucketMax[b], ordered[i].boundsMax)
            }

            let parentArea = max(boxArea(bMin, bMax), 1.0e-6)
            var bestCost = Float(count)
            var bestSplitBucket = -1

            for split in 1..<bucketCount {
                var lMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var lMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                var lCount = 0
                for b in 0..<split where bucketCounts[b] > 0 {
                    lMin = simd_min(lMin, bucketMin[b])
                    lMax = simd_max(lMax, bucketMax[b])
                    lCount += bucketCounts[b]
                }

                var rMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var rMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                var rCount = 0
                for b in split..<bucketCount where bucketCounts[b] > 0 {
                    rMin = simd_min(rMin, bucketMin[b])
                    rMax = simd_max(rMax, bucketMax[b])
                    rCount += bucketCounts[b]
                }

                guard lCount > 0 && rCount > 0 else { continue }
                let cost = 0.125
                    + (boxArea(lMin, lMax) / parentArea) * Float(lCount)
                    + (boxArea(rMin, rMax) / parentArea) * Float(rCount)
                if cost < bestCost {
                    bestCost = cost
                    bestSplitBucket = split
                }
            }

            let midIndex: Int
            if bestSplitBucket > 0 {
                let threshold = cMin[axis] + (Float(bestSplitBucket) / Float(bucketCount)) * extent[axis]
                var leftCursor = start
                var rightCursor = start + count - 1
                while leftCursor <= rightCursor {
                    if ordered[leftCursor].centroid[axis] < threshold {
                        leftCursor += 1
                    } else {
                        ordered.swapAt(leftCursor, rightCursor)
                        rightCursor -= 1
                    }
                }
                if leftCursor == start || leftCursor == start + count {
                    ordered[start..<(start + count)].sort { $0.centroid[axis] < $1.centroid[axis] }
                    midIndex = start + count / 2
                } else {
                    midIndex = leftCursor
                }
            } else {
                ordered[start..<(start + count)].sort { $0.centroid[axis] < $1.centroid[axis] }
                midIndex = start + count / 2
            }

            let leftChild = build(start: start, count: midIndex - start)
            let rightChild = build(start: midIndex, count: start + count - midIndex)
            builtNodes[myIndex] = Node(
                boundsMin: bMin,
                boundsMax: bMax,
                leftOrFirst: leftChild,
                rightChild: rightChild,
                count: 0
            )
            return myIndex
        }

        _ = build(start: 0, count: ordered.count)
        self.triangles = ordered
        self.nodes = builtNodes
    }

    /// Exact Möller–Trumbore ray-triangle intersection with watertight edge tolerance.
    @inline(__always)
    public static func intersectTriangleMollerTrumbore(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        v0: SIMD3<Float>,
        v1: SIMD3<Float>,
        v2: SIMD3<Float>,
        minDistance: Float = 1.0e-4,
        maxDistance: Float = 1.0e6
    ) -> Float? {
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let pvec = simd_cross(direction, edge2)
        let det = simd_dot(edge1, pvec)
        if abs(det) < 1.0e-8 {
            return nil
        }

        let invDet = 1.0 / det
        let tvec = origin - v0
        let u = simd_dot(tvec, pvec) * invDet
        let tol: Float = -1.5e-5
        if u < tol || u > 1.0 - tol {
            return nil
        }

        let qvec = simd_cross(tvec, edge1)
        let v = simd_dot(direction, qvec) * invDet
        if v < tol || (u + v) > 1.0 - tol {
            return nil
        }

        let t = simd_dot(edge2, qvec) * invDet
        guard t >= minDistance && t <= maxDistance else {
            return nil
        }
        return t
    }

    @inline(__always)
    private static func intersectAABB(
        origin: SIMD3<Float>,
        invDir: SIMD3<Float>,
        bMin: SIMD3<Float>,
        bMax: SIMD3<Float>,
        maxT: Float
    ) -> Float? {
        let t0 = (bMin - origin) * invDir
        let t1 = (bMax - origin) * invDir
        let tSmaller = simd_min(t0, t1)
        let tBigger = simd_max(t0, t1)
        let tNear = max(0.0, max(tSmaller.x, max(tSmaller.y, tSmaller.z)))
        let tFar = min(maxT, min(tBigger.x, min(tBigger.y, tBigger.z)))
        return tNear <= tFar ? tNear : nil
    }

    public func traceClosestHit(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        minDistance: Float = 1.0e-4,
        maxDistance: Float = 1.0e5
    ) -> AcousticRayHit? {
        guard !nodes.isEmpty else { return nil }

        let safeDir = SIMD3<Float>(
            abs(direction.x) > 1.0e-8 ? direction.x : (direction.x >= 0 ? 1.0e-8 : -1.0e-8),
            abs(direction.y) > 1.0e-8 ? direction.y : (direction.y >= 0 ? 1.0e-8 : -1.0e-8),
            abs(direction.z) > 1.0e-8 ? direction.z : (direction.z >= 0 ? 1.0e-8 : -1.0e-8)
        )
        let invDir = 1.0 / safeDir

        var closestT = maxDistance
        var bestTriIdx = -1

        var stack = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        var sp = 1

        withUnsafeMutableBytes(of: &stack) { raw in
            let ptr = raw.bindMemory(to: Int.self).baseAddress!
            ptr[0] = 0

            while sp > 0 {
                sp -= 1
                let nodeIdx = ptr[sp]
                let node = nodes[nodeIdx]

                guard Self.intersectAABB(
                    origin: origin,
                    invDir: invDir,
                    bMin: node.boundsMin,
                    bMax: node.boundsMax,
                    maxT: closestT
                ) != nil else {
                    continue
                }

                if node.isLeaf {
                    let end = node.leftOrFirst + node.count
                    for idx in node.leftOrFirst..<end {
                        let tri = triangles[idx]
                        if let hitT = Self.intersectTriangleMollerTrumbore(
                            origin: origin,
                            direction: direction,
                            v0: tri.v0,
                            v1: tri.v1,
                            v2: tri.v2,
                            minDistance: minDistance,
                            maxDistance: closestT
                        ) {
                            closestT = hitT
                            bestTriIdx = idx
                        }
                    }
                } else if sp + 2 <= 32 {
                    let leftNode = nodes[node.leftOrFirst]
                    let rightNode = nodes[node.rightChild]
                    let dLeft = Self.intersectAABB(origin: origin, invDir: invDir, bMin: leftNode.boundsMin, bMax: leftNode.boundsMax, maxT: closestT)
                    let dRight = Self.intersectAABB(origin: origin, invDir: invDir, bMin: rightNode.boundsMin, bMax: rightNode.boundsMax, maxT: closestT)

                    if let dl = dLeft, let dr = dRight {
                        if dl < dr {
                            ptr[sp] = node.rightChild
                            ptr[sp + 1] = node.leftOrFirst
                        } else {
                            ptr[sp] = node.leftOrFirst
                            ptr[sp + 1] = node.rightChild
                        }
                        sp += 2
                    } else if dLeft != nil {
                        ptr[sp] = node.leftOrFirst
                        sp += 1
                    } else if dRight != nil {
                        ptr[sp] = node.rightChild
                        sp += 1
                    }
                }
            }
        }

        guard bestTriIdx >= 0 else { return nil }
        let hitTri = triangles[bestTriIdx]
        let hitN = simd_dot(hitTri.normal, direction) < 0.0 ? hitTri.normal : -hitTri.normal
        return AcousticRayHit(
            distance: closestT,
            point: origin + direction * closestT,
            normal: hitN,
            triangleIndex: bestTriIdx,
            materialIndex: hitTri.materialIndex
        )
    }

    public func isOccluded(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float
    ) -> Bool {
        traceClosestHit(origin: origin, direction: direction, minDistance: 1.0e-4, maxDistance: maxDistance) != nil
    }
}

// MARK: - 4. Directional Room Impulse Response (DRIR) Reconstructor & RT60 Analyzer

public enum DRIRReconstructor: Sendable {
    public static let drirTapCount: Int = 512
    public static let airAttenuationNepersPerMeter = SIMD4<Float>(0.00010, 0.00028, 0.00095, 0.00420)

    /// Sabine reverberation time `RT60 = 0.161 * V / (S * alpha_b + 4 * m_b * V)` across 4 octave bands.
    public static func computeSabineRT60(
        volumeCubicMeters v: Float,
        surfaceAreaSqMeters s: Float,
        meanAbsorption alpha: SIMD4<Float>
    ) -> SIMD4<Float> {
        let clampedAlpha = simd_clamp(alpha, SIMD4<Float>(repeating: 0.005), SIMD4<Float>(repeating: 0.99))
        let denom = s * clampedAlpha + 4.0 * airAttenuationNepersPerMeter * v
        return SIMD4<Float>(
            (0.161 * v) / max(1.0e-4, denom.x),
            (0.161 * v) / max(1.0e-4, denom.y),
            (0.161 * v) / max(1.0e-4, denom.z),
            (0.161 * v) / max(1.0e-4, denom.w)
        )
    }

    /// Eyring-Norris reverberation time `RT60 = 0.161 * V / (-S * ln(1 - alpha_b) + 4 * m_b * V)` across 4 octave bands.
    public static func computeEyringRT60(
        volumeCubicMeters v: Float,
        surfaceAreaSqMeters s: Float,
        meanAbsorption alpha: SIMD4<Float>
    ) -> SIMD4<Float> {
        let c = simd_clamp(alpha, SIMD4<Float>(repeating: 0.005), SIMD4<Float>(repeating: 0.99))
        let minusLog = SIMD4<Float>(
            -logf(1.0 - c.x),
            -logf(1.0 - c.y),
            -logf(1.0 - c.z),
            -logf(1.0 - c.w)
        )
        let denom = s * minusLog + 4.0 * airAttenuationNepersPerMeter * v
        return SIMD4<Float>(
            (0.161 * v) / max(1.0e-4, denom.x),
            (0.161 * v) / max(1.0e-4, denom.y),
            (0.161 * v) / max(1.0e-4, denom.z),
            (0.161 * v) / max(1.0e-4, denom.w)
        )
    }

    /// Computes ray-traced `T20 -> RT60` per octave band via Lundeby tail-compensated Schroeder backward integration.
    public static func computeRayTracedSchroederRT60(
        directionalEDH: [SIMD4<Float>],
        timeBinCount: Int,
        directionSectorCount: Int,
        timeBinDurationSeconds: Float
    ) -> SIMD4<Float> {
        guard timeBinCount >= 8, directionSectorCount >= 1, timeBinDurationSeconds > 0 else {
            return SIMD4<Float>(repeating: 0.25)
        }

        // Collapse directional sectors into omnidirectional 4-band energy decay histogram
        var omni = [SIMD4<Float>](repeating: .zero, count: timeBinCount)
        for s in 0..<directionSectorCount {
            let base = s * timeBinCount
            for t in 0..<timeBinCount where (base + t) < directionalEDH.count {
                omni[t] += directionalEDH[base + t]
            }
        }

        var result = SIMD4<Float>(repeating: 0.15)
        for band in 0..<4 {
            // Skip direct arrival spike in bin 0..1 when reverberant tail exists
            var firstReverbBin = 1
            while firstReverbBin < timeBinCount - 4 && omni[firstReverbBin][band] <= 0.0 {
                firstReverbBin += 1
            }

            // Estimate exponential tail rate on active reverberant bins for Lundeby truncation compensation
            var activeBins: [(t: Double, logE: Double)] = []
            activeBins.reserveCapacity(timeBinCount)
            for idx in firstReverbBin..<timeBinCount {
                let e = Double(omni[idx][band])
                if e > 1.0e-14 {
                    activeBins.append((Double(idx) * Double(timeBinDurationSeconds), log(e)))
                }
            }

            guard activeBins.count >= 3 else {
                result[band] = 0.08
                continue
            }

            // Fit late log-energy slope to compensate finite bounce truncation bias (Lundeby integral)
            let fitSlice = activeBins.suffix(max(3, activeBins.count * 3 / 4))
            let nFit = Double(fitSlice.count)
            let meanT = fitSlice.reduce(0.0) { $0 + $1.t } / nFit
            let meanL = fitSlice.reduce(0.0) { $0 + $1.logE } / nFit
            var covTL = 0.0
            var varT = 0.0
            for pt in fitSlice {
                let dt = pt.t - meanT
                covTL += dt * (pt.logE - meanL)
                varT += dt * dt
            }
            let lambdaDecay = (varT > 1.0e-12 && covTL < -1.0e-9) ? (-covTL / varT) : 12.0
            let lastActive = activeBins.last!
            let tailIntegral = exp(lastActive.logE) / max(0.25, lambdaDecay * Double(timeBinDurationSeconds))

            // Schroeder backward integration with analytical truncation remainder
            var edc = [Double](repeating: 0.0, count: timeBinCount)
            var accum = tailIntegral
            for idx in stride(from: timeBinCount - 1, through: firstReverbBin, by: -1) {
                accum += Double(max(0.0, omni[idx][band]))
                edc[idx] = accum
            }

            let e0 = max(edc[firstReverbBin], 1.0e-16)
            var regT: [Double] = []
            var regDB: [Double] = []
            for idx in firstReverbBin..<timeBinCount {
                let db = 10.0 * log10(max(edc[idx] / e0, 1.0e-12))
                if db <= -5.0 && db >= -25.0 {
                    regT.append(Double(idx - firstReverbBin) * Double(timeBinDurationSeconds))
                    regDB.append(db)
                }
            }

            if regT.count < 2 {
                for idx in firstReverbBin..<timeBinCount {
                    let db = 10.0 * log10(max(edc[idx] / e0, 1.0e-12))
                    if db <= -1.0 && db >= -35.0 {
                        regT.append(Double(idx - firstReverbBin) * Double(timeBinDurationSeconds))
                        regDB.append(db)
                    }
                }
            }

            if regT.count >= 2 {
                let c = Double(regT.count)
                let mt = regT.reduce(0.0, +) / c
                let my = regDB.reduce(0.0, +) / c
                var num = 0.0
                var den = 0.0
                for k in 0..<regT.count {
                    let dt = regT[k] - mt
                    num += dt * (regDB[k] - my)
                    den += dt * dt
                }
                if den > 1.0e-12 && num < -1.0e-9 {
                    let slope = num / den
                    result[band] = Float(min(max(-60.0 / slope, 0.03), 25.0))
                } else {
                    result[band] = Float(min(max(6.907755 / lambdaDecay, 0.03), 25.0))
                }
            } else {
                result[band] = Float(min(max(6.907755 / lambdaDecay, 0.03), 25.0))
            }
        }

        return result
    }

    // 4th-order Linkwitz-Riley (24 dB/oct = two cascaded Butterworth biquads, Q = 1/sqrt(2))
    private struct LinkwitzRiley4thOrder {
        struct Biquad {
            let b0: Float; let b1: Float; let b2: Float
            let a1: Float; let a2: Float
            var z1: Float = 0; var z2: Float = 0

            @inline(__always)
            mutating func step(_ x: Float) -> Float {
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                return y
            }
        }

        var stage1Low: Biquad
        var stage2Low: Biquad
        var stage1High: Biquad
        var stage2High: Biquad

        init(crossoverHz: Float, sampleRate: Float) {
            let w0 = 2.0 * Float.pi * min(max(crossoverHz, 40.0), sampleRate * 0.44) / sampleRate
            let cosW = cosf(w0)
            let sinW = sinf(w0)
            let alpha = sinW * 0.70710678 // Q = 1/sqrt(2) Butterworth
            let invA0 = 1.0 / (1.0 + alpha)

            let lp = Biquad(
                b0: ((1.0 - cosW) * 0.5) * invA0,
                b1: (1.0 - cosW) * invA0,
                b2: ((1.0 - cosW) * 0.5) * invA0,
                a1: (-2.0 * cosW) * invA0,
                a2: (1.0 - alpha) * invA0
            )
            let hp = Biquad(
                b0: ((1.0 + cosW) * 0.5) * invA0,
                b1: -(1.0 + cosW) * invA0,
                b2: ((1.0 + cosW) * 0.5) * invA0,
                a1: (-2.0 * cosW) * invA0,
                a2: (1.0 - alpha) * invA0
            )
            self.stage1Low = lp
            self.stage2Low = lp
            self.stage1High = hp
            self.stage2High = hp
        }

        @inline(__always)
        mutating func split(_ x: Float) -> (low: Float, high: Float) {
            let low = stage2Low.step(stage1Low.step(x))
            let high = stage2High.step(stage1High.step(x))
            return (low, high)
        }
    }

    /// Synthesizes a 512-tap stereo binaural DRIR at 48 kHz from the 4-band Directional Energy Decay Histogram
    /// using Velvet-Noise / Poisson reflection pulses, 4-band Linkwitz-Riley (250/1000/4000 Hz) crossovers,
    /// and directional `KEMARHRIRSynthesizer` ear filters.
    public static func synthesizeStereoDRIR(
        directionalEDH: [SIMD4<Float>],
        timeBinCount: Int,
        directionSectorCount: Int,
        timeBinDurationSeconds: Float,
        sampleRate: Double = 48_000.0,
        seed: UInt64 = 0xD1B5_4A32_D192_ED03
    ) -> (left: [Float], right: [Float]) {
        let tapCount = drirTapCount
        let fs = Float(max(8_000.0, sampleRate))
        guard timeBinCount > 0, directionSectorCount > 0, directionalEDH.count >= timeBinCount * directionSectorCount else {
            var l = [Float](repeating: 0.0, count: tapCount)
            var r = [Float](repeating: 0.0, count: tapCount)
            l[0] = 1.0
            r[0] = 1.0
            return (l, r)
        }

        let azBins = max(1, directionSectorCount / 2)
        let elBins = max(1, directionSectorCount / azBins)

        var leftIR = [Float](repeating: 0.0, count: tapCount)
        var rightIR = [Float](repeating: 0.0, count: tapCount)

        var rng = seed
        @inline(__always)
        func nextUniform() -> Float {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return Float(z >> 40) * (1.0 / 16_777_216.0)
        }

        let invBinDt = 1.0 / max(1.0e-5, timeBinDurationSeconds)
        let hrirShortLen = 32 // Causal head window of 128-tap KEMAR HRIR preserving ITD + pinna notches

        for sector in 0..<directionSectorCount {
            let base = sector * timeBinCount
            var sectorTotalEnergy: Float = 0.0
            for t in 0..<timeBinCount {
                let e = directionalEDH[base + t]
                sectorTotalEnergy += e.x + e.y + e.z + e.w
            }
            if sectorTotalEnergy <= 1.0e-12 {
                continue
            }

            let azIdx = sector % azBins
            let elIdx = sector / azBins
            let azimuth = -Float.pi + ((Float(azIdx) + 0.5) / Float(azBins)) * (2.0 * Float.pi)
            let elevation = -Float.pi * 0.35 + ((Float(elIdx) + 0.5) / Float(elBins)) * (Float.pi * 0.70)

            let hrir = KEMARHRIRSynthesizer.synthesize(
                azimuthRadians: azimuth,
                elevationRadians: elevation,
                distanceMeters: 1.8,
                sampleRate: Double(fs)
            )

            // Sparse Velvet-Noise / Poisson pulse sequence (grid Td = 6 samples ~ 8000 pulses/s)
            var pulses = [Float](repeating: 0.0, count: tapCount)
            if sector == directionSectorCount / 2 {
                pulses[0] = 0.85
            }
            let gridSize = 6
            var gStart = 1
            while gStart < tapCount {
                let span = min(gridSize, tapCount - gStart)
                let pulseOffset = min(span - 1, Int(nextUniform() * Float(span)))
                let sign: Float = nextUniform() >= 0.5 ? 1.0 : -1.0
                pulses[gStart + pulseOffset] = sign
                gStart += gridSize
            }

            // Tree-structured 4-band Linkwitz-Riley 24 dB/oct crossover bank (250 Hz, 1000 Hz, 4000 Hz)
            var xoverMid = LinkwitzRiley4thOrder(crossoverHz: 1_000.0, sampleRate: fs)
            var xoverLow = LinkwitzRiley4thOrder(crossoverHz: 250.0, sampleRate: fs)
            var xoverHigh = LinkwitzRiley4thOrder(crossoverHz: 4_000.0, sampleRate: fs)

            var shapedSector = [Float](repeating: 0.0, count: tapCount)
            for n in 0..<tapCount {
                let tSec = Float(n) / fs
                let fIdx = min(tSec * invBinDt, Float(timeBinCount - 1))
                let idx0 = Int(fIdx)
                let idx1 = min(idx0 + 1, timeBinCount - 1)
                let frac = fIdx - Float(idx0)

                let e0 = directionalEDH[base + idx0]
                let e1 = directionalEDH[base + idx1]
                let envE = simd_max(e0 + (e1 - e0) * frac, .zero)
                let gain4 = SIMD4<Float>(
                    sqrtf(envE.x),
                    sqrtf(envE.y),
                    sqrtf(envE.z),
                    sqrtf(envE.w)
                )

                let (lowHalf, highHalf) = xoverMid.split(pulses[n])
                let (b125, b500) = xoverLow.split(lowHalf)
                let (b2000, b8000) = xoverHigh.split(highHalf)

                shapedSector[n] = b125 * gain4.x + b500 * gain4.y + b2000 * gain4.z + b8000 * gain4.w
            }

            // Convolve directional velvet stream with KEMAR binaural ear filters
            for n in 0..<tapCount {
                let sVal = shapedSector[n]
                if abs(sVal) < 1.0e-10 { continue }
                let kLimit = min(hrirShortLen, min(hrir.leftTaps.count, tapCount - n))
                for k in 0..<kLimit {
                    leftIR[n + k] += sVal * hrir.leftTaps[k]
                    rightIR[n + k] += sVal * hrir.rightTaps[k]
                }
            }
        }

        // Smooth final 24-tap raised-cosine fade-out & safe RMS/peak scaling preserving absorption energy differences
        let fadeLen = 24
        let fadeStart = tapCount - fadeLen
        var maxAbs: Float = 0.0
        for i in 0..<tapCount {
            if i >= fadeStart {
                let u = Float(i - fadeStart + 1) / Float(fadeLen + 1)
                let w = 0.5 * (1.0 + cosf(Float.pi * u))
                leftIR[i] *= w
                rightIR[i] *= w
            }
            maxAbs = max(maxAbs, max(abs(leftIR[i]), abs(rightIR[i])))
        }

        if maxAbs > 0.92 {
            let norm = 0.92 / maxAbs
            for i in 0..<tapCount {
                leftIR[i] *= norm
                rightIR[i] *= norm
            }
        } else if maxAbs < 1.0e-7 {
            leftIR[0] = 0.5
            rightIR[0] = 0.5
        }

        return (leftIR, rightIR)
    }
}

// MARK: - 5. Lock-Free / Wait-Free Real-Time DRIR Handoff into PartitionedOverlapSaveConvolver

public final class RayTracedDRIRConvolverBridge: @unchecked Sendable {
    public static let tapCount: Int = PartitionedOverlapSaveConvolver.maxImpulseLength // 512

    private let stagingLock: UnsafeMutablePointer<os_unfair_lock_s>
    private var stagedLeftTaps: [Float]
    private var stagedRightTaps: [Float]
    private var hasPendingUpdate: Bool = false

    // Owned exclusively by the real-time audio render thread after initialization
    private var audioThreadConvolver: PartitionedOverlapSaveConvolver

    public init() {
        self.stagingLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.stagingLock.initialize(to: os_unfair_lock_s())

        var initL = [Float](repeating: 0.0, count: Self.tapCount)
        var initR = [Float](repeating: 0.0, count: Self.tapCount)
        initL[0] = 0.65
        initR[0] = 0.65
        self.stagedLeftTaps = initL
        self.stagedRightTaps = initR
        self.audioThreadConvolver = PartitionedOverlapSaveConvolver(leftTaps: initL, rightTaps: initR)
    }

    deinit {
        stagingLock.deinitialize(count: 1)
        stagingLock.deallocate()
    }

    /// Called from background `MetalAcousticRayTracer` actor to stage a new 512-tap stereo DRIR.
    public func pushStereoDRIR(leftTaps: [Float], rightTaps: [Float]) {
        os_unfair_lock_lock(stagingLock)
        let nL = min(Self.tapCount, leftTaps.count)
        let nR = min(Self.tapCount, rightTaps.count)
        for i in 0..<nL { stagedLeftTaps[i] = leftTaps[i] }
        if nL < Self.tapCount {
            for i in nL..<Self.tapCount { stagedLeftTaps[i] = 0.0 }
        }
        for i in 0..<nR { stagedRightTaps[i] = rightTaps[i] }
        if nR < Self.tapCount {
            for i in nR..<Self.tapCount { stagedRightTaps[i] = 0.0 }
        }
        hasPendingUpdate = true
        os_unfair_lock_unlock(stagingLock)
    }

    /// Wait-free real-time render pass on `AVAudioSourceNode` thread:
    /// Picks up staged DRIR via `os_unfair_lock_trylock` (arming `PartitionedOverlapSaveConvolver`'s
    /// dual-slot 128-sample raised-cosine crossfader) and convolves `monoInput` into `(wetLeft, wetRight)`
    /// with ZERO heap allocations.
    public func processRealtimeBlock(
        monoInput: UnsafePointer<Float>,
        wetLeftOutput: UnsafeMutablePointer<Float>,
        wetRightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        if os_unfair_lock_trylock(stagingLock) {
            if hasPendingUpdate {
                audioThreadConvolver.setImpulseResponse(
                    leftTaps: stagedLeftTaps,
                    rightTaps: stagedRightTaps
                )
                hasPendingUpdate = false
            }
            os_unfair_lock_unlock(stagingLock)
        }

        audioThreadConvolver.processMonoToStereoBlock(
            monoInput: monoInput,
            leftOutput: wetLeftOutput,
            rightOutput: wetRightOutput,
            frameCount: frameCount
        )
    }
}

// MARK: - 6. GPU Metal Hardware Ray-Traced 3D Acoustic Solver Actor (`MTLAccelerationStructure`)

public actor MetalAcousticRayTracer {
    public static let defaultRayCount: Int = 4_096
    public static let defaultMaxBounces: Int = 16
    public static let defaultTimeBinCount: Int = 256
    public static let defaultDirectionSectors: Int = 16
    public static let defaultTimeBinDurationSeconds: Float = 0.004

    // Exact 16-byte Swift mirrors of `AcousticRayTracingKernels.metal` buffers
    private struct GPUMaterialMirror {
        var absorption: SIMD4<Float>
        var scattering: SIMD4<Float>
    }

    private struct GPUTriangleMetaMirror {
        var normalAndArea: SIMD4<Float>
        var indicesAndMat: SIMD4<UInt32>
    }

    private struct GPUInstanceMetaMirror {
        var offsets: SIMD4<UInt32>
    }

    private struct GPUTraceUniformsMirror {
        var sourcePosAndSpeed: SIMD4<Float>
        var listenerPosAndRadius: SIMD4<Float>
        var listenerRightAndMaxDist: SIMD4<Float>
        var listenerUpAndTimeBinDt: SIMD4<Float>
        var listenerFwdAndAirScale: SIMD4<Float>
        var airAttenuationPerMeter: SIMD4<Float>
        var counts: SIMD4<UInt32>
        var limits: SIMD4<UInt32>
    }

    private struct GPURaySegmentMirror {
        var startAndBounce: SIMD4<Float>
        var endAndDominantBand: SIMD4<Float>
        var bandEnergy: SIMD4<Float>
    }

    #if canImport(Metal)
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let tracePipeline: MTLComputePipelineState?
    #endif

    public let isHardwareRayTracingAvailable: Bool
    private var traceSeedCounter: UInt32 = 1

    public init(preferHardwareRayTracing: Bool = true) {
        #if canImport(Metal)
        if preferHardwareRayTracing,
           let mtlDevice = MTLCreateSystemDefaultDevice(),
           mtlDevice.supportsRaytracing,
           let queue = mtlDevice.makeCommandQueue(),
           let library = mtlDevice.makeDefaultLibrary(),
           let kernelFn = library.makeFunction(name: "aetherTraceAcousticRays"),
           let pipeline = try? mtlDevice.makeComputePipelineState(function: kernelFn) {
            self.device = mtlDevice
            self.commandQueue = queue
            self.tracePipeline = pipeline
            self.isHardwareRayTracingAvailable = true
        } else {
            self.device = nil
            self.commandQueue = nil
            self.tracePipeline = nil
            self.isHardwareRayTracingAvailable = false
        }
        #else
        self.isHardwareRayTracingAvailable = false
        #endif
    }

    /// Executes 3D acoustic ray-tracing across architectural chamber + orbiting `HabitNode` satellites,
    /// reconstructs the 512-tap stereo binaural DRIR, and optionally pushes directly into `RayTracedDRIRConvolverBridge`.
    public func solveChamberAcoustics(
        chamber: AcousticChamberPreset = .geodesicSanctuary,
        surfaceMaterial: AcousticSurfaceMaterial = AcousticSurfaceMaterialPreset.perforatedAcousticWood.material,
        habits: [HabitNodeDTO] = [],
        orbitalPhaseRadians: Float = 0.0,
        sourcePosition: SIMD3<Float> = SIMD3<Float>(0.0, 0.35, 1.45),
        listenerPose: ListenerHeadPose3D = ListenerHeadPose3D(position: SIMD3<Float>(0.0, 0.0, -1.15)),
        rayCount: Int = MetalAcousticRayTracer.defaultRayCount,
        maxBounces: Int = MetalAcousticRayTracer.defaultMaxBounces,
        sampleRate: Double = 48_000.0,
        forceCPUFallback: Bool = false,
        convolverBridge: RayTracedDRIRConvolverBridge? = nil
    ) -> AcousticTraceReport {
        let chamberGeom = ProceduralMeshGenerator.makeChamberGeometry(preset: chamber, materialIndex: 0)
        let satMaterial = AcousticSurfaceMaterialPreset.brushedTitanium.material
        let satPack = ProceduralMeshGenerator.buildOrbitingSatellites(
            habits: habits,
            orbitalPhaseRadians: orbitalPhaseRadians,
            satelliteMaterialIndex: 1
        )

        return solveCustomGeometry(
            chamberLabel: chamber,
            chamberGeometry: chamberGeom,
            satellitePack: satPack,
            materials: [surfaceMaterial, satMaterial],
            sourcePosition: sourcePosition,
            listenerPose: listenerPose,
            rayCount: rayCount,
            maxBounces: maxBounces,
            sampleRate: sampleRate,
            forceCPUFallback: forceCPUFallback,
            convolverBridge: convolverBridge
        )
    }

    /// Solves acoustics on arbitrary closed chamber geometry (used by analytical unit tests & custom chambers).
    public func solveCustomGeometry(
        chamberLabel: AcousticChamberPreset = .geodesicSanctuary,
        chamberGeometry: AcousticChamberGeometry,
        satellitePack: (instances: [OrbitingSatelliteAcousticInstance], unitMesh: ProceduralMeshData, worldTriangles: [AcousticMeshTriangle])? = nil,
        materials: [AcousticSurfaceMaterial],
        sourcePosition: SIMD3<Float>,
        listenerPose: ListenerHeadPose3D,
        rayCount: Int = MetalAcousticRayTracer.defaultRayCount,
        maxBounces: Int = MetalAcousticRayTracer.defaultMaxBounces,
        sampleRate: Double = 48_000.0,
        forceCPUFallback: Bool = false,
        convolverBridge: RayTracedDRIRConvolverBridge? = nil
    ) -> AcousticTraceReport {
        let safeMaterials = materials.isEmpty ? [AcousticSurfaceMaterialPreset.obsidianMarble.material] : materials
        let safeRayCount = max(64, rayCount)
        let safeMaxBounces = min(max(1, maxBounces), 16)
        let timeBinCount = Self.defaultTimeBinCount
        let dirSectorCount = Self.defaultDirectionSectors
        let timeBinDt = Self.defaultTimeBinDurationSeconds

        traceSeedCounter &+= 1
        let salt = traceSeedCounter

        var allWorldTriangles = chamberGeometry.triangles
        if let sat = satellitePack, !sat.worldTriangles.isEmpty {
            allWorldTriangles.append(contentsOf: sat.worldTriangles)
        }

        // Always maintain synchronized CPU SIMD SAH-BVH
        let cpuBVH = AcousticSAHBVH(triangles: allWorldTriangles)

        var edh: [SIMD4<Float>] = []
        var bounceEnvelope: [SIMD4<Float>] = []
        var segments: [TracedAcousticRaySegment] = []
        var leakedRays = 0
        var usedGPU = false

        #if canImport(Metal)
        if !forceCPUFallback,
           isHardwareRayTracingAvailable,
           let gpuResult = executeHardwareMetalRayTrace(
               chamberGeometry: chamberGeometry,
               satellitePack: satellitePack,
               materials: safeMaterials,
               sourcePosition: sourcePosition,
               listenerPose: listenerPose,
               rayCount: safeRayCount,
               maxBounces: safeMaxBounces,
               timeBinCount: timeBinCount,
               dirSectorCount: dirSectorCount,
               timeBinDt: timeBinDt,
               seedSalt: salt
           ) {
            edh = gpuResult.edh
            bounceEnvelope = computeAnalyticalBounceEnvelope(
                meanAbsorption: safeMaterials[0].absorption,
                volume: chamberGeometry.enclosedVolumeCubicMeters,
                area: chamberGeometry.totalSurfaceAreaSqMeters,
                maxBounces: safeMaxBounces
            )
            segments = gpuResult.segments
            leakedRays = gpuResult.leakedCount
            usedGPU = true
        }
        #endif

        if !usedGPU {
            let cpuResult = executeDeterministicCPUSAHTrace(
                bvh: cpuBVH,
                materials: safeMaterials,
                sourcePosition: sourcePosition,
                listenerPose: listenerPose,
                rayCount: safeRayCount,
                maxBounces: safeMaxBounces,
                timeBinCount: timeBinCount,
                dirSectorCount: dirSectorCount,
                timeBinDt: timeBinDt,
                seedSalt: salt
            )
            edh = cpuResult.edh
            bounceEnvelope = cpuResult.bounceEnvelope
            segments = cpuResult.segments
            leakedRays = cpuResult.leakedCount
        }

        let primaryAlpha = safeMaterials[0].absorption
        let sabine = DRIRReconstructor.computeSabineRT60(
            volumeCubicMeters: chamberGeometry.enclosedVolumeCubicMeters,
            surfaceAreaSqMeters: chamberGeometry.totalSurfaceAreaSqMeters,
            meanAbsorption: primaryAlpha
        )
        let eyring = DRIRReconstructor.computeEyringRT60(
            volumeCubicMeters: chamberGeometry.enclosedVolumeCubicMeters,
            surfaceAreaSqMeters: chamberGeometry.totalSurfaceAreaSqMeters,
            meanAbsorption: primaryAlpha
        )
        let rayTracedRT60 = DRIRReconstructor.computeRayTracedSchroederRT60(
            directionalEDH: edh,
            timeBinCount: timeBinCount,
            directionSectorCount: dirSectorCount,
            timeBinDurationSeconds: timeBinDt
        )

        let stereoDRIR = DRIRReconstructor.synthesizeStereoDRIR(
            directionalEDH: edh,
            timeBinCount: timeBinCount,
            directionSectorCount: dirSectorCount,
            timeBinDurationSeconds: timeBinDt,
            sampleRate: sampleRate,
            seed: UInt64(salt) &* 0x9E37_79B9_7F4A_7C15 ^ 0xA5A5_5A5A_F0F0_0F0F
        )

        convolverBridge?.pushStereoDRIR(leftTaps: stereoDRIR.left, rightTaps: stereoDRIR.right)

        return AcousticTraceReport(
            chamber: chamberLabel,
            materialName: safeMaterials[0].name,
            usedHardwareRayTracing: usedGPU,
            rayCount: safeRayCount,
            maxBounces: safeMaxBounces,
            triangleCount: allWorldTriangles.count,
            leakedRayCount: leakedRays,
            chamberVolumeCubicMeters: chamberGeometry.enclosedVolumeCubicMeters,
            chamberSurfaceAreaSqMeters: chamberGeometry.totalSurfaceAreaSqMeters,
            sabineRT60PerBand: sabine,
            eyringRT60PerBand: eyring,
            rayTracedRT60PerBand: rayTracedRT60,
            bounceMeanEnergyEnvelope: bounceEnvelope,
            directionalEDH: edh,
            timeBinCount: timeBinCount,
            directionSectorCount: dirSectorCount,
            timeBinDurationSeconds: timeBinDt,
            leftDRIR: stereoDRIR.left,
            rightDRIR: stereoDRIR.right,
            raySegments: segments
        )
    }

    private func computeAnalyticalBounceEnvelope(
        meanAbsorption: SIMD4<Float>,
        volume: Float,
        area: Float,
        maxBounces: Int
    ) -> [SIMD4<Float>] {
        let mfp = max(0.35, 4.0 * volume / max(1.0, area))
        let airStep = SIMD4<Float>(
            expf(-DRIRReconstructor.airAttenuationNepersPerMeter.x * mfp),
            expf(-DRIRReconstructor.airAttenuationNepersPerMeter.y * mfp),
            expf(-DRIRReconstructor.airAttenuationNepersPerMeter.z * mfp),
            expf(-DRIRReconstructor.airAttenuationNepersPerMeter.w * mfp)
        )
        let refl = SIMD4<Float>(repeating: 1.0) - meanAbsorption
        var env: [SIMD4<Float>] = []
        env.reserveCapacity(maxBounces)
        var current = SIMD4<Float>(repeating: 1.0)
        for _ in 0..<maxBounces {
            current *= refl * airStep
            env.append(current)
        }
        return env
    }

    // MARK: - Hardware Metal `MTLPrimitiveAccelerationStructure` + `MTLInstanceAccelerationStructure` Execution

    #if canImport(Metal)
    private func buildPrimitiveAccelerationStructure(
        device: MTLDevice,
        queue: MTLCommandQueue,
        vertices: [SIMD3<Float>],
        indices: [UInt32]
    ) -> MTLAccelerationStructure? {
        guard !vertices.isEmpty, indices.count >= 3 else { return nil }

        // Pack tightly as 12-byte packed float3 array for MTLAccelerationStructureTriangleGeometryDescriptor
        var packedXYZ = [Float]()
        packedXYZ.reserveCapacity(vertices.count * 3)
        for v in vertices {
            packedXYZ.append(v.x)
            packedXYZ.append(v.y)
            packedXYZ.append(v.z)
        }

        guard let vertexBuffer = device.makeBuffer(
                  bytes: packedXYZ,
                  length: packedXYZ.count * MemoryLayout<Float>.stride,
                  options: .storageModeShared
              ),
              let indexBuffer = device.makeBuffer(
                  bytes: indices,
                  length: indices.count * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              ) else {
            return nil
        }

        let triGeom = MTLAccelerationStructureTriangleGeometryDescriptor()
        triGeom.vertexBuffer = vertexBuffer
        triGeom.vertexStride = MemoryLayout<Float>.stride * 3
        triGeom.vertexFormat = .float3
        triGeom.indexBuffer = indexBuffer
        triGeom.indexType = .uint32
        triGeom.triangleCount = indices.count / 3
        triGeom.opaque = true

        let primDesc = MTLPrimitiveAccelerationStructureDescriptor()
        primDesc.geometryDescriptors = [triGeom]

        let sizes = device.accelerationStructureSizes(descriptor: primDesc)
        guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(256, sizes.buildScratchBufferSize), options: .storageModePrivate),
              let cmdBuf = queue.makeCommandBuffer(),
              let accelEnc = cmdBuf.makeAccelerationStructureCommandEncoder() else {
            return nil
        }

        accelEnc.build(accelerationStructure: accel, descriptor: primDesc, scratchBuffer: scratch, scratchBufferOffset: 0)
        accelEnc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return cmdBuf.status == .completed ? accel : nil
    }

    private func executeHardwareMetalRayTrace(
        chamberGeometry: AcousticChamberGeometry,
        satellitePack: (instances: [OrbitingSatelliteAcousticInstance], unitMesh: ProceduralMeshData, worldTriangles: [AcousticMeshTriangle])?,
        materials: [AcousticSurfaceMaterial],
        sourcePosition: SIMD3<Float>,
        listenerPose: ListenerHeadPose3D,
        rayCount: Int,
        maxBounces: Int,
        timeBinCount: Int,
        dirSectorCount: Int,
        timeBinDt: Float,
        seedSalt: UInt32
    ) -> (edh: [SIMD4<Float>], segments: [TracedAcousticRaySegment], leakedCount: Int)? {
        guard let device, let commandQueue, let tracePipeline else { return nil }

        guard let chamberBLAS = buildPrimitiveAccelerationStructure(
            device: device,
            queue: commandQueue,
            vertices: chamberGeometry.vertices,
            indices: chamberGeometry.indices
        ) else {
            return nil
        }

        var blasList: [MTLAccelerationStructure] = [chamberBLAS]
        var instanceMetas: [GPUInstanceMetaMirror] = [
            GPUInstanceMetaMirror(offsets: SIMD4<UInt32>(0, 1, 0, 0))
        ]
        var triMetas: [GPUTriangleMetaMirror] = chamberGeometry.triangles.map { tri in
            GPUTriangleMetaMirror(
                normalAndArea: SIMD4<Float>(tri.normal.x, tri.normal.y, tri.normal.z, tri.area),
                indicesAndMat: SIMD4<UInt32>(0, 0, 0, UInt32(tri.materialIndex))
            )
        }

        let satInstances = satellitePack?.instances ?? []
        if let sat = satellitePack, !sat.instances.isEmpty,
           let satBLAS = buildPrimitiveAccelerationStructure(
               device: device,
               queue: commandQueue,
               vertices: sat.unitMesh.positions,
               indices: sat.unitMesh.indices
           ) {
            blasList.append(satBLAS)
            let satTriOffset = UInt32(triMetas.count)
            var idx = 0
            while idx + 2 < sat.unitMesh.indices.count {
                let p0 = sat.unitMesh.positions[Int(sat.unitMesh.indices[idx])]
                let p1 = sat.unitMesh.positions[Int(sat.unitMesh.indices[idx + 1])]
                let p2 = sat.unitMesh.positions[Int(sat.unitMesh.indices[idx + 2])]
                let n = simd_normalize(p0 + p1 + p2)
                triMetas.append(
                    GPUTriangleMetaMirror(
                        normalAndArea: SIMD4<Float>(n.x, n.y, n.z, 0.05),
                        indicesAndMat: SIMD4<UInt32>(0, 0, 0, 1)
                    )
                )
                idx += 3
            }

            for inst in sat.instances {
                instanceMetas.append(
                    GPUInstanceMetaMirror(offsets: SIMD4<UInt32>(satTriOffset, UInt32(inst.materialIndex + 1), 0, 0))
                )
            }
        }

        let totalInstanceCount = 1 + (blasList.count > 1 ? satInstances.count : 0)
        guard let instanceDescBuf = device.makeBuffer(
            length: totalInstanceCount * MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride,
            options: .storageModeShared
        ) else {
            return nil
        }

        let instPtr = instanceDescBuf.contents().bindMemory(
            to: MTLAccelerationStructureInstanceDescriptor.self,
            capacity: totalInstanceCount
        )

        instPtr[0] = Self.makeMTLInstanceDescriptor(transform: matrix_identity_float4x4, accelIndex: 0)
        if blasList.count > 1 {
            for (k, satInst) in satInstances.enumerated() {
                instPtr[1 + k] = Self.makeMTLInstanceDescriptor(transform: satInst.worldTransform, accelIndex: 1)
            }
        }

        let tlasDesc = MTLInstanceAccelerationStructureDescriptor()
        tlasDesc.instancedAccelerationStructures = blasList
        tlasDesc.instanceCount = totalInstanceCount
        tlasDesc.instanceDescriptorBuffer = instanceDescBuf

        let tlasSizes = device.accelerationStructureSizes(descriptor: tlasDesc)
        guard let tlas = device.makeAccelerationStructure(size: tlasSizes.accelerationStructureSize),
              let tlasScratch = device.makeBuffer(length: max(256, tlasSizes.buildScratchBufferSize), options: .storageModePrivate),
              let buildCmd = commandQueue.makeCommandBuffer(),
              let buildEnc = buildCmd.makeAccelerationStructureCommandEncoder() else {
            return nil
        }

        buildEnc.build(accelerationStructure: tlas, descriptor: tlasDesc, scratchBuffer: tlasScratch, scratchBufferOffset: 0)
        buildEnc.endEncoding()
        buildCmd.commit()
        buildCmd.waitUntilCompleted()
        guard buildCmd.status == .completed else { return nil }

        let gpuMats = materials.map { GPUMaterialMirror(absorption: $0.absorption, scattering: $0.scattering) }
        let maxSegments = 512
        let edhFloatCount = timeBinCount * dirSectorCount * 4

        var uniforms = GPUTraceUniformsMirror(
            sourcePosAndSpeed: SIMD4<Float>(sourcePosition.x, sourcePosition.y, sourcePosition.z, 343.0),
            listenerPosAndRadius: SIMD4<Float>(listenerPose.position.x, listenerPose.position.y, listenerPose.position.z, listenerPose.captureRadiusMeters),
            listenerRightAndMaxDist: SIMD4<Float>(listenerPose.right.x, listenerPose.right.y, listenerPose.right.z, 10_000.0),
            listenerUpAndTimeBinDt: SIMD4<Float>(listenerPose.up.x, listenerPose.up.y, listenerPose.up.z, timeBinDt),
            listenerFwdAndAirScale: SIMD4<Float>(listenerPose.forward.x, listenerPose.forward.y, listenerPose.forward.z, 1.0),
            airAttenuationPerMeter: DRIRReconstructor.airAttenuationNepersPerMeter,
            counts: SIMD4<UInt32>(UInt32(rayCount), UInt32(maxBounces), UInt32(timeBinCount), UInt32(dirSectorCount)),
            limits: SIMD4<UInt32>(UInt32(maxSegments), UInt32(triMetas.count), UInt32(gpuMats.count), seedSalt)
        )

        guard let triMetaBuf = device.makeBuffer(bytes: triMetas, length: triMetas.count * MemoryLayout<GPUTriangleMetaMirror>.stride, options: .storageModeShared),
              let matBuf = device.makeBuffer(bytes: gpuMats, length: gpuMats.count * MemoryLayout<GPUMaterialMirror>.stride, options: .storageModeShared),
              let instMetaBuf = device.makeBuffer(bytes: instanceMetas, length: instanceMetas.count * MemoryLayout<GPUInstanceMetaMirror>.stride, options: .storageModeShared),
              let edhBuf = device.makeBuffer(length: edhFloatCount * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let segBuf = device.makeBuffer(length: maxSegments * MemoryLayout<GPURaySegmentMirror>.stride, options: .storageModeShared),
              let segCounterBuf = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let leakCounterBuf = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            return nil
        }

        memset(edhBuf.contents(), 0, edhBuf.length)
        memset(segCounterBuf.contents(), 0, segCounterBuf.length)
        memset(leakCounterBuf.contents(), 0, leakCounterBuf.length)

        enc.setComputePipelineState(tracePipeline)
        for blas in blasList {
            enc.useResource(blas, usage: .read)
        }
        enc.setAccelerationStructure(tlas, bufferIndex: 0)
        enc.setBuffer(triMetaBuf, offset: 0, index: 1)
        enc.setBuffer(matBuf, offset: 0, index: 2)
        enc.setBuffer(instMetaBuf, offset: 0, index: 3)
        enc.setBytes(&uniforms, length: MemoryLayout<GPUTraceUniformsMirror>.stride, index: 4)
        enc.setBuffer(edhBuf, offset: 0, index: 5)
        enc.setBuffer(segBuf, offset: 0, index: 6)
        enc.setBuffer(segCounterBuf, offset: 0, index: 7)
        enc.setBuffer(leakCounterBuf, offset: 0, index: 8)

        let tgWidth = min(max(32, tracePipeline.threadExecutionWidth), 256)
        let gridThreads = MTLSize(width: rayCount, height: 1, depth: 1)
        let tgSize = MTLSize(width: tgWidth, height: 1, depth: 1)
        enc.dispatchThreads(gridThreads, threadsPerThreadgroup: tgSize)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }

        let rawEDHPtr = edhBuf.contents().bindMemory(to: Float.self, capacity: edhFloatCount)
        var edh = [SIMD4<Float>](repeating: .zero, count: timeBinCount * dirSectorCount)
        for idx in 0..<(timeBinCount * dirSectorCount) {
            let b = idx * 4
            edh[idx] = SIMD4<Float>(rawEDHPtr[b], rawEDHPtr[b + 1], rawEDHPtr[b + 2], rawEDHPtr[b + 3])
        }

        let segCount = min(maxSegments, Int(segCounterBuf.contents().bindMemory(to: UInt32.self, capacity: 1).pointee))
        let segPtr = segBuf.contents().bindMemory(to: GPURaySegmentMirror.self, capacity: maxSegments)
        var outSegments: [TracedAcousticRaySegment] = []
        outSegments.reserveCapacity(segCount)
        for i in 0..<segCount {
            let s = segPtr[i]
            outSegments.append(
                TracedAcousticRaySegment(
                    start: SIMD3<Float>(s.startAndBounce.x, s.startAndBounce.y, s.startAndBounce.z),
                    end: SIMD3<Float>(s.endAndDominantBand.x, s.endAndDominantBand.y, s.endAndDominantBand.z),
                    bounceIndex: Int(s.startAndBounce.w),
                    dominantBand: Int(s.endAndDominantBand.w),
                    bandEnergy: s.bandEnergy
                )
            )
        }

        let leaked = Int(leakCounterBuf.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        return (edh, outSegments, leaked)
    }

    private static func makeMTLInstanceDescriptor(
        transform: simd_float4x4,
        accelIndex: UInt32
    ) -> MTLAccelerationStructureInstanceDescriptor {
        var desc = MTLAccelerationStructureInstanceDescriptor()
        desc.accelerationStructureIndex = accelIndex
        desc.options = .opaque
        desc.mask = 0xFF
        desc.intersectionFunctionTableOffset = 0
        desc.transformationMatrix = MTLPackedFloat4x3(
            columns: (
                MTLPackedFloat3Make(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                MTLPackedFloat3Make(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                MTLPackedFloat3Make(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z),
                MTLPackedFloat3Make(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            )
        )
        return desc
    }
    #endif

    // MARK: - Deterministic CPU SIMD SAH-BVH Fallback Ray-Tracer

    private func executeDeterministicCPUSAHTrace(
        bvh: AcousticSAHBVH,
        materials: [AcousticSurfaceMaterial],
        sourcePosition: SIMD3<Float>,
        listenerPose: ListenerHeadPose3D,
        rayCount: Int,
        maxBounces: Int,
        timeBinCount: Int,
        dirSectorCount: Int,
        timeBinDt: Float,
        seedSalt: UInt32
    ) -> (edh: [SIMD4<Float>], bounceEnvelope: [SIMD4<Float>], segments: [TracedAcousticRaySegment], leakedCount: Int) {
        let speedOfSound: Float = 343.0
        let invSpeed: Float = 1.0 / speedOfSound
        let airM = DRIRReconstructor.airAttenuationNepersPerMeter

        var edh = [SIMD4<Float>](repeating: .zero, count: timeBinCount * dirSectorCount)
        var bounceAccum = [SIMD4<Float>](repeating: .zero, count: maxBounces)
        var bounceHits = [Int](repeating: 0, count: maxBounces)
        var segments: [TracedAcousticRaySegment] = []
        segments.reserveCapacity(384)
        var leakedRays = 0

        @inline(__always)
        func mapSphericalSector(_ incomingToListenerWorld: SIMD3<Float>) -> Int {
            guard dirSectorCount > 1 else { return 0 }
            let localVec = simd_normalize(SIMD3<Float>(
                simd_dot(incomingToListenerWorld, listenerPose.right),
                simd_dot(incomingToListenerWorld, listenerPose.up),
                simd_dot(incomingToListenerWorld, listenerPose.forward)
            ))
            let azimuth = atan2f(localVec.x, localVec.z)
            let elevation = asinf(min(max(localVec.y, -1.0), 1.0))

            let azBins = max(1, dirSectorCount / 2)
            let elBins = max(1, dirSectorCount / azBins)
            let azNorm = min(max((azimuth + Float.pi) / (2.0 * Float.pi), 0.0), 0.99999)
            let elNorm = min(max((elevation + Float.pi * 0.5) / Float.pi, 0.0), 0.99999)
            let azIdx = min(Int(azNorm * Float(azBins)), azBins - 1)
            let elIdx = min(Int(elNorm * Float(elBins)), elBins - 1)
            return min(elIdx * azBins + azIdx, dirSectorCount - 1)
        }

        @inline(__always)
        func accumulateEDH(timeSec: Float, sector: Int, contribution: SIMD4<Float>) {
            let tBin = min(Int(max(0.0, timeSec) / timeBinDt), timeBinCount - 1)
            let sBin = min(max(0, sector), dirSectorCount - 1)
            edh[sBin * timeBinCount + tBin] += simd_max(contribution, .zero)
        }

        // Direct sound Next Event Estimation
        let directVec = listenerPose.position - sourcePosition
        let directDist = simd_length(directVec)
        if directDist > 1.0e-3 {
            let directDir = directVec / directDist
            if !bvh.isOccluded(
                origin: sourcePosition,
                direction: directDir,
                maxDistance: max(1.0e-3, directDist - listenerPose.captureRadiusMeters * 0.35)
            ) {
                let invSq = 1.0 / max(0.25, directDist * directDist)
                let airDirect = SIMD4<Float>(
                    expf(-airM.x * directDist),
                    expf(-airM.y * directDist),
                    expf(-airM.z * directDist),
                    expf(-airM.w * directDist)
                )
                accumulateEDH(
                    timeSec: directDist * invSpeed,
                    sector: mapSphericalSector(-directDir),
                    contribution: airDirect * invSq * 0.35
                )
            }
        }

        let invRays = 1.0 / Float(rayCount)
        let goldenAngle: Float = 2.39996323

        for rIdx in 0..<rayCount {
            let y = 1.0 - 2.0 * (Float(rIdx) + 0.5) * invRays
            let radial = sqrtf(max(0.0, 1.0 - y * y))
            let theta = goldenAngle * Float(rIdx)
            var rayDir = simd_normalize(SIMD3<Float>(radial * cosf(theta), y, radial * sinf(theta)))
            var rayOrigin = sourcePosition
            var rayEnergy = SIMD4<Float>(repeating: invRays)
            var cumulativeDist: Float = 0.0

            for bounce in 0..<maxBounces {
                guard let hit = bvh.traceClosestHit(origin: rayOrigin, direction: rayDir) else {
                    leakedRays += 1
                    break
                }

                let segDist = max(1.0e-4, hit.distance)
                cumulativeDist += segDist

                let segAir = SIMD4<Float>(
                    expf(-airM.x * segDist),
                    expf(-airM.y * segDist),
                    expf(-airM.z * segDist),
                    expf(-airM.w * segDist)
                )
                rayEnergy *= segAir

                let mat = materials[min(hit.materialIndex, materials.count - 1)]
                let hitNormal = hit.normal

                if (rIdx & 31) == 0 && bounce < 6 && segments.count < 512 {
                    var dom = 0
                    var maxB = rayEnergy.x
                    if rayEnergy.y > maxB { maxB = rayEnergy.y; dom = 1 }
                    if rayEnergy.z > maxB { maxB = rayEnergy.z; dom = 2 }
                    if rayEnergy.w > maxB { maxB = rayEnergy.w; dom = 3 }
                    segments.append(
                        TracedAcousticRaySegment(
                            start: rayOrigin,
                            end: hit.point,
                            bounceIndex: bounce,
                            dominantBand: dom,
                            bandEnergy: rayEnergy * Float(rayCount)
                        )
                    )
                }

                // Attenuate per band by (1 - alpha_b)
                rayEnergy *= (SIMD4<Float>(repeating: 1.0) - mat.absorption)
                bounceAccum[bounce] += rayEnergy * Float(rayCount)
                bounceHits[bounce] += 1

                let safeHit = hit.point + hitNormal * 1.5e-3

                // Next Event Estimation shadow ray toward listener head sphere
                let toListener = listenerPose.position - safeHit
                let distToListener = simd_length(toListener)
                if distToListener > 1.0e-3 {
                    let toListenerDir = toListener / distToListener
                    let cosListener = simd_dot(hitNormal, toListenerDir)
                    if cosListener > 0.0 {
                        let maxOcc = max(1.0e-4, distToListener - listenerPose.captureRadiusMeters * 0.45)
                        if !bvh.isOccluded(origin: safeHit, direction: toListenerDir, maxDistance: maxOcc) {
                            let dTotal = cumulativeDist + distToListener
                            let rSq = listenerPose.captureRadiusMeters * listenerPose.captureRadiusMeters
                            let solidAngle = min(1.0, rSq / max(rSq, distToListener * distToListener))
                            let specDir = simd_reflect(rayDir, hitNormal)
                            let specLobe = powf(max(0.0, simd_dot(specDir, toListenerDir)), 10.0)
                            let brdf = mat.scattering * (2.0 * cosListener)
                                + (SIMD4<Float>(repeating: 1.0) - mat.scattering) * (specLobe * 5.0)
                            let neeAir = SIMD4<Float>(
                                expf(-airM.x * distToListener),
                                expf(-airM.y * distToListener),
                                expf(-airM.z * distToListener),
                                expf(-airM.w * distToListener)
                            )
                            accumulateEDH(
                                timeSec: dTotal * invSpeed,
                                sector: mapSphericalSector(-toListenerDir),
                                contribution: rayEnergy * brdf * solidAngle * neeAir
                            )
                        }
                    }
                }

                // Stateless Sobol/Halton QMC bounce direction
                let qmc = Self.qmcSample3D(rayIndex: UInt32(rIdx), bounceIndex: UInt32(bounce), salt: seedSalt)
                let specReflect = simd_normalize(rayDir - 2.0 * simd_dot(rayDir, hitNormal) * hitNormal)
                let diffReflect = Self.sampleCosineHemisphere(u: SIMD2<Float>(qmc.x, qmc.y), normal: hitNormal)
                let meanScatter = 0.25 * (mat.scattering.x + mat.scattering.y + mat.scattering.z + mat.scattering.w)
                var nextDir = simd_normalize(specReflect * (1.0 - meanScatter) + diffReflect * meanScatter)
                if simd_dot(nextDir, hitNormal) < 1.0e-3 {
                    nextDir = simd_normalize(nextDir + hitNormal * (1.0e-2 - simd_dot(nextDir, hitNormal)))
                }

                // Unbiased Russian Roulette termination after bounce 6
                if bounce >= 6 {
                    let maxBand = max(max(rayEnergy.x, rayEnergy.y), max(rayEnergy.z, rayEnergy.w)) * Float(rayCount)
                    if maxBand < 0.15 {
                        let pSurvive = min(max(maxBand / 0.15, 0.05), 0.95)
                        if qmc.z >= pSurvive {
                            break
                        }
                        rayEnergy /= pSurvive
                    }
                }

                rayOrigin = safeHit
                rayDir = nextDir
            }
        }

        var envelope = [SIMD4<Float>](repeating: .zero, count: maxBounces)
        for b in 0..<maxBounces {
            if bounceHits[b] > 0 {
                envelope[b] = bounceAccum[b] * invRays
            }
        }

        return (edh, envelope, segments, leakedRays)
    }

    @inline(__always)
    private static func radicalInverse2(_ bitsIn: UInt32) -> Float {
        var b = (bitsIn << 16) | (bitsIn >> 16)
        b = ((b & 0x5555_5555) << 1) | ((b & 0xAAAA_AAAA) >> 1)
        b = ((b & 0x3333_3333) << 2) | ((b & 0xCCCC_CCCC) >> 2)
        b = ((b & 0x0F0F_0F0F) << 4) | ((b & 0xF0F0_F0F0) >> 4)
        b = ((b & 0x00FF_00FF) << 8) | ((b & 0xFF00_FF00) >> 8)
        return Float(b) * 2.3283064365e-10
    }

    @inline(__always)
    private static func radicalInverse3(_ nIn: UInt32) -> Float {
        let invBase: Float = 1.0 / 3.0
        var factor = invBase
        var result: Float = 0.0
        var cur = nIn
        while cur > 0 {
            result += Float(cur % 3) * factor
            cur /= 3
            factor *= invBase
        }
        return result
    }

    @inline(__always)
    private static func sobolDim2(_ index: UInt32) -> Float {
        var v: UInt32 = 0x8000_0000
        var r: UInt32 = 0
        var i = index
        while i != 0 {
            if (i & 1) != 0 { r ^= v }
            i >>= 1
            v ^= (v >> 1)
        }
        return Float(r) * 2.3283064365e-10
    }

    @inline(__always)
    private static func qmcSample3D(rayIndex: UInt32, bounceIndex: UInt32, salt: UInt32) -> SIMD3<Float> {
        let seq = (rayIndex &+ 1) &* 53 &+ bounceIndex &* 1009 &+ (salt & 0xFFFF)
        let u1 = fmodf(radicalInverse2(seq) + Float(rayIndex & 2047) * 0.00048828125, 1.0)
        let u2 = fmodf(radicalInverse3(seq) + Float(bounceIndex) * 0.61803399, 1.0)
        let u3 = fmodf(sobolDim2(seq ^ 0x9E37_79B9), 1.0)
        return SIMD3<Float>(u1, u2, u3)
    }

    @inline(__always)
    private static func sampleCosineHemisphere(u: SIMD2<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
        let phi = 2.0 * Float.pi * u.x
        let cosTheta = sqrtf(max(0.0, 1.0 - u.y))
        let sinTheta = sqrtf(max(0.0, u.y))

        let tangent: SIMD3<Float>
        let bitangent: SIMD3<Float>
        if normal.z < -0.99999 {
            tangent = SIMD3<Float>(0.0, -1.0, 0.0)
            bitangent = SIMD3<Float>(-1.0, 0.0, 0.0)
        } else {
            let a = 1.0 / (1.0 + normal.z)
            let d = -normal.x * normal.y * a
            tangent = simd_normalize(SIMD3<Float>(1.0 - normal.x * normal.x * a, d, -normal.x))
            bitangent = simd_normalize(SIMD3<Float>(d, 1.0 - normal.y * normal.y * a, -normal.y))
        }
        return simd_normalize(tangent * (cosf(phi) * sinTheta) + bitangent * (sinf(phi) * sinTheta) + normal * cosTheta)
    }
}
