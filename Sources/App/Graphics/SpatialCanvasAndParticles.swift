// MARK: - FILE: SpatialCanvasAndParticles.swift

import SwiftUI
import simd

@MainActor
public final class ParticlePhysicsSimulation {
    public struct Particle {
        var position: SIMD2<Float>
        var previousPosition: SIMD2<Float>
        var velocity: SIMD2<Float>
        var radius: Float
        var hueOffset: Float
        var orbitalRadiusFactor: Float
        var angularDirection: Float
        var baseAlpha: Float
    }

    private var particles: [Particle] = []
    private var lastStepTimestamp: TimeInterval?
    private var initializedBounds: CGSize = .zero
    private let targetCount: Int

    public init(particleCount: Int = 150) {
        self.targetCount = max(24, particleCount)
    }

    private func seedParticlesIfNeeded(in size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        if !particles.isEmpty && abs(initializedBounds.width - size.width) < 40 {
            return
        }
        initializedBounds = size
        particles.removeAll(keepingCapacity: true)

        let center = SIMD2<Float>(Float(size.width * 0.5), Float(size.height * 0.5))
        let minDim = Float(min(size.width, size.height))
        var rng: UInt64 = 0x517C_C1B7_2722_0A95

        for idx in 0..<targetCount {
            func nextUnit() -> Float {
                rng &+= 0x9E37_79B9_7F4A_7C15
                var z = rng
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z = z ^ (z >> 31)
                return Float(z >> 40) / 16_777_216.0
            }

            let angle = nextUnit() * Float.pi * 2.0
            let ringFactor = 0.14 + pow(nextUnit(), 0.78) * 0.42
            let dist = ringFactor * minDim
            let pos = center + SIMD2<Float>(cos(angle) * dist, sin(angle) * dist)
            let tangent = SIMD2<Float>(-sin(angle), cos(angle)) * (18.0 + nextUnit() * 28.0)

            particles.append(
                Particle(
                    position: pos,
                    previousPosition: pos,
                    velocity: tangent,
                    radius: 1.2 + nextUnit() * 2.5,
                    hueOffset: (Float(idx % 7) / 7.0) * 0.22 - 0.11,
                    orbitalRadiusFactor: ringFactor,
                    angularDirection: (idx % 5 == 0) ? -1.0 : 1.0,
                    baseAlpha: 0.28 + nextUnit() * 0.55
                )
            )
        }
    }

    public func stepAndRender(
        into context: inout GraphicsContext,
        size: CGSize,
        timestamp: Date,
        audioAmplitude: Float,
        highBandEnergy: Float,
        accentHue: Double,
        activeTouchLocation: CGPoint?,
        touchVelocity: CGVector
    ) {
        seedParticlesIfNeeded(in: size)
        guard !particles.isEmpty else { return }

        let now = timestamp.timeIntervalSinceReferenceDate
        let rawDt = lastStepTimestamp.map { now - $0 } ?? (1.0 / 120.0)
        lastStepTimestamp = now

        let dt = Float(min(max(rawDt, 1.0 / 240.0), 1.0 / 30.0))

        let w = Float(size.width)
        let h = Float(size.height)
        let center = SIMD2<Float>(w * 0.5, h * 0.5)
        let minDim = min(w, h)
        let amp = min(max(audioAmplitude, 0.0), 1.0)
        let crisp = min(max(highBandEnergy, 0.0), 1.0)

        let hasTouch = activeTouchLocation != nil
        let touchPos = activeTouchLocation.map { SIMD2<Float>(Float($0.x), Float($0.y)) } ?? .zero
        let touchVel = SIMD2<Float>(Float(touchVelocity.dx), Float(touchVelocity.dy))
        let touchSpeed = simd_length(touchVel)

        let previousMode = context.blendMode
        context.blendMode = .plusLighter

        for i in particles.indices {
            var p = particles[i]
            p.previousPosition = p.position

            let toParticle = p.position - center
            let radialDist = max(simd_length(toParticle), 1.0)
            let radialDir = toParticle / radialDist
            let tangentDir = SIMD2<Float>(-radialDir.y, radialDir.x) * p.angularDirection

            let desiredRadius = (p.orbitalRadiusFactor + amp * 0.085) * minDim
            let springError = desiredRadius - radialDist
            let radialSpringForce = radialDir * (springError * 1.85)

            let swirlSpeed = 24.0 + amp * 95.0 + crisp * 42.0
            let vortexForce = (tangentDir * swirlSpeed - p.velocity) * 1.35

            var totalAcceleration = radialSpringForce + vortexForce

            if hasTouch {
                let fromTouch = p.position - touchPos
                let touchDist = max(simd_length(fromTouch), 4.0)
                let interactionRadius: Float = 165.0
                if touchDist < interactionRadius {
                    let falloff = 1.0 - (touchDist / interactionRadius)
                    let quadraticFalloff = falloff * falloff

                    totalAcceleration += touchVel * (quadraticFalloff * 2.8)

                    let touchNormal = fromTouch / touchDist
                    let pressurePush = (45.0 + min(touchSpeed * 0.18, 220.0)) * quadraticFalloff
                    totalAcceleration += touchNormal * pressurePush
                }
            }

            p.velocity += totalAcceleration * dt
            let speed = simd_length(p.velocity)
            if speed > 680.0 {
                p.velocity = (p.velocity / speed) * 680.0
            }
            p.velocity *= pow(0.985, dt * 60.0)
            p.position += p.velocity * dt

            let margin: Float = 24.0
            if p.position.x < -margin { p.position.x = w + margin; p.previousPosition = p.position }
            if p.position.x > w + margin { p.position.x = -margin; p.previousPosition = p.position }
            if p.position.y < -margin { p.position.y = h + margin; p.previousPosition = p.position }
            if p.position.y > h + margin { p.position.y = -margin; p.previousPosition = p.position }

            particles[i] = p

            let wrappedHue = Double((Float(accentHue) + p.hueOffset + 1.0).truncatingRemainder(dividingBy: 1.0))
            let dynamicAlpha = Double(min(1.0, p.baseAlpha * (0.55 + amp * 1.15 + min(speed / 420.0, 0.55))))
            let particleColor = Color(hue: wrappedHue, saturation: 0.68, brightness: 0.98, opacity: dynamicAlpha)

            let currentCG = CGPoint(x: CGFloat(p.position.x), y: CGFloat(p.position.y))
            let tailVector = p.velocity * min(0.032, 0.010 + amp * 0.018)
            let tailCG = CGPoint(
                x: CGFloat(p.position.x - tailVector.x),
                y: CGFloat(p.position.y - tailVector.y)
            )

            let coreDiameter = CGFloat(p.radius * (1.0 + amp * 0.75) * 2.0)

            if simd_length(tailVector) > 1.5 {
                var streak = Path()
                streak.move(to: tailCG)
                streak.addLine(to: currentCG)
                context.stroke(
                    streak,
                    with: .color(particleColor.opacity(0.65)),
                    style: StrokeStyle(lineWidth: CGFloat(p.radius * 1.15), lineCap: .round)
                )
            }

            let coreRect = CGRect(
                x: currentCG.x - coreDiameter * 0.5,
                y: currentCG.y - coreDiameter * 0.5,
                width: coreDiameter,
                height: coreDiameter
            )
            context.fill(Path(ellipseIn: coreRect), with: .color(particleColor))
        }

        context.blendMode = previousMode
    }
}

public struct AetherSpatialBackdropView: View {
    public let audioAmplitude: Float
    public let highBandEnergy: Float
    public let beatFrequencyHz: Float
    public let accentHue: Double
    public let focusProgress: Double
    public let onTouchVelocityPulse: (Float, Float) -> Void

    @State private var simulation = ParticlePhysicsSimulation(particleCount: 156)
    @State private var shaderOriginDate = Date.now

    @State private var rippleOrigin: CGPoint = .zero
    @State private var rippleStartDate: Date = .distantPast
    @State private var rippleEnergy: Float = 0.0

    @State private var activeTouchPoint: CGPoint?
    @State private var touchVelocity: CGVector = .zero
    @State private var previousDragSample: (point: CGPoint, time: TimeInterval)?

    public init(
        audioAmplitude: Float,
        highBandEnergy: Float,
        beatFrequencyHz: Float,
        accentHue: Double,
        focusProgress: Double,
        onTouchVelocityPulse: @escaping (Float, Float) -> Void
    ) {
        self.audioAmplitude = audioAmplitude
        self.highBandEnergy = highBandEnergy
        self.beatFrequencyHz = beatFrequencyHz
        self.accentHue = accentHue
        self.focusProgress = focusProgress
        self.onTouchVelocityPulse = onTouchVelocityPulse
    }

    public var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size

            TimelineView(.animation) { timeline in
                let now = timeline.date
                let elapsed = Float(now.timeIntervalSince(shaderOriginDate))
                let rawRippleAge = Float(now.timeIntervalSince(rippleStartDate))
                let effectiveRippleEnergy: Float = (rawRippleAge >= 0 && rawRippleAge < 2.2)
                    ? rippleEnergy * exp(-rawRippleAge * 1.35)
                    : 0.0

                ZStack {
                    Rectangle()
                        .fill(.black)
                        .colorEffect(
                            ShaderLibrary.aetherAurora(
                                .float2(Float(viewportSize.width), Float(viewportSize.height)),
                                .float(elapsed),
                                .float(audioAmplitude),
                                .float(beatFrequencyHz),
                                .float(Float(accentHue)),
                                .float(Float(focusProgress))
                            )
                        )

                    Canvas(rendersAsynchronously: false) { context, canvasSize in
                        simulation.stepAndRender(
                            into: &context,
                            size: canvasSize,
                            timestamp: now,
                            audioAmplitude: audioAmplitude,
                            highBandEnergy: highBandEnergy,
                            accentHue: accentHue,
                            activeTouchLocation: activeTouchPoint,
                            touchVelocity: touchVelocity
                        )
                    }
                }
                .layerEffect(
                    ShaderLibrary.interactiveRipple(
                        .float2(Float(viewportSize.width), Float(viewportSize.height)),
                        .float2(Float(rippleOrigin.x), Float(rippleOrigin.y)),
                        .float(max(0, rawRippleAge)),
                        .float(effectiveRippleEnergy),
                        .float(audioAmplitude)
                    ),
                    maxSampleOffset: CGSize(width: 36, height: 36),
                    isEnabled: effectiveRippleEnergy > 0.002
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let nowRef = Date.timeIntervalSinceReferenceDate
                            let loc = value.location
                            activeTouchPoint = loc

                            if let prev = previousDragSample {
                                let dt = max(nowRef - prev.time, 1.0 / 240.0)
                                let vx = (loc.x - prev.point.x) / dt
                                let vy = (loc.y - prev.point.y) / dt
                                touchVelocity = CGVector(dx: vx, dy: vy)

                                let speed = hypot(vx, vy)
                                if speed > 140 || rawRippleAge > 0.28 {
                                    rippleOrigin = loc
                                    rippleStartDate = .now
                                    rippleEnergy = Float(min(max(0.45 + speed / 1800.0, 0.45), 1.35))
                                }

                                let normVel = Float(min(speed / 1600.0, 1.0))
                                let normY = Float(min(max(loc.y / max(viewportSize.height, 1), 0), 1))
                                onTouchVelocityPulse(normVel, normY)
                            } else {
                                rippleOrigin = loc
                                rippleStartDate = .now
                                rippleEnergy = 0.85
                                onTouchVelocityPulse(0.35, Float(loc.y / max(viewportSize.height, 1)))
                            }

                            previousDragSample = (loc, nowRef)
                        }
                        .onEnded { _ in
                            activeTouchPoint = nil
                            touchVelocity = .zero
                            previousDragSample = nil
                        }
                )
            }
        }
        .ignoresSafeArea()
    }
}
