// MARK: - FILE: CustomLayoutsAndEffects.swift

import SwiftUI
import QuartzCore

private struct OrbitalMassLayoutKey: LayoutValueKey {
    static let defaultValue: Double = 1.0
}

private struct IsGravitationalCoreLayoutKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

public extension View {
    func orbitalMass(_ mass: Double) -> some View {
        layoutValue(key: OrbitalMassLayoutKey.self, value: min(max(mass, 0.5), 2.5))
    }

    func gravitationalCore(_ isCore: Bool = true) -> some View {
        layoutValue(key: IsGravitationalCoreLayoutKey.self, value: isCore)
    }
}

// MARK: - RadialOrbitalLayout: Custom SwiftUI Layout Protocol Implementation

public struct RadialOrbitalLayout: Layout {
    public var rotationRadians: Double
    public var radiusScale: CGFloat

    public struct Cache {
        var coreIndex: Int?
        var coreSize: CGSize = .zero
        var satelliteIndices: [Int] = []
        var satelliteSizes: [CGSize] = []
        var satelliteMasses: [Double] = []
        var weightedAngles: [Double] = []
    }

    public init(rotationRadians: Double = 0, radiusScale: CGFloat = 1.0) {
        self.rotationRadians = rotationRadians
        self.radiusScale = radiusScale
    }

    public var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(rotationRadians, radiusScale) }
        set {
            rotationRadians = newValue.first
            radiusScale = newValue.second
        }
    }

    public func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        rebuildCache(&cache, subviews: subviews)
        return cache
    }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        rebuildCache(&cache, subviews: subviews)
    }

    private func rebuildCache(_ cache: inout Cache, subviews: Subviews) {
        cache.coreIndex = nil
        cache.coreSize = .zero
        cache.satelliteIndices.removeAll(keepingCapacity: true)
        cache.satelliteSizes.removeAll(keepingCapacity: true)
        cache.satelliteMasses.removeAll(keepingCapacity: true)
        cache.weightedAngles.removeAll(keepingCapacity: true)

        for index in subviews.indices {
            let subview = subviews[index]
            let isCore = subview[IsGravitationalCoreLayoutKey.self]
            let measured = subview.sizeThatFits(.unspecified)

            if isCore && cache.coreIndex == nil {
                cache.coreIndex = index
                cache.coreSize = measured
            } else {
                cache.satelliteIndices.append(index)
                cache.satelliteSizes.append(measured)
                cache.satelliteMasses.append(subview[OrbitalMassLayoutKey.self])
            }
        }

        let count = cache.satelliteIndices.count
        guard count > 0 else { return }

        let weights: [Double] = cache.satelliteSizes.enumerated().map { idx, sz in
            let diagonal = hypot(Double(sz.width), Double(sz.height))
            return max(44.0, diagonal * (0.85 + 0.15 * cache.satelliteMasses[idx]))
        }
        let totalWeight = max(1.0, weights.reduce(0, +))

        var cumulative = 0.0
        for w in weights {
            let midpointAngle = ((cumulative + w * 0.5) / totalWeight) * (.pi * 2.0) - (.pi * 0.5)
            cache.weightedAngles.append(midpointAngle)
            cumulative += w
        }
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let maxSatelliteDiameter = cache.satelliteSizes.reduce(CGFloat(0)) { acc, sz in
            max(acc, max(sz.width, sz.height))
        }
        let coreDiameter = max(cache.coreSize.width, cache.coreSize.height)
        let idealSpan = max(320, coreDiameter + maxSatelliteDiameter * 2.4 + 92)

        let width = proposal.width ?? idealSpan
        let height = proposal.height ?? idealSpan
        let side = min(width, height)
        return CGSize(width: width, height: max(side, 320))
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard !subviews.isEmpty else { return }
        let barycenter = CGPoint(x: bounds.midX, y: bounds.midY)

        if let coreIdx = cache.coreIndex {
            subviews[coreIdx].place(
                at: barycenter,
                anchor: .center,
                proposal: ProposedViewSize(cache.coreSize)
            )
        }

        let satCount = cache.satelliteIndices.count
        guard satCount > 0 else { return }

        let maxSatelliteHalf = cache.satelliteSizes.reduce(CGFloat(28)) { acc, sz in
            max(acc, max(sz.width, sz.height) * 0.5)
        }
        let coreHalf = max(cache.coreSize.width, cache.coreSize.height) * 0.5
        let maxAvailableRadius = max(
            coreHalf + 42,
            min(bounds.width, bounds.height) * 0.5 - maxSatelliteHalf - 8
        )
        let innerOrbitFloor = min(maxAvailableRadius, max(coreHalf + maxSatelliteHalf + 14, maxAvailableRadius * 0.74))

        for (slot, subviewIdx) in cache.satelliteIndices.enumerated() {
            let mass = cache.satelliteMasses[slot]
            let size = cache.satelliteSizes[slot]
            let baseAngle = cache.weightedAngles[slot] + rotationRadians

            let normalizedMass = CGFloat((mass - 0.5) / 2.0)
            let stratifiedRadius = (maxAvailableRadius - normalizedMass * (maxAvailableRadius - innerOrbitFloor)) * radiusScale

            let x = barycenter.x + CGFloat(cos(baseAngle)) * stratifiedRadius
            let y = barycenter.y + CGFloat(sin(baseAngle)) * stratifiedRadius

            subviews[subviewIdx].place(
                at: CGPoint(x: x, y: y),
                anchor: .center,
                proposal: ProposedViewSize(size)
            )
        }
    }
}

// MARK: - Custom GeometryEffect 3D Matrix Portal Transition

public struct OrbitalMatrixWarpEffect: GeometryEffect {
    public var progress: Double

    public init(progress: Double) {
        self.progress = progress
    }

    public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        let clamped = min(max(progress, 0.0), 1.0)
        let inverse = 1.0 - clamped

        let halfW = size.width * 0.5
        let halfH = size.height * 0.5

        var transform3D = CATransform3DIdentity
        transform3D.m34 = -1.0 / 650.0

        transform3D = CATransform3DTranslate(transform3D, halfW, halfH + CGFloat(inverse * 22.0), 0)
        let scale = CGFloat(max(0.78, 0.84 + 0.16 * clamped))
        transform3D = CATransform3DScale(transform3D, scale, scale, 1.0)
        transform3D = CATransform3DRotate(transform3D, CGFloat(inverse * 0.42), 1.0, -0.18, 0.04)
        transform3D = CATransform3DTranslate(transform3D, -halfW, -halfH, 0)

        return ProjectionTransform(transform3D)
    }
}

public extension AnyTransition {
    static var aetherMatrixPortal: AnyTransition {
        .modifier(
            active: OrbitalMatrixWarpEffect(progress: 0.0),
            identity: OrbitalMatrixWarpEffect(progress: 1.0)
        )
        .combined(with: .opacity)
    }
}

// MARK: - Custom Segmented Control with .matchedGeometryEffect

public struct AetherSegmentItem<ID: Hashable>: Identifiable, Sendable {
    public let id: ID
    public let title: String
    public let symbolName: String

    public init(id: ID, title: String, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }
}

public struct AetherSegmentedControl<ID: Hashable & Sendable>: View {
    public let items: [AetherSegmentItem<ID>]
    @Binding public var selection: ID
    public let accentHue: Double
    public let onSelect: () -> Void

    @Namespace private var pillNamespace

    public init(
        items: [AetherSegmentItem<ID>],
        selection: Binding<ID>,
        accentHue: Double,
        onSelect: @escaping () -> Void
    ) {
        self.items = items
        self._selection = selection
        self.accentHue = accentHue
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let isSelected = (selection == item.id)

                Button {
                    guard selection != item.id else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = item.id
                    }
                    onSelect()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.62))
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(hue: accentHue, saturation: 0.65, brightness: 0.92).opacity(0.45),
                                            Color(hue: (accentHue + 0.12).truncatingRemainder(dividingBy: 1.0), saturation: 0.70, brightness: 0.78).opacity(0.28)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [.white.opacity(0.55), .white.opacity(0.10)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 1
                                        )
                                }
                                .shadow(
                                    color: Color(hue: accentHue, saturation: 0.8, brightness: 0.9).opacity(0.35),
                                    radius: 10,
                                    y: 3
                                )
                                .matchedGeometryEffect(id: "ActiveAetherSegmentPill", in: pillNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
        }
    }
}

// MARK: - Dynamic Audio-Reactive Glassmorphism ViewModifier

public struct GlassmorphicCardModifier: ViewModifier {
    public let accentHue: Double
    public let audioEnergy: Float
    public let cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        let glowOpacity = 0.22 + Double(min(max(audioEnergy, 0), 1)) * 0.42
        let accent = Color(hue: accentHue, saturation: 0.68, brightness: 0.96)
        let secondary = Color(hue: (accentHue + 0.16).truncatingRemainder(dividingBy: 1.0), saturation: 0.62, brightness: 0.90)

        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.10),
                                        accent.opacity(0.06),
                                        .black.opacity(0.18)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                .white.opacity(0.45),
                                accent.opacity(glowOpacity),
                                .white.opacity(0.08),
                                secondary.opacity(glowOpacity * 0.85),
                                .white.opacity(0.45)
                            ],
                            center: .center
                        ),
                        lineWidth: 1.1
                    )
            }
            .shadow(color: .black.opacity(0.38), radius: 18, x: 0, y: 10)
    }
}

public extension View {
    func aetherGlass(
        accentHue: Double,
        audioEnergy: Float = 0,
        cornerRadius: CGFloat = 24
    ) -> some View {
        modifier(
            GlassmorphicCardModifier(
                accentHue: accentHue,
                audioEnergy: audioEnergy,
                cornerRadius: cornerRadius
            )
        )
    }
}
