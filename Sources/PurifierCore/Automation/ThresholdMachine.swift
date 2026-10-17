// PM2.5 threshold: pure state machine with hysteresis. Time is supplied from outside - no timers
// or waits inside, so it is easy to test on synthetic time.
import Foundation

/// Threshold settings. Default values - `.standard`.
public struct ThresholdSettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var pm25Limit: Int              // N
    public var riseDuration: TimeInterval  // how long to stay above N to turn the boost on
    public var fallDuration: TimeInterval  // how long to stay not above N to restore the mode
    public var boostLevel: Int             // Manual level that the boost sets

    /// Allowed range of the boost level.
    public static let boostLevelRange = 0...14
    public static let riseMinutesRange = 1...180
    public static let fallMinutesRange = 1...360

    public static let standard = ThresholdSettings(
        isEnabled: true,
        pm25Limit: 35,
        riseDuration: 120,
        fallDuration: 600,
        boostLevel: 14
    )

    public init(
        isEnabled: Bool = true,
        pm25Limit: Int = 35,
        riseDuration: TimeInterval = 120,
        fallDuration: TimeInterval = 600,
        boostLevel: Int = 14
    ) {
        self.isEnabled = isEnabled
        self.pm25Limit = pm25Limit
        self.riseDuration = riseDuration
        self.fallDuration = fallDuration
        self.boostLevel = Self.clampBoostLevel(boostLevel)
    }

    /// Files written before the boost level appeared have no `boostLevel` key:
    /// then we take 14. Values outside 0...14 are clamped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        pm25Limit = try container.decode(Int.self, forKey: .pm25Limit)
        riseDuration = Self.boundedDuration(
            try container.decode(TimeInterval.self, forKey: .riseDuration), minutes: Self.riseMinutesRange
        )
        fallDuration = Self.boundedDuration(
            try container.decode(TimeInterval.self, forKey: .fallDuration), minutes: Self.fallMinutesRange
        )
        boostLevel = Self.clampBoostLevel(
            try container.decodeIfPresent(Int.self, forKey: .boostLevel) ?? Self.standard.boostLevel
        )
    }

    /// Invalid values (N < 0, durations <= 0) are equivalent to a disabled threshold.
    var isActive: Bool {
        isEnabled && pm25Limit >= 0 && riseDuration > 0 && fallDuration > 0
    }

    private static func clampBoostLevel(_ level: Int) -> Int {
        min(max(level, boostLevelRange.lowerBound), boostLevelRange.upperBound)
    }

    /// Safe display conversion, including values assigned without going through Codable.
    public static func clampedMinutes(for duration: TimeInterval, in range: ClosedRange<Int>) -> Int {
        guard duration.isFinite else { return range.upperBound }
        let minutes = min(max(duration / 60, Double(range.lowerBound)), Double(range.upperBound))
        return Int(minutes.rounded())
    }

    private static func boundedDuration(_ duration: TimeInterval, minutes: ClosedRange<Int>) -> TimeInterval {
        let maximum = TimeInterval(minutes.upperBound) * 60
        // Keep finite nonpositive durations: they disable the threshold.
        return duration.isFinite ? min(duration, maximum) : maximum
    }
}

/// Pure threshold state machine. Time is supplied from outside.
public struct ThresholdMachine: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Wait for PM2.5 at or below the threshold before allowing another boost.
        case suppressed
        case rising(since: Date)
        /// `level` - the remembered boost level: external interference is considered
        /// only a deviation from it, not from the current settings.
        case boosting(restore: PurifierCommand, level: Int, calmSince: Date?)
    }

    public private(set) var phase: Phase

    public init() {
        phase = .idle
    }

    /// New confirmed state or a check on the deadline.
    /// Returns the commands and the moment of the next check without new data (`nil` - not needed).
    public mutating func evaluate(
        state: PurifierState,
        settings: ThresholdSettings,
        now: Date,
        favoriteLevelRange: ClosedRange<Int> = ThresholdSettings.boostLevelRange
    ) -> (commands: [PurifierCommand], recheckAt: Date?) {
        guard settings.isActive else { return disable() }

        // An unmodeled device mode is not evidence of manual interference. Wait for
        // a known mode before starting a boost or comparing it with the active boost.
        guard state.mode != nil || !state.isOn else { return ([], nil) }
        let boostLevel = min(max(settings.boostLevel, favoriteLevelRange.lowerBound), favoriteLevelRange.upperBound)

        switch phase {
        case .suppressed:
            if state.pm25 <= settings.pm25Limit { phase = .idle }
            return ([], nil)

        case .idle:
            guard state.isOn, state.pm25 > settings.pm25Limit else { return ([], nil) }
            phase = .rising(since: now)
            return ([], now.addingTimeInterval(settings.riseDuration))

        case .rising(let since):
            guard state.isOn, state.pm25 > settings.pm25Limit else {
                phase = .idle
                return ([], nil)
            }
            guard now.timeIntervalSince(since) >= settings.riseDuration else {
                return ([], since.addingTimeInterval(settings.riseDuration))
            }
            // Time is up. The boost must not lower speed: in Manual with a level not
            // lower than the boost it is not needed - we stay calm.
            if state.mode == .manual, state.favoriteLevel >= boostLevel {
                phase = .idle
                return ([], nil)
            }
            // Fix the mode to return to, and the boost level for this cycle.
            let level = boostLevel
            guard let restore = restoreCommand(for: state) else { return ([], nil) }
            phase = .boosting(restore: restore, level: level, calmSince: nil)
            return ([.manualLevel(level)], nil)

        case .boosting(let restore, let level, let calmSince):
            // A state other than Manual with the remembered boost level means
            // external interference (a button on the device, the panel, turning it off) -
            // the boost is cancelled without restoring.
            guard state.isOn, state.mode == .manual, state.favoriteLevel == level else {
                cancelBoost(state: state, settings: settings)
                return ([], nil)
            }
            guard state.pm25 <= settings.pm25Limit else {
                phase = .boosting(restore: restore, level: level, calmSince: nil)   // air is dirty again
                return ([], nil)
            }
            guard let calmSince else {
                let start = now
                phase = .boosting(restore: restore, level: level, calmSince: start)
                return ([], start.addingTimeInterval(settings.fallDuration))
            }
            guard now.timeIntervalSince(calmSince) >= settings.fallDuration else {
                return ([], calmSince.addingTimeInterval(settings.fallDuration))
            }
            phase = .idle
            return ([restore], nil)
        }
    }

    /// Cancel without restore; dirty air suppresses the next boost until it clears.
    public mutating func cancelBoost(state: PurifierState?, settings: ThresholdSettings) {
        if let state, state.pm25 > settings.pm25Limit {
            phase = .suppressed
        } else {
            phase = .idle
        }
    }

    private mutating func disable() -> (commands: [PurifierCommand], recheckAt: Date?) {
        if case .boosting(let restore, _, _) = phase {
            phase = .idle
            return ([restore], nil)   // were boosting - we restore the mode that it displaced
        }
        phase = .idle
        return ([], nil)
    }

    private func restoreCommand(for state: PurifierState) -> PurifierCommand? {
        switch state.mode {
        case .auto: return .mode(.auto)
        case .sleep: return .mode(.sleep)
        case .manual: return .manualLevel(state.favoriteLevel)
        case nil: return nil
        }
    }
}
