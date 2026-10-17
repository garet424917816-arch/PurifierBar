import Testing
import PurifierCore

@Suite("T3 - independent probes of the presentation contract")
struct T3ProbeTests {
    @Test("PM2.5 boundaries", arguments: [
        (0, AirQuality.excellent),
        (15, .excellent), (16, .good),
        (35, .good), (36, .moderate),
        (75, .moderate), (76, .poor),
        (115, .poor), (116, .unhealthy),
        (150, .unhealthy), (151, .hazardous),
        (Int.max, .hazardous),
    ])
    func airQualityBoundaries(pm25: Int, expected: AirQuality) {
        #expect(AirQuality(pm25: pm25) == expected)
    }

    // The contract does not define negative values; we assume the lowest category.
    @Test("Negative PM2.5", arguments: [-1, Int.min])
    func negativeAirQuality(pm25: Int) {
        #expect(AirQuality(pm25: pm25) == .excellent)
    }

    @Test("Category names", arguments: [
        (AirQuality.excellent, "Excellent"),
        (.good, "Good"), (.moderate, "Moderate"),
        (.poor, "Poor"), (.unhealthy, "Unhealthy"),
        (.hazardous, "Hazardous"),
    ])
    func airQualityTitles(quality: AirQuality, expected: String) {
        #expect(quality.title == expected)
    }

    @Test("Full list of categories")
    func airQualityCases() {
        let expected: [AirQuality] = [
            .excellent, .good, .moderate, .poor, .unhealthy, .hazardous,
        ]
        #expect(AirQuality.allCases.count == expected.count)
        for quality in expected {
            #expect(AirQuality.allCases.contains(quality))
        }
    }

    @Test("RGB within 0...1", arguments: AirQuality.allCases)
    func airQualityRGBRange(quality: AirQuality) {
        let rgb = quality.rgb
        for channel in [rgb.r, rgb.g, rgb.b] {
            #expect(channel.isFinite)
            #expect((0.0...1.0).contains(channel))
        }
    }

    @Test("Monotonic transition from green to red/purple")
    func airQualityWarmth() throws {
        let qualities: [AirQuality] = [
            .excellent, .good, .moderate, .poor, .unhealthy, .hazardous,
        ]
        var hues: [Double] = []
        for quality in qualities {
            let hue = try #require(Self.warmthHue(quality.rgb))
            hues.append(hue)
        }
        // "Warmth" here is the HSV hue decline: green 120, yellow 60,
        // red 0, purple -60. The contract does not set exact RGB values.
        for index in 1..<hues.count {
            #expect(hues[index] <= hues[index - 1] + 1e-12)
        }
        #expect(hues[0] > hues[hues.count - 1])
        let first = AirQuality.excellent.rgb
        #expect(first.g > first.r)
        #expect(first.g > first.b)
        let last = AirQuality.hazardous.rgb
        #expect(last.r > last.g)
    }

    @Test("Interpolation and clamping of t", arguments: [
        (-100.0, 0.0), (-0.25, 0.0), (0.0, 0.0),
        (0.5, 0.5), (1.0, 1.0), (1.25, 1.0), (100.0, 1.0),
    ])
    func blendEndpointsAndClamping(t: Double, fraction: Double) {
        let a = (r: 0.2, g: 0.8, b: 0.4)
        let b = (r: 0.9, g: 0.1, b: 0.6)
        let actual = blendRGB(a, b, t)
        #expect(abs(actual.r - (0.2 + 0.7 * fraction)) < 1e-12)
        #expect(abs(actual.g - (0.8 - 0.7 * fraction)) < 1e-12)
        #expect(abs(actual.b - (0.4 + 0.2 * fraction)) < 1e-12)
    }

    @Test("Interpolation of identical colors", arguments: [0.0, 0.5, 1.0])
    func blendSameColor(t: Double) {
        let color = (r: 0.15, g: 0.65, b: 0.35)
        let actual = blendRGB(color, color, t)
        #expect(abs(actual.r - color.r) < 1e-12)
        #expect(abs(actual.g - color.g) < 1e-12)
        #expect(abs(actual.b - color.b) < 1e-12)
    }

    @Test("Menu bar label for all states", arguments: [
        (Connection.connecting, "18"),
        (.online, "18"), (.unreachable, "18?"),
    ])
    func menuBarWithReading(connection: Connection, expected: String) {
        #expect(PanelFormat.menuBarTitle(pm25: 18, connection: connection) == expected)
        let zeroTitle = connection == .unreachable ? "0?" : "0"
        #expect(PanelFormat.menuBarTitle(pm25: 0, connection: connection) == zeroTitle)
    }

    @Test("Menu bar label without state", arguments: [
        Connection.connecting, .online, .unreachable,
    ])
    func menuBarWithoutReading(connection: Connection) {
        #expect(PanelFormat.menuBarTitle(pm25: nil, connection: connection) == "—")
    }

    @Test("Filter format", arguments: [
        (64, 186, "64 % · 186 d"),
        (0, 0, "0 % · 0 d"),
        (100, 1, "100 % · 1 d"),
    ])
    func filterFormat(percent: Int, daysLeft: Int, expected: String) {
        #expect(PanelFormat.filter(percent: percent, daysLeft: daysLeft) == expected)
    }

    @Test("Format of all modes", arguments: [
        (PurifierMode.auto, "Auto"), (.sleep, "Sleep"), (.manual, "Manual"),
    ])
    func modeFormat(mode: PurifierMode, expected: String) {
        #expect(PanelFormat.mode(mode) == expected)
    }

    @Test("Format of all brightness levels", arguments: [
        (ScreenBrightness.off, "Off"), (.bright, "Bright"), (.dim, "Dim"),
    ])
    func screenFormat(screen: ScreenBrightness, expected: String) {
        #expect(PanelFormat.screen(screen) == expected)
    }

    @Test("Format of known errors")
    func knownFaultFormat() {
        #expect(PanelFormat.fault(.none) == nil)
        #expect(PanelFormat.fault(.motorStuck) == "Motor stuck")
        #expect(PanelFormat.fault(.sensorLost) == "Sensor lost")
    }

    @Test("Format of unknown errors", arguments: [
        (1, "Error 1"), (42, "Error 42"), (999, "Error 999"),
    ])
    func otherFaultFormat(code: Int, expected: String) {
        #expect(PanelFormat.fault(.other(code)) == expected)
    }

    private static func warmthHue(_ rgb: (r: Double, g: Double, b: Double)) -> Double? {
        let highest = max(rgb.r, rgb.g, rgb.b)
        let lowest = min(rgb.r, rgb.g, rgb.b)
        let chroma = highest - lowest
        guard chroma.isFinite, chroma > 0 else { return nil }
        var hue: Double
        if highest == rgb.r {
            hue = 60 * (rgb.g - rgb.b) / chroma
        } else if highest == rgb.g {
            hue = 60 * (2 + (rgb.b - rgb.r) / chroma)
        } else {
            hue = 60 * (4 + (rgb.r - rgb.g) / chroma)
        }
        if hue > 180 { hue -= 360 }
        return hue
    }
}
