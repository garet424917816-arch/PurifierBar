// Air quality presentation: PM2.5 levels, names and colors for the glow.
// No SwiftUI - only numbers and strings, so it is covered by `swift test`.
import Foundation

/// Air-quality level by PM2.5. Boundaries - README/contract T3.
public enum AirQuality: Sendable, Equatable, CaseIterable {
    case excellent
    case good
    case moderate
    case poor
    case unhealthy
    case hazardous

    /// 0-15, 16-35, 36-75, 76-115, 116-150, 151+.
    public init(pm25: Int) {
        switch pm25 {
        case ..<16: self = .excellent
        case 16...35: self = .good
        case 36...75: self = .moderate
        case 76...115: self = .poor
        case 116...150: self = .unhealthy
        default: self = .hazardous
        }
    }

    /// Level name for the panel.
    public var title: String {
        switch self {
        case .excellent: return String(localized: "Excellent")
        case .good: return String(localized: "Good")
        case .moderate: return String(localized: "Moderate")
        case .poor: return String(localized: "Poor")
        case .unhealthy: return String(localized: "Unhealthy")
        case .hazardous: return String(localized: "Hazardous")
        }
    }

    /// Glow color, components 0...1: from green through yellow and
    /// orange to red and purple.
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .excellent: return (0.20, 0.78, 0.45)
        case .good: return (0.62, 0.82, 0.30)
        case .moderate: return (0.95, 0.76, 0.20)
        case .poor: return (0.96, 0.55, 0.16)
        case .unhealthy: return (0.91, 0.29, 0.24)
        case .hazardous: return (0.55, 0.25, 0.60)
        }
    }
}

/// Linear interpolation between two colors. `t` is clamped to 0...1.
public func blendRGB(
    _ from: (r: Double, g: Double, b: Double),
    _ to: (r: Double, g: Double, b: Double),
    _ t: Double
) -> (r: Double, g: Double, b: Double) {
    let k = min(max(t, 0), 1)
    return (
        from.r + (to.r - from.r) * k,
        from.g + (to.g - from.g) * k,
        from.b + (to.b - from.b) * k
    )
}
