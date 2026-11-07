// MARK: - FILE: OrbitalSDFCoreView.swift

import SwiftUI
import simd

// MARK: - 3D Sphere-Traced SDF Orbital Portal View with Interactive 2-Axis Camera Orbit

public struct OrbitalSDFCoreView: View {
    public let title: String
    public let formattedRemainingTime: String
    public let binauralBeatHz: Float
    public let isTimerRunning: Bool
    public let focusProgress: Double
    public let accentHue: Double
    public let lowEnergy: Float
    public let midEnergy: Float
    public let highEnergy: Float
    public let diameter: CGFloat

    @State private var shaderOriginDate = Date.now
    @State private var committedCameraOrbit = SIMD2<Float>(0.0, 0.18)
    @State private var activeOrbitDragDelta = SIMD2<Float>.zero

    public init(
        title: String = "Free Spatial Flow",
        formattedRemainingTime: String = "25:00",
        binauralBeatHz: Float = 14.0,
        isTimerRunning: Bool = false,
        focusProgress: Double = 0.0,
        accentHue: Double = 0.56,
        lowEnergy: Float = 0.25,
        midEnergy: Float = 0.22,
        highEnergy: Float = 0.18,
        diameter: CGFloat = 196
    ) {
        self.title = title
        self.formattedRemainingTime = formattedRemainingTime
        self.binauralBeatHz = binauralBeatHz
        self.isTimerRunning = isTimerRunning
        self.focusProgress = focusProgress
        self.accentHue = accentHue
        self.lowEnergy = lowEnergy
        self.midEnergy = midEnergy
        self.highEnergy = highEnergy
        self.diameter = max(140, diameter)
    }

    private var effectiveCameraOrbit: SIMD2<Float> {
        let yaw = committedCameraOrbit.x + activeOrbitDragDelta.x
        let pitch = min(max(committedCameraOrbit.y + activeOrbitDragDelta.y, -1.22), 1.22)
        return SIMD2<Float>(yaw, pitch)
    }

    public var body: some View {
        let clampedHue = (accentHue.truncatingRemainder(dividingBy: 1.0) + 1.0)
            .truncatingRemainder(dividingBy: 1.0)
        let ringPrimary = Color(hue: clampedHue, saturation: 0.74, brightness: 0.98)
        let ringSecondary = Color(
            hue: (clampedHue + 0.16).truncatingRemainder(dividingBy: 1.0),
            saturation: 0.68,
            brightness: 0.95
        )
        let combinedEnergy = min(max((lowEnergy + midEnergy + highEnergy) / 3.0, 0.0), 1.0)
        let orbit = effectiveCameraOrbit

        TimelineView(.animation) { timeline in
            let elapsed = Float(timeline.date.timeIntervalSince(shaderOriginDate))

            ZStack {
                // 1. 64-Step Sphere-Traced 3D SDF Core Portal
                Circle()
                    .fill(.black)
                    .colorEffect(
                        ShaderLibrary.aetherRaymarchedCore(
                            .float2(Float(diameter), Float(diameter)),
                            .float(elapsed),
                            .float(lowEnergy),
                            .float(midEnergy),
                            .float(highEnergy),
                            .float(Float(clampedHue)),
                            .float(Float(min(max(focusProgress, 0.0), 1.0))),
                            .float2(orbit.x, orbit.y)
                        )
                    )
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1.0)
                    }
                    .shadow(
                        color: ringPrimary.opacity(0.26 + Double(combinedEnergy) * 0.36),
                        radius: 24
                    )

                // 2. Orbital Focus Progress Track & Active Arc
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 6.5)
                    .padding(8)

                Circle()
                    .trim(from: 0.0, to: max(0.015, min(1.0, focusProgress)))
                    .stroke(
                        AngularGradient(
                            colors: [ringPrimary, ringSecondary, .white, ringPrimary],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(8)
                    .animation(.linear(duration: 0.15), value: focusProgress)

                // 3. Spatial Timer & Binaural Beat Hz HUD Overlay
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(1)
                        .frame(maxWidth: diameter * 0.66)
                        .shadow(color: .black.opacity(0.65), radius: 4)

                    Text(formattedRemainingTime)
                        .font(.system(size: diameter * 0.175, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .shadow(color: .black.opacity(0.72), radius: 6)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(isTimerRunning ? Color.green : Color.white.opacity(0.40))
                            .frame(width: 6, height: 6)

                        Text(String(format: "%.1f Hz", binauralBeatHz))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ringPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial.opacity(0.75), in: Capsule(style: .continuous))
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let sensitivity: Float = 0.014
                        activeOrbitDragDelta = SIMD2<Float>(
                            Float(drag.translation.width) * sensitivity,
                            Float(-drag.translation.height) * sensitivity
                        )
                    }
                    .onEnded { _ in
                        committedCameraOrbit = effectiveCameraOrbit
                        activeOrbitDragDelta = .zero
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    committedCameraOrbit = SIMD2<Float>(0.0, 0.18)
                    activeOrbitDragDelta = .zero
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(formattedRemainingTime), \(String(format: "%.1f", binauralBeatHz)) Hertz")
        }
    }
}
