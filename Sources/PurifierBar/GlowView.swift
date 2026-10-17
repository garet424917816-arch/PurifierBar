// Live glow of the panel on Core Animation: a radial gradient layer for the glow
// and 40 round particle layers. The render server computes the particle motion (separate
// infinite animations of position.x / position.y - a sine via autoreverses
// + easeInEaseOut, the phase via timeOffset). The process only sets parameters on
// state change, with no per-frame drawing.
import AppKit
import PurifierCore
import QuartzCore
import SwiftUI

// MARK: - Input model

/// Input data of the glow. `Equatable`, so `updateNSView` does no extra work.
private struct GlowInputs: Equatable {
    var quality: AirQuality
    var isOn: Bool
    var mode: PurifierMode?
    var motorRPM: Int
    var favoriteLevel: Int
    var favoriteLevelMax: Int
    var isBoosting: Bool
    var paused: Bool

    /// Particle flow speed: Sleep - slower, Manual - by level,
    /// Auto - by fan RPM. A disabled device - static.
    var tempo: Double {
        guard isOn else { return 0 }
        var value: Double
        switch mode {
        case .sleep:
            value = 0.35
        case .auto, nil:
            value = 0.4 + min(1, Double(motorRPM) / 1200) * 0.9
        case .manual:
            let top = max(favoriteLevelMax, 1)
            value = 0.45 + Double(min(max(favoriteLevel, 0), top)) / Double(top) * 1.0
        }
        if isBoosting { value *= 1.5 }
        return value
    }

    /// Brightness and size of the glow: 1 enabled, dimmed when disabled.
    var energy: Double { isOn ? 1 : GlowConstants.offEnergy }

    /// Speed of the container layer: pause and a disabled device stop the motion.
    var speed: Double { paused ? 0 : tempo }
}

private enum GlowConstants {
    static let colorTransition: TimeInterval = 1.0
    static let energyTransition: TimeInterval = 0.8
    static let offEnergy = 0.18
}

// MARK: - SwiftUI wrapper

struct GlowView: NSViewRepresentable {
    let quality: AirQuality
    let isOn: Bool
    let mode: PurifierMode?
    let motorRPM: Int
    let favoriteLevel: Int
    /// Top of the device's favorite level range (layout-specific: 14, 11 or 9).
    let favoriteLevelMax: Int
    let isBoosting: Bool
    let paused: Bool

    func makeNSView(context: Context) -> GlowHostView { GlowHostView() }

    func updateNSView(_ nsView: GlowHostView, context: Context) {
        nsView.apply(GlowInputs(
            quality: quality,
            isOn: isOn,
            mode: mode,
            motorRPM: motorRPM,
            favoriteLevel: favoriteLevel,
            favoriteLevelMax: favoriteLevelMax,
            isBoosting: isBoosting,
            paused: paused
        ))
    }
}

// MARK: - Layer tree

/// NSView with a `CALayer` tree: the glow (radial gradient) and the particles.
/// The particle motion is set by infinite animations, so the process barely
/// uses CPU - the render server draws everything.
final class GlowHostView: NSView {
    private let container = CALayer()
    private let glowLayer = CAGradientLayer()
    private let particleGroup = CALayer()
    private let particleLayers: [CALayer]

    /// Last applied input; `nil` - never yet.
    private var inputs: GlowInputs?
    /// Target color and energy (for transitions and size recalculation).
    private var tint = RGB(AirQuality.excellent.rgb)
    private var energy = 1.0
    private var hasAppliedSpeed = false
    /// Size for which the particle motion is already configured (so as not to reset the phase).
    private var motionSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        particleLayers = GlowParticles.all.map { _ in CALayer() }
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false

        // The container sets the particle speed (tempo / pause).
        container.masksToBounds = false
        layer?.addSublayer(container)

        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 1)  // radii of the ellipse - on both axes; y = 0.5 gave zero height
        glowLayer.locations = [0, 0.55, 1]
        glowLayer.compositingFilter = "plusLighter"
        glowLayer.colors = glowColors(tint, energy)
        container.addSublayer(glowLayer)

        // Particles are in a separate group: one `plusLighter` for all of them.
        particleGroup.compositingFilter = "plusLighter"
        particleGroup.masksToBounds = false
        container.addSublayer(particleGroup)

        for layer in particleLayers {
            particleGroup.addSublayer(layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Size

    override func layout() {
        super.layout()
        // Layout without animation: the size is recalculated instantly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        placeLayers(fromEnergy: nil, duration: 0)
        CATransaction.commit()
    }

    // MARK: - Applying state

    fileprivate func apply(_ newInputs: GlowInputs) {
        guard newInputs != inputs else { return }
        let firstTime = inputs == nil
        let previous = inputs
        let oldTint = tint
        let oldEnergy = energy

        tint = RGB(newInputs.quality.rgb)
        energy = newInputs.energy
        inputs = newInputs

        let colorChanged = previous.map { $0.quality != newInputs.quality } ?? false
        let energyChanged = previous.map { $0.isOn != newInputs.isOn } ?? false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if firstTime {
            placeLayers(fromEnergy: nil, duration: 0)
            applyGlowColors(from: nil, duration: 0)
            applyParticleColors(from: nil, duration: 0)
        } else if energyChanged {
            // Energy changes both opacity and size - we transition together.
            placeLayers(fromEnergy: oldEnergy, duration: GlowConstants.energyTransition)
            applyGlowColors(from: (oldTint, oldEnergy), duration: GlowConstants.energyTransition)
            applyParticleColors(from: (oldTint, oldEnergy), duration: GlowConstants.energyTransition)
        } else if colorChanged {
            applyGlowColors(from: (oldTint, oldEnergy), duration: GlowConstants.colorTransition)
            applyParticleColors(from: (oldTint, oldEnergy), duration: GlowConstants.colorTransition)
        }
        CATransaction.commit()

        applySpeed(newInputs.speed)
    }

    // MARK: - Container speed (tempo / pause)

    /// Smooth speed change without jumps: we keep the layer's local time.
    private func applySpeed(_ speed: Double) {
        if hasAppliedSpeed, Float(speed) == container.speed { return }
        let now = CACurrentMediaTime()
        if !hasAppliedSpeed {
            hasAppliedSpeed = true
            container.beginTime = now
            container.timeOffset = 0
            container.speed = Float(speed)
            return
        }
        let local = container.convertTime(now, from: nil)
        if speed == 0 {
            // Pause: the local time freezes at timeOffset.
            container.speed = 0
            container.timeOffset = local
            container.beginTime = 0
        } else {
            container.speed = Float(speed)
            container.timeOffset = 0
            container.beginTime = now - local / speed
        }
    }

    // MARK: - Layer geometry

    /// Positions the glow and the particles for the current size. Animates only
    /// the energy transition (and only when `oldEnergy` is set).
    private func placeLayers(fromEnergy old: Double?, duration: CFTimeInterval) {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        let animated = old != nil && duration > 0
        // We set the motion only when the size changes: otherwise the particle phase would reset.
        let sizeChanged = CGSize(width: width, height: height) != motionSize
        motionSize = CGSize(width: width, height: height)

        particleGroup.frame = CGRect(x: 0, y: 0, width: width, height: height)

        // Glow: center at 0.56 of the height (CALayer coordinates - from the bottom).
        let newRadius = min(width, height) * (0.7 + 0.3 * energy)
        let newGlowBounds = CGRect(x: 0, y: 0, width: newRadius * 2, height: newRadius * 2)
        if animated, let old {
            let oldRadius = min(width, height) * (0.7 + 0.3 * old)
            animateBounds(
                glowLayer,
                from: CGRect(x: 0, y: 0, width: oldRadius * 2, height: oldRadius * 2),
                to: newGlowBounds,
                duration: duration
            )
        } else {
            glowLayer.bounds = newGlowBounds
        }
        glowLayer.position = CGPoint(x: width / 2, y: height * 0.44)

        let centerX = width / 2
        let centerTop = height * 0.56
        for (index, particle) in GlowParticles.all.enumerated() {
            let layer = particleLayers[index]
            let newParticleRadius = particle.radius * (0.5 + 0.9 * energy)
            let base = CGPoint(
                x: centerX + (particle.x - 0.5) * width,
                y: height - (centerTop + (particle.y - 0.5) * height)
            )
            let newBounds = CGRect(
                x: 0, y: 0,
                width: newParticleRadius * 2, height: newParticleRadius * 2
            )
            if animated, let old {
                let oldParticleRadius = particle.radius * (0.5 + 0.9 * old)
                animateBounds(
                    layer,
                    from: CGRect(x: 0, y: 0, width: oldParticleRadius * 2, height: oldParticleRadius * 2),
                    to: newBounds,
                    duration: duration
                )
                animateCornerRadius(layer, from: oldParticleRadius, to: newParticleRadius, duration: duration)
            } else {
                layer.bounds = newBounds
                layer.cornerRadius = newParticleRadius
            }
            layer.position = base
            if sizeChanged {
                installMotion(layer, particle: particle, base: base, size: CGSize(width: width, height: height))
            }
        }
    }

    // MARK: - Particle motion

    /// A separate infinite animation for each axis: a sine via
    /// `autoreverses` + `easeInEaseOut`, the phase via `timeOffset`.
    /// The period comes from `particle.speed`; slowness/pause via the container's `speed`.
    private func installMotion(_ layer: CALayer, particle: Particle, base: CGPoint, size: CGSize) {
        let speed = max(particle.speed, 0.0001)

        let amplitudeX = particle.amplitude * Double(size.width) * 0.16
        let periodX = 2 * Double.pi / speed
        addOscillation(
            layer, key: "glow.x", keyPath: "position.x",
            center: Double(base.x), amplitude: amplitudeX,
            period: periodX, timeOffset: particle.phase / speed
        )

        let amplitudeY = particle.amplitude * Double(size.height) * 0.16
        let periodY = 2 * Double.pi / (0.85 * speed)
        let offsetY = 1.85 * particle.phase * periodY / (2 * Double.pi) - periodY / 4
        addOscillation(
            layer, key: "glow.y", keyPath: "position.y",
            center: Double(base.y), amplitude: amplitudeY,
            period: periodY, timeOffset: offsetY
        )
    }

    private func addOscillation(
        _ layer: CALayer, key: String, keyPath: String,
        center: Double, amplitude: Double, period: Double, timeOffset: Double
    ) {
        guard period > 0, amplitude > 0 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = center + amplitude
        animation.toValue = center - amplitude
        animation.duration = period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        var offset = timeOffset.truncatingRemainder(dividingBy: period)
        if offset < 0 { offset += period }
        animation.timeOffset = offset
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    // MARK: - Color

    private func applyGlowColors(from old: (RGB, Double)?, duration: CFTimeInterval) {
        let colors = glowColors(tint, energy)
        if let old, duration > 0 {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = glowColors(old.0, old.1)
            animation.toValue = colors
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glowLayer.add(animation, forKey: "colors")
        }
        glowLayer.colors = colors
    }

    private func applyParticleColors(from old: (RGB, Double)?, duration: CFTimeInterval) {
        for (index, particle) in GlowParticles.all.enumerated() {
            let layer = particleLayers[index]
            let to = color(tint, alpha: particle.alpha * energy)
            if let old, duration > 0 {
                let animation = CABasicAnimation(keyPath: "backgroundColor")
                animation.fromValue = color(old.0, alpha: particle.alpha * old.1)
                animation.toValue = to
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: "backgroundColor")
            }
            layer.backgroundColor = to
        }
    }

    private func glowColors(_ rgb: RGB, _ energy: Double) -> [CGColor] {
        [
            color(rgb, alpha: 0.50 * energy),
            color(rgb, alpha: 0.16 * energy),
            color(rgb, alpha: 0),
        ]
    }

    private func color(_ rgb: RGB, alpha: Double) -> CGColor {
        CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    // MARK: - Geometry animations

    private func animateBounds(_ layer: CALayer, from: CGRect, to: CGRect, duration: CFTimeInterval) {
        layer.bounds = to
        let animation = CABasicAnimation(keyPath: "bounds")
        animation.fromValue = NSValue(rect: from)
        animation.toValue = NSValue(rect: to)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "bounds")
    }

    private func animateCornerRadius(_ layer: CALayer, from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        layer.cornerRadius = to
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "cornerRadius")
    }
}

// MARK: - Particles

private struct Particle: Sendable {
    var x: Double
    var y: Double
    var radius: Double
    var phase: Double
    var speed: Double
    var amplitude: Double
    var alpha: Double
}

private enum GlowParticles {
    /// Up to 40 particles; the positions are fixed, the motion comes from infinite animations.
    static let all: [Particle] = makeParticles(count: 40)

    static func makeParticles(count: Int) -> [Particle] {
        // Deterministic generator: the pattern is stable between runs and tests.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        return (0..<count).map { _ in
            Particle(
                x: next(),
                y: next(),
                radius: 0.8 + next() * 2.6,
                phase: next() * Double.pi * 2,
                speed: 0.05 + next() * 0.12,
                amplitude: 0.3 + next() * 0.9,
                alpha: 0.10 + next() * 0.28
            )
        }
    }
}

// MARK: - Color values

private struct RGB: Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(_ value: (r: Double, g: Double, b: Double)) {
        r = value.r
        g = value.g
        b = value.b
    }
}
