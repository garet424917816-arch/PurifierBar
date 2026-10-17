// Model-specific property maps and value encodings from the released MIoT specifications.

public struct PurifierLayout: Sendable, Equatable {
    public let name: String
    public let power: PropertyID
    public let fault: PropertyID
    public let mode: PropertyID
    public let pm25: PropertyID
    public let filterPercent: PropertyID
    public let filterHoursUsed: PropertyID
    public let filterDaysLeft: PropertyID?
    public let sound: PropertyID
    public let childLock: PropertyID
    public let screen: PropertyID
    public let motorRPM: PropertyID
    public let favoriteLevel: PropertyID
    public let favoriteLevelRange: ClosedRange<Int>
    public let screenOff: Int
    public let screenDim: Int
    public let screenBright: Int
    public let motorStuckCode: Int?
    public let sensorLostCode: Int?

    public var all: [PropertyID] {
        [power, fault, mode, pm25, filterPercent, filterHoursUsed]
            + (filterDaysLeft.map { [$0] } ?? [])
            + [sound, childLock, motorRPM, favoriteLevel, screen]
    }

    public func screenValue(_ brightness: ScreenBrightness) -> Int {
        switch brightness {
        case .off: screenOff
        case .dim: screenDim
        case .bright: screenBright
        }
    }

    public func screenBrightness(value: Int) -> ScreenBrightness? {
        ScreenBrightness.allCases.first { screenValue($0) == value }
    }

    public func purifierFault(code: Int) -> PurifierFault {
        if code == 0 { return .none }
        if code == motorStuckCode { return .motorStuck }
        if code == sensorLostCode { return .sensorLost }
        return .other(code)
    }

    public func clampedLevel(_ level: Int) -> Int {
        min(max(level, favoriteLevelRange.lowerBound), favoriteLevelRange.upperBound)
    }

    public static let cpa4 = PurifierLayout(
        name: "cpa4", power: .init(siid: 2, piid: 1), fault: .init(siid: 2, piid: 2),
        mode: .init(siid: 2, piid: 4), pm25: .init(siid: 3, piid: 4),
        filterPercent: .init(siid: 4, piid: 1), filterHoursUsed: .init(siid: 4, piid: 3),
        filterDaysLeft: .init(siid: 4, piid: 4), sound: .init(siid: 6, piid: 1),
        childLock: .init(siid: 8, piid: 1), screen: .init(siid: 13, piid: 2),
        motorRPM: .init(siid: 9, piid: 1), favoriteLevel: .init(siid: 9, piid: 11),
        favoriteLevelRange: 0...14, screenOff: 0, screenDim: 1, screenBright: 2,
        motorStuckCode: 2, sensorLostCode: 3
    )
    public static let rma1 = cpa4.variant(name: "rma1", favoriteLevel: .init(siid: 9, piid: 2))
    public static let rma2 = cpa4.variant(
        name: "rma2", sound: .init(siid: 5, piid: 1), childLock: .init(siid: 6, piid: 1),
        screen: .init(siid: 7, piid: 2), motorRPM: .init(siid: 8, piid: 1),
        favoriteLevel: .init(siid: 11, piid: 1)
    )
    public static let mb5 = cpa4.variant(
        name: "mb5", favoriteLevel: .init(siid: 9, piid: 5), maximumLevel: 11, standardFaults: false
    )
    public static let mb3 = PurifierLayout(
        name: "mb3", power: .init(siid: 2, piid: 2), fault: .init(siid: 2, piid: 1),
        mode: .init(siid: 2, piid: 5), pm25: .init(siid: 3, piid: 6),
        filterPercent: .init(siid: 4, piid: 3), filterHoursUsed: .init(siid: 4, piid: 5),
        filterDaysLeft: nil, sound: .init(siid: 5, piid: 1),
        childLock: .init(siid: 7, piid: 1), screen: .init(siid: 6, piid: 1),
        motorRPM: .init(siid: 10, piid: 8), favoriteLevel: .init(siid: 10, piid: 10),
        favoriteLevelRange: 0...14, screenOff: 2, screenDim: 1, screenBright: 0,
        motorStuckCode: 2, sensorLostCode: 3
    )
    public static let proH = mb3.variant(name: "proH", maximumLevel: 9)
    public static let za1 = mb3.variant(
        name: "za1", power: .init(siid: 2, piid: 1), fault: .init(siid: 2, piid: 2),
        motorRPM: .init(siid: 10, piid: 11)
    )

    private func variant(
        name: String, power: PropertyID? = nil, fault: PropertyID? = nil,
        sound: PropertyID? = nil, childLock: PropertyID? = nil, screen: PropertyID? = nil,
        motorRPM: PropertyID? = nil, favoriteLevel: PropertyID? = nil,
        maximumLevel: Int? = nil, standardFaults: Bool = true
    ) -> PurifierLayout {
        PurifierLayout(
            name: name, power: power ?? self.power, fault: fault ?? self.fault,
            mode: mode, pm25: pm25, filterPercent: filterPercent, filterHoursUsed: filterHoursUsed,
            filterDaysLeft: filterDaysLeft, sound: sound ?? self.sound, childLock: childLock ?? self.childLock,
            screen: screen ?? self.screen, motorRPM: motorRPM ?? self.motorRPM,
            favoriteLevel: favoriteLevel ?? self.favoriteLevel,
            favoriteLevelRange: 0...(maximumLevel ?? favoriteLevelRange.upperBound),
            screenOff: screenOff, screenDim: screenDim, screenBright: screenBright,
            motorStuckCode: standardFaults ? motorStuckCode : nil,
            sensorLostCode: standardFaults ? sensorLostCode : nil
        )
    }
}
