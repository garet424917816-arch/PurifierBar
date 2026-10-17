// Tests of the pure threshold state machine on synthetic time - no waits.
import Foundation
import Testing
@testable import PurifierCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private let settings = ThresholdSettings(
    isEnabled: true,
    pm25Limit: 35,
    riseDuration: 120,
    fallDuration: 600
)

/// Drives the machine into the boost phase and returns it.
private func boosted(
    from initial: PurifierState,
    settings: ThresholdSettings = settings
) -> ThresholdMachine {
    var machine = ThresholdMachine()
    _ = machine.evaluate(state: initial, settings: settings, now: t0)
    _ = machine.evaluate(state: initial, settings: settings, now: t0.addingTimeInterval(settings.riseDuration))
    return machine
}

// MARK: - idle -> rising

@Test func idleStartsRisingWhenDirtyAndOn() {
    var machine = ThresholdMachine()
    let result = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0)
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == t0.addingTimeInterval(120))
    #expect(machine.phase == .rising(since: t0))
}

@Test func idleStaysWhenCleanOrOff() {
    var machine = ThresholdMachine()
    #expect(machine.evaluate(state: automationState(pm25: 10), settings: settings, now: t0).recheckAt == nil)
    #expect(machine.phase == .idle)

    var off = ThresholdMachine()
    #expect(off.evaluate(state: automationState(isOn: false, pm25: 90), settings: settings, now: t0).recheckAt == nil)
    #expect(off.phase == .idle)
}

@Test func pm25EqualToLimitIsNotDirty() {
    var machine = ThresholdMachine()
    let result = machine.evaluate(state: automationState(pm25: 35), settings: settings, now: t0)
    #expect(result.recheckAt == nil)
    #expect(machine.phase == .idle)
}

// MARK: - rising

@Test func risingCancelsWhenClean() {
    var machine = ThresholdMachine()
    _ = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0)
    let result = machine.evaluate(state: automationState(pm25: 10), settings: settings, now: t0.addingTimeInterval(10))
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == nil)
    #expect(machine.phase == .idle)
}

@Test func risingCancelsWhenSwitchedOff() {
    var machine = ThresholdMachine()
    _ = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0)
    let result = machine.evaluate(state: automationState(isOn: false, pm25: 60), settings: settings, now: t0.addingTimeInterval(10))
    #expect(result.commands.isEmpty)
    #expect(machine.phase == .idle)
}

@Test func risingBoostsOnlyAfterDuration() {
    var machine = ThresholdMachine()
    _ = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0)

    let early = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0.addingTimeInterval(119))
    #expect(early.commands.isEmpty)
    #expect(early.recheckAt == t0.addingTimeInterval(120))

    let fired = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0.addingTimeInterval(120))
    #expect(fired.commands == [.manualLevel(14)])
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 14, calmSince: nil))
}

// MARK: - restore mode, fixed at boost start

@Test func boostRestoresAuto() {
    let machine = boosted(from: automationState(mode: .auto, pm25: 60))
    guard case .boosting(let restore, _, _) = machine.phase else { Issue.record("not boosting"); return }
    #expect(restore == .mode(.auto))
}

@Test func boostRestoresSleep() {
    let machine = boosted(from: automationState(mode: .sleep, pm25: 60))
    guard case .boosting(let restore, _, _) = machine.phase else { Issue.record("not boosting"); return }
    #expect(restore == .mode(.sleep))
}

@Test func boostRestoresManualLevel() {
    let machine = boosted(from: automationState(mode: .manual, pm25: 60, favoriteLevel: 5))
    guard case .boosting(let restore, _, _) = machine.phase else { Issue.record("not boosting"); return }
    #expect(restore == .manualLevel(5))
}

// MARK: - boosting: hysteresis down

@Test func boostingCalmsThenRestores() {
    var machine = boosted(from: automationState(mode: .auto, pm25: 60))

    let calmAt = t0.addingTimeInterval(200)
    let calm = machine.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 14), settings: settings, now: calmAt)
    #expect(calm.commands.isEmpty)
    #expect(calm.recheckAt == calmAt.addingTimeInterval(600))
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 14, calmSince: calmAt))

    let restored = machine.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 14), settings: settings, now: calmAt.addingTimeInterval(600))
    #expect(restored.commands == [.mode(.auto)])
    #expect(restored.recheckAt == nil)
    #expect(machine.phase == .idle)
}

@Test func boostingCleansResetCalmCountdown() {
    var machine = boosted(from: automationState(pm25: 60))
    let calmAt = t0.addingTimeInterval(200)
    _ = machine.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 14), settings: settings, now: calmAt)

    // Air is dirty again - the calm countdown resets.
    let dirty = machine.evaluate(state: automationState(mode: .manual, pm25: 90, favoriteLevel: 14), settings: settings, now: calmAt.addingTimeInterval(300))
    #expect(dirty.commands.isEmpty)
    #expect(dirty.recheckAt == nil)
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 14, calmSince: nil))
}

@Test func boostingNotRestoredBeforeFallDuration() {
    var machine = boosted(from: automationState(pm25: 60))
    let calmAt = t0.addingTimeInterval(200)
    _ = machine.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 14), settings: settings, now: calmAt)
    let early = machine.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 14), settings: settings, now: calmAt.addingTimeInterval(599))
    #expect(early.commands.isEmpty)
    #expect(early.recheckAt == calmAt.addingTimeInterval(600))
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 14, calmSince: calmAt))
}

// MARK: - boosting: external interference

@Test func externalModeChangeCancelsBoost() {
    var machine = boosted(from: automationState(pm25: 60))
    let result = machine.evaluate(state: automationState(mode: .auto, pm25: 90), settings: settings, now: t0.addingTimeInterval(200))
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == nil)
    #expect(machine.phase == .suppressed)
}

@Test func externalLevelChangeCancelsBoost() {
    var machine = boosted(from: automationState(pm25: 60))
    let result = machine.evaluate(state: automationState(mode: .manual, pm25: 90, favoriteLevel: 7), settings: settings, now: t0.addingTimeInterval(200))
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == nil)
    #expect(machine.phase == .suppressed)
}

@Test func switchingOffDuringBoostCancels() {
    var machine = boosted(from: automationState(pm25: 60))
    let result = machine.evaluate(state: automationState(isOn: false, mode: .manual, pm25: 90, favoriteLevel: 14), settings: settings, now: t0.addingTimeInterval(200))
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == nil)
    #expect(machine.phase == .suppressed)
}

// MARK: - disabled and invalid threshold

@Test func disabledDuringBoostRestores() {
    var machine = boosted(from: automationState(mode: .auto, pm25: 60))
    let disabled = ThresholdSettings(isEnabled: false, pm25Limit: 35, riseDuration: 120, fallDuration: 600)
    let result = machine.evaluate(state: automationState(mode: .manual, pm25: 90, favoriteLevel: 14), settings: disabled, now: t0.addingTimeInterval(200))
    #expect(result.commands == [.mode(.auto)])
    #expect(machine.phase == .idle)
}

@Test func disabledInRisingGoesIdle() {
    var machine = ThresholdMachine()
    _ = machine.evaluate(state: automationState(pm25: 90), settings: settings, now: t0)
    let disabled = ThresholdSettings(isEnabled: false, pm25Limit: 35, riseDuration: 120, fallDuration: 600)
    let result = machine.evaluate(state: automationState(pm25: 90), settings: disabled, now: t0.addingTimeInterval(10))
    #expect(result.commands.isEmpty)
    #expect(machine.phase == .idle)
}

@Test func invalidSettingsBehaveAsDisabled() {
    var negative = ThresholdMachine()
    let badLimit = ThresholdSettings(isEnabled: true, pm25Limit: -1, riseDuration: 120, fallDuration: 600)
    #expect(negative.evaluate(state: automationState(pm25: 90), settings: badLimit, now: t0).recheckAt == nil)
    #expect(negative.phase == .idle)

    var zeroRise = ThresholdMachine()
    let badRise = ThresholdSettings(isEnabled: true, pm25Limit: 35, riseDuration: 0, fallDuration: 600)
    #expect(zeroRise.evaluate(state: automationState(pm25: 90), settings: badRise, now: t0).recheckAt == nil)
    #expect(zeroRise.phase == .idle)

    var zeroFall = ThresholdMachine()
    let badFall = ThresholdSettings(isEnabled: true, pm25Limit: 35, riseDuration: 120, fallDuration: 0)
    #expect(zeroFall.evaluate(state: automationState(pm25: 90), settings: badFall, now: t0).recheckAt == nil)
    #expect(zeroFall.phase == .idle)
}

// MARK: - external cancel

@Test(arguments: [10, 35, 60, nil] as [Int?])
func cancelBoostUsesLastKnownPM25(pm25: Int?) {
    var machine = boosted(from: automationState(mode: .auto, pm25: 60))
    machine.cancelBoost(state: pm25.map { automationState(pm25: $0) }, settings: settings)
    #expect(machine.phase == (pm25.map { $0 > settings.pm25Limit } == true ? .suppressed : .idle))

    // After cancel, if the air is clean, the machine stays idle.
    let result = machine.evaluate(state: automationState(pm25: 10), settings: settings, now: t0.addingTimeInterval(300))
    #expect(result.commands.isEmpty)
    #expect(machine.phase == .idle)
}

@Test(arguments: [true, false])
func suppressedDirtyAirNeverStartsRise(isOn: Bool) {
    var machine = boosted(from: automationState(pm25: 60))
    machine.cancelBoost(state: automationState(pm25: 60), settings: settings)
    for offset: TimeInterval in [200, 320, 900, 86_400] {
        let result = machine.evaluate(state: automationState(isOn: isOn, pm25: 60),
                                      settings: settings, now: t0.addingTimeInterval(offset))
        #expect(result.commands.isEmpty)
        #expect(result.recheckAt == nil)
        #expect(machine.phase == .suppressed)
    }
}

@Test func suppressedClearsAtLimitThenAllowsFullRise() {
    var machine = boosted(from: automationState(pm25: 60))
    machine.cancelBoost(state: automationState(pm25: 60), settings: settings)
    let clean = machine.evaluate(state: automationState(pm25: 35), settings: settings,
                                 now: t0.addingTimeInterval(300))
    #expect(clean.commands.isEmpty)
    #expect(clean.recheckAt == nil)
    #expect(machine.phase == .idle)

    let riseAt = t0.addingTimeInterval(301)
    let rising = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: riseAt)
    #expect(rising.commands.isEmpty)
    #expect(rising.recheckAt == riseAt.addingTimeInterval(120))
    #expect(machine.phase == .rising(since: riseAt))
    let early = machine.evaluate(state: automationState(pm25: 60), settings: settings,
                                 now: riseAt.addingTimeInterval(119))
    #expect(early.commands.isEmpty)
    let boost = machine.evaluate(state: automationState(pm25: 60), settings: settings,
                                 now: riseAt.addingTimeInterval(120))
    #expect(boost.commands == [.manualLevel(14)])
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 14, calmSince: nil))
}

@Test(arguments: ["disabled", "limit", "rise", "fall"])
func suppressedDisabledOrInvalidThresholdGoesIdle(reason: String) {
    var machine = boosted(from: automationState(pm25: 60))
    machine.cancelBoost(state: automationState(pm25: 60), settings: settings)
    var disabled = settings
    switch reason {
    case "disabled": disabled.isEnabled = false
    case "limit": disabled.pm25Limit = -1
    case "rise": disabled.riseDuration = 0
    default: disabled.fallDuration = 0
    }
    let result = machine.evaluate(state: automationState(pm25: 60), settings: disabled,
                                  now: t0.addingTimeInterval(300))
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == nil)
    #expect(machine.phase == .idle)
}

@Test func suppressedUnknownModeWaitsEvenWhenClean() {
    var machine = boosted(from: automationState(pm25: 60))
    machine.cancelBoost(state: automationState(pm25: 60), settings: settings)
    var unknown = automationState(pm25: 35)
    unknown.mode = nil
    let result = machine.evaluate(state: unknown, settings: settings, now: t0.addingTimeInterval(300))
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == nil)
    #expect(machine.phase == .suppressed)
}

// MARK: - PM2.5 jumping up and down within the intervals

@Test func dirtyDipBelowLimitDuringRiseResets() {
    var machine = ThresholdMachine()
    _ = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0)
    // Falling below the limit before the rise completes cancels the rise.
    _ = machine.evaluate(state: automationState(pm25: 20), settings: settings, now: t0.addingTimeInterval(60))
    #expect(machine.phase == .idle)

    // New pollution - the countdown starts over from the new moment.
    let again = machine.evaluate(state: automationState(pm25: 60), settings: settings, now: t0.addingTimeInterval(100))
    #expect(again.commands.isEmpty)
    #expect(machine.phase == .rising(since: t0.addingTimeInterval(100)))
    #expect(again.recheckAt == t0.addingTimeInterval(220))
}

// MARK: - boost level

private let settings9 = ThresholdSettings(
    isEnabled: true,
    pm25Limit: 35,
    riseDuration: 120,
    fallDuration: 600,
    boostLevel: 9
)

@Test func boostUsesConfiguredLevel() {
    var machine = ThresholdMachine()
    _ = machine.evaluate(state: automationState(mode: .auto, pm25: 60), settings: settings9, now: t0)
    let fired = machine.evaluate(state: automationState(mode: .auto, pm25: 60), settings: settings9, now: t0.addingTimeInterval(120))
    #expect(fired.commands == [.manualLevel(9)])
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 9, calmSince: nil))

    // Confirmed Manual 9 is our boost, not interference.
    let confirmed = machine.evaluate(
        state: automationState(mode: .manual, pm25: 90, favoriteLevel: 9),
        settings: settings9,
        now: t0.addingTimeInterval(130)
    )
    #expect(confirmed.commands.isEmpty)
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 9, calmSince: nil))
}

@Test func manualAtOrAboveBoostLevelDoesNotBoost() {
    // Boost does not lower speed: a level not below the boost stays as is.
    for level in [9, 12, 14] {
        var machine = ThresholdMachine()
        _ = machine.evaluate(state: automationState(mode: .manual, pm25: 60, favoriteLevel: level), settings: settings9, now: t0)
        let fired = machine.evaluate(
            state: automationState(mode: .manual, pm25: 60, favoriteLevel: level),
            settings: settings9,
            now: t0.addingTimeInterval(120)
        )
        #expect(fired.commands.isEmpty)
        #expect(fired.recheckAt == nil)
        #expect(machine.phase == .idle)
    }

    // Level below boost - boost raises speed, so it starts.
    var lower = ThresholdMachine()
    _ = lower.evaluate(state: automationState(mode: .manual, pm25: 60, favoriteLevel: 8), settings: settings9, now: t0)
    let fired = lower.evaluate(state: automationState(mode: .manual, pm25: 60, favoriteLevel: 8), settings: settings9, now: t0.addingTimeInterval(120))
    #expect(fired.commands == [.manualLevel(9)])
}

@Test func changingBoostLevelDuringBoostKeepsBoostAndAppliesNextTime() {
    // Boost started at level 9 - the level is remembered in the phase.
    var machine = boosted(from: automationState(mode: .auto, pm25: 60), settings: settings9)
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 9, calmSince: nil))

    // Changing settings during a boost does not cancel it: the confirmed Manual 9
    // matches the remembered boost level, not the new settings.
    let withNewSettings = machine.evaluate(
        state: automationState(mode: .manual, pm25: 90, favoriteLevel: 9),
        settings: settings,   // boostLevel 14
        now: t0.addingTimeInterval(200)
    )
    #expect(withNewSettings.commands.isEmpty)
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: 9, calmSince: nil))

    // Calm and mode restore; a new boost takes the new level 14.
    _ = machine.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 9), settings: settings, now: t0.addingTimeInterval(300))
    let restored = machine.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 9), settings: settings, now: t0.addingTimeInterval(900))
    #expect(restored.commands == [.mode(.auto)])
    #expect(machine.phase == .idle)

    _ = machine.evaluate(state: automationState(mode: .auto, pm25: 60), settings: settings, now: t0.addingTimeInterval(910))
    let next = machine.evaluate(state: automationState(mode: .auto, pm25: 60), settings: settings, now: t0.addingTimeInterval(1030))
    #expect(next.commands == [.manualLevel(14)])
}

// MARK: - settings compatibility

@Test func legacyJSONWithoutBoostLevelDefaultsTo14() throws {
    let json = #"{"isEnabled":true,"pm25Limit":42,"riseDuration":90,"fallDuration":300}"#
    let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: Data(json.utf8))
    #expect(decoded.boostLevel == 14)
    #expect(decoded == ThresholdSettings(isEnabled: true, pm25Limit: 42, riseDuration: 90, fallDuration: 300))
}

@Test func boostLevelOutOfRangeIsClamped() throws {
    let high = #"{"isEnabled":true,"pm25Limit":35,"riseDuration":120,"fallDuration":600,"boostLevel":99}"#
    #expect(try JSONDecoder().decode(ThresholdSettings.self, from: Data(high.utf8)).boostLevel == 14)

    let low = #"{"isEnabled":true,"pm25Limit":35,"riseDuration":120,"fallDuration":600,"boostLevel":-3}"#
    #expect(try JSONDecoder().decode(ThresholdSettings.self, from: Data(low.utf8)).boostLevel == 0)
}

@Test func boostLevelRoundTrips() throws {
    let custom = ThresholdSettings(pm25Limit: 50, boostLevel: 9)
    let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: JSONEncoder().encode(custom))
    #expect(decoded == custom)
    #expect(decoded.boostLevel == 9)
}

@Test(arguments: [PurifierLayout.mb5, .proH])
func boostUsesDeviceRangeWithoutChangingSettings(layout: PurifierLayout) {
    var machine = ThresholdMachine()
    let state = automationState(pm25: 80)
    _ = machine.evaluate(state: state, settings: settings, now: t0,
                         favoriteLevelRange: layout.favoriteLevelRange)
    let result = machine.evaluate(state: state, settings: settings, now: t0.addingTimeInterval(120),
                                  favoriteLevelRange: layout.favoriteLevelRange)
    let maximum = layout.favoriteLevelRange.upperBound
    #expect(result.commands == [.manualLevel(maximum)])
    #expect(settings.boostLevel == 14)
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: maximum, calmSince: nil))
    let confirmed = automationState(mode: .manual, pm25: 80, favoriteLevel: maximum)
    _ = machine.evaluate(state: confirmed, settings: settings, now: t0.addingTimeInterval(121),
                         favoriteLevelRange: layout.favoriteLevelRange)
    #expect(machine.phase == .boosting(restore: .mode(.auto), level: maximum, calmSince: nil))
}

@Test func deviceMaximumManualLevelDoesNotTriggerRedundantBoost() {
    var machine = ThresholdMachine()
    let state = automationState(mode: .manual, pm25: 80, favoriteLevel: 11)
    _ = machine.evaluate(state: state, settings: settings, now: t0, favoriteLevelRange: 0...11)
    let result = machine.evaluate(state: state, settings: settings, now: t0.addingTimeInterval(120),
                                  favoriteLevelRange: 0...11)
    #expect(result.commands.isEmpty)
    #expect(machine.phase == .idle)
}

@Test func unknownModeWaitsWithoutInventingRestoreOrCancellingBoost() {
    var unknown = automationState(pm25: 80)
    unknown.mode = nil
    var idle = ThresholdMachine()
    #expect(idle.evaluate(state: unknown, settings: settings, now: t0).commands.isEmpty)
    #expect(idle.phase == .idle)

    var rising = ThresholdMachine()
    _ = rising.evaluate(state: automationState(pm25: 80), settings: settings, now: t0)
    let risingPhase = rising.phase
    let result = rising.evaluate(state: unknown, settings: settings, now: t0.addingTimeInterval(120))
    #expect(result.commands.isEmpty)
    #expect(result.recheckAt == nil)
    #expect(rising.phase == risingPhase)

    var active = boosted(from: automationState(pm25: 80))
    let boostPhase = active.phase
    let paused = active.evaluate(state: unknown, settings: settings, now: t0.addingTimeInterval(130))
    #expect(paused.commands.isEmpty)
    #expect(paused.recheckAt == nil)
    #expect(active.phase == boostPhase)
    let resumed = active.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 14),
                                  settings: settings, now: t0.addingTimeInterval(140))
    #expect(resumed.recheckAt == t0.addingTimeInterval(740))
    let restored = active.evaluate(state: automationState(mode: .manual, pm25: 10, favoriteLevel: 14),
                                   settings: settings, now: t0.addingTimeInterval(740))
    #expect(restored.commands == [.mode(.auto)])

    var switchedOff = boosted(from: automationState(pm25: 80))
    unknown.isOn = false
    _ = switchedOff.evaluate(state: unknown, settings: settings, now: t0.addingTimeInterval(130))
    #expect(switchedOff.phase == .suppressed)
}

@Test(arguments: ["1e300", "10801", "21601", "0", "-60", "120"])
func decodedThresholdDurationsRespectUpperBounds(value: String) throws {
    let json = """
    {"isEnabled":true,"pm25Limit":35,"riseDuration":\(value),"fallDuration":\(value)}
    """
    let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: Data(json.utf8))
    let duration = try #require(Double(value))
    #expect(decoded.riseDuration == min(duration, 180 * 60))
    #expect(decoded.fallDuration == min(duration, 360 * 60))
    #expect(decoded.isActive == (duration > 0))
}

@Test(arguments: ["NaN", "Infinity", "-Infinity"])
func decodedNonfiniteThresholdDurationsUseMaximum(value: String) throws {
    let json = """
    {"isEnabled":true,"pm25Limit":35,"riseDuration":"\(value)","fallDuration":"\(value)"}
    """
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
    )
    let decoded = try decoder.decode(ThresholdSettings.self, from: Data(json.utf8))
    #expect(decoded.riseDuration == 180 * 60)
    #expect(decoded.fallDuration == 360 * 60)
}

@Test(arguments: [ThresholdSettings.riseMinutesRange, ThresholdSettings.fallMinutesRange])
func thresholdMinuteConversionClampsBeforeIntegerConversion(range: ClosedRange<Int>) {
    for duration: TimeInterval in [1e300, .greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
        #expect(ThresholdSettings.clampedMinutes(for: duration, in: range) == range.upperBound)
    }
    for duration: TimeInterval in [0, -60, -.greatestFiniteMagnitude, 1, 59] {
        #expect(ThresholdSettings.clampedMinutes(for: duration, in: range) == range.lowerBound)
    }
    #expect(ThresholdSettings.clampedMinutes(for: 89, in: range) == 1)
    #expect(ThresholdSettings.clampedMinutes(for: 90, in: range) == 2)
    #expect(ThresholdSettings.clampedMinutes(for: 120, in: range) == 2)
    #expect(ThresholdSettings.clampedMinutes(for: Double(range.upperBound) * 60, in: range) == range.upperBound)
}
