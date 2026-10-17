// Independent probes of the public API per BRIEFS/T5_CONTRACT.md. Synthetic time only.
import Foundation
import Testing
import PurifierCore

private func t5ProbeDate(_ offset: TimeInterval = 0) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(offset)
}

private func t5ProbeState(percent: Int = 80, fault: PurifierFault = .none) -> PurifierState {
    PurifierState(
        isOn: true, fault: fault, mode: .auto, pm25: 12,
        filterPercent: percent, filterHoursUsed: 100, filterDaysLeft: 30,
        sound: false, childLock: false, screen: .bright, motorRPM: 416,
        favoriteLevel: 7
    )
}

private func t5ProbeSettings(
    filter: Bool = false, fault: Bool = false, unreachable: Bool = false, minutes: Int = 1
) -> AlertSettings {
    AlertSettings(filterLow: filter, fault: fault, unreachable: unreachable, unreachableMinutes: minutes)
}

@Suite("T5: independent probes of notifications and settings")
struct T5ProbeTests {
    @Test("Default values, thresholds and an empty monitor")
    func contractDefaults() {
        #expect(AlertSettings.standard == AlertSettings(
            filterLow: true, fault: true, unreachable: true, unreachableMinutes: 10
        ))
        #expect(AlertMonitor.filterLowThreshold == 10)
        #expect(AlertMonitor.filterResetThreshold == 50)
        #expect(AlertMemory() == AlertMemory(filterLowNotified: false))
        #expect(AutomationSettings.standard.alerts == .standard)
        #expect(AutomationSettings().alerts == .standard)
        let monitor = AlertMonitor(settings: .standard)
        #expect(monitor.settings == .standard)
        #expect(monitor.memory == AlertMemory())
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("Filter notifies strictly below 10 %", arguments: [0, 9, 10, 49, 50])
    func filterThreshold(percent: Int) {
        var monitor = AlertMonitor(settings: t5ProbeSettings(filter: true))
        let result = monitor.observe(state: t5ProbeState(percent: percent), connection: .online, now: t5ProbeDate())
        let expected: [PurifierAlert] = percent < 10 ? [.filterLow(percent: percent)] : []
        #expect(result == expected)
        #expect(monitor.memory.filterLowNotified == (percent < 10))
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("Repeats and all values 10-49 % do not reset the filter flag")
    func filterDoesNotRepeatBelowReset() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(filter: true))
        #expect(monitor.observe(state: t5ProbeState(percent: 9), connection: .online,
                                now: t5ProbeDate()) == [.filterLow(percent: 9)])
        for (index, percent) in ([9, 8, 0] + Array(10...49) + [9, 1]).enumerated() {
            #expect(monitor.observe(state: t5ProbeState(percent: percent), connection: .online,
                                    now: t5ProbeDate(Double(index + 1))).isEmpty)
            #expect(monitor.memory.filterLowNotified)
        }
    }

    @Test("Replacement at 50 % and above allows the next notification", arguments: [50, 100])
    func filterReplacementResets(percent: Int) {
        var monitor = AlertMonitor(settings: t5ProbeSettings(filter: true),
                                   memory: AlertMemory(filterLowNotified: true))
        #expect(monitor.observe(state: t5ProbeState(percent: percent), connection: .online,
                                now: t5ProbeDate()).isEmpty)
        #expect(!monitor.memory.filterLowNotified)
        #expect(monitor.observe(state: t5ProbeState(percent: 4), connection: .online,
                                now: t5ProbeDate(1)) == [.filterLow(percent: 4)])
        #expect(monitor.memory.filterLowNotified)
        #expect(monitor.observe(state: t5ProbeState(percent: 3), connection: .online,
                                now: t5ProbeDate(2)).isEmpty)
    }

    @Test("Serialized filter memory survives a new monitor", arguments: [false, true])
    func filterMemoryRoundTrip(notified: Bool) throws {
        let memory = AlertMemory(filterLowNotified: notified)
        let data = try JSONEncoder().encode(memory)
        let restored = try JSONDecoder().decode(AlertMemory.self, from: data)
        #expect(restored == memory)
        var monitor = AlertMonitor(settings: t5ProbeSettings(filter: true, fault: true), memory: restored)
        let expected: [PurifierAlert] = notified ? [.fault(.motorStuck)] : [.fault(.motorStuck), .filterLow(percent: 7)]
        #expect(monitor.observe(state: t5ProbeState(percent: 7, fault: .motorStuck), connection: .online,
                                now: t5ProbeDate()) == expected)
        #expect(monitor.memory.filterLowNotified)
    }

    @Test("Stale state does not notify and does not reset the filter memory",
          arguments: [Connection.connecting, .unreachable], [false, true])
    func staleStateCannotChangeFilter(connection: Connection, notified: Bool) {
        let memory = AlertMemory(filterLowNotified: notified)
        var monitor = AlertMonitor(settings: t5ProbeSettings(filter: true), memory: memory)
        for (index, percent) in [5, 100, 0, 50].enumerated() {
            #expect(monitor.observe(state: t5ProbeState(percent: percent), connection: connection,
                                    now: t5ProbeDate(Double(index))).isEmpty)
            #expect(monitor.memory == memory)
        }
        let expected: [PurifierAlert] = notified ? [] : [.filterLow(percent: 6)]
        #expect(monitor.observe(state: t5ProbeState(percent: 6), connection: .online,
                                now: t5ProbeDate(10)) == expected)
    }

    @Test("nil does not change the filter memory or the previous malfunction",
          arguments: [Connection.online, .connecting, .unreachable], [false, true])
    func missingStatePreservesHistory(connection: Connection, notified: Bool) {
        let memory = AlertMemory(filterLowNotified: notified)
        var monitor = AlertMonitor(settings: t5ProbeSettings(filter: true, fault: true), memory: memory)
        #expect(monitor.observe(state: t5ProbeState(percent: 49, fault: .motorStuck), connection: .online,
                                now: t5ProbeDate()) == [.fault(.motorStuck)])
        #expect(monitor.memory == memory)
        #expect(monitor.observe(state: nil, connection: connection, now: t5ProbeDate(2)).isEmpty)
        #expect(monitor.memory == memory)
        let expected: [PurifierAlert] = notified ? [] : [.filterLow(percent: 4)]
        #expect(monitor.observe(state: t5ProbeState(percent: 4, fault: .motorStuck), connection: .online,
                                now: t5ProbeDate(3)) == expected)
    }

    @Test("Disabled filter does not change memory on low life or on replacement",
          arguments: [false, true])
    func disabledFilterPreservesMemory(notified: Bool) {
        let memory = AlertMemory(filterLowNotified: notified)
        var monitor = AlertMonitor(settings: t5ProbeSettings(), memory: memory)
        for (index, percent) in [9, 100, 5, 50].enumerated() {
            #expect(monitor.observe(state: t5ProbeState(percent: percent), connection: .online,
                                    now: t5ProbeDate(Double(index))).isEmpty)
            #expect(monitor.memory == memory)
        }
        monitor.settings.filterLow = true
        let expected: [PurifierAlert] = notified ? [] : [.filterLow(percent: 2)]
        #expect(monitor.observe(state: t5ProbeState(percent: 2), connection: .online,
                                now: t5ProbeDate(10)) == expected)
        #expect(monitor.memory.filterLowNotified)
    }

    @Test("Malfunction: repeat, change, disappearance and return")
    func faultTransitions() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(fault: true))
        let samples: [(PurifierFault, [PurifierAlert])] = [
            (.none, []),
            (.motorStuck, [.fault(.motorStuck)]),
            (.motorStuck, []),
            (.sensorLost, [.fault(.sensorLost)]),
            (.sensorLost, []),
            (.none, []),
            (.sensorLost, [.fault(.sensorLost)]),
            (.other(7), [.fault(.other(7))]),
            (.other(7), []),
            (.other(8), [.fault(.other(8))]),
        ]
        for (index, sample) in samples.enumerated() {
            #expect(monitor.observe(state: t5ProbeState(fault: sample.0), connection: .online,
                                    now: t5ProbeDate(Double(index))) == sample.1)
        }
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("Stale malfunctions do not notify and do not change history",
          arguments: [Connection.connecting, .unreachable])
    func staleFaultsDoNotAdvanceHistory(connection: Connection) {
        var monitor = AlertMonitor(settings: t5ProbeSettings(fault: true))
        #expect(monitor.observe(state: t5ProbeState(fault: .motorStuck), connection: connection,
                                now: t5ProbeDate()).isEmpty)
        #expect(monitor.observe(state: t5ProbeState(fault: .motorStuck), connection: .online,
                                now: t5ProbeDate(1)) == [.fault(.motorStuck)])
        #expect(monitor.observe(state: t5ProbeState(fault: .none), connection: connection,
                                now: t5ProbeDate(2)).isEmpty)
        #expect(monitor.observe(state: t5ProbeState(fault: .motorStuck), connection: .online,
                                now: t5ProbeDate(3)).isEmpty)
        #expect(monitor.observe(state: t5ProbeState(fault: .sensorLost), connection: connection,
                                now: t5ProbeDate(4)).isEmpty)
        #expect(monitor.observe(state: t5ProbeState(fault: .sensorLost), connection: .online,
                                now: t5ProbeDate(5)) == [.fault(.sensorLost)])
    }

    @Test("Disabled malfunction toggle keeps tracking")
    func disabledFaultTracksHistory() {
        var monitor = AlertMonitor(settings: t5ProbeSettings())
        #expect(monitor.observe(state: t5ProbeState(fault: .motorStuck), connection: .online,
                                now: t5ProbeDate()).isEmpty)
        monitor.settings.fault = true
        #expect(monitor.observe(state: t5ProbeState(fault: .motorStuck), connection: .online,
                                now: t5ProbeDate(1)).isEmpty)
        #expect(monitor.observe(state: t5ProbeState(fault: .sensorLost), connection: .online,
                                now: t5ProbeDate(2)) == [.fault(.sensorLost)])
        monitor.settings.fault = false
        #expect(monitor.observe(state: t5ProbeState(fault: .none), connection: .online,
                                now: t5ProbeDate(3)).isEmpty)
        monitor.settings.fault = true
        #expect(monitor.observe(state: t5ProbeState(fault: .sensorLost), connection: .online,
                                now: t5ProbeDate(4)) == [.fault(.sensorLost)])
        monitor.settings.fault = false
        #expect(monitor.observe(state: t5ProbeState(fault: .motorStuck), connection: .online,
                                now: t5ProbeDate(5)).isEmpty)
        monitor.settings.fault = true
        #expect(monitor.observe(state: t5ProbeState(fault: .motorStuck), connection: .online,
                                now: t5ProbeDate(6)).isEmpty)
    }

    @Test("Unavailability notifies exactly at the minute boundaries", arguments: [1, 10, 240])
    func unreachableExactBoundary(minutes: Int) {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true, minutes: minutes))
        let seconds = Double(minutes * 60)
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(20)).isEmpty)
        #expect(monitor.nextDeadline() == t5ProbeDate(20 + seconds))
        for offset in [20 + seconds / 2, 20 + seconds - 0.001] {
            #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(offset)).isEmpty)
            #expect(monitor.nextDeadline() == t5ProbeDate(20 + seconds))
        }
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(20 + seconds)) == [.unreachable(since: t5ProbeDate(20))])
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(20 + seconds * 3)).isEmpty)
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("Unavailability clamps 0 and 241 minutes to 1 and 240", arguments: [0, 241])
    func unreachableMinutesClamped(minutes: Int) {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true, minutes: minutes))
        let seconds: TimeInterval = minutes == 0 ? 60 : 14_400
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate()).isEmpty)
        #expect(monitor.nextDeadline() == t5ProbeDate(seconds))
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(seconds - 0.001)).isEmpty)
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(seconds)) == [.unreachable(since: t5ProbeDate())])
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("connecting does not start an unavailability episode")
    func connectingDoesNotStartEpisode() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true))
        for offset in [0.0, 60, 600] {
            #expect(monitor.observe(state: nil, connection: .connecting, now: t5ProbeDate(offset)).isEmpty)
            #expect(monitor.nextDeadline() == nil)
        }
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(601)).isEmpty)
        #expect(monitor.nextDeadline() == t5ProbeDate(661))
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(661)) == [.unreachable(since: t5ProbeDate(601))])
    }

    @Test("connecting does not end the episode and allows a notification at the deadline")
    func connectingKeepsEpisode() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true))
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate()).isEmpty)
        #expect(monitor.observe(state: nil, connection: .connecting, now: t5ProbeDate(59)).isEmpty)
        #expect(monitor.nextDeadline() == t5ProbeDate(60))
        #expect(monitor.observe(state: nil, connection: .connecting,
                                now: t5ProbeDate(60)) == [.unreachable(since: t5ProbeDate())])
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(120)).isEmpty)
    }

    @Test("One notification per episode, a new one after online")
    func unreachableOncePerEpisode() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true))
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate()).isEmpty)
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(61)) == [.unreachable(since: t5ProbeDate())])
        for (index, connection) in [Connection.unreachable, .connecting, .unreachable].enumerated() {
            #expect(monitor.observe(state: nil, connection: connection,
                                    now: t5ProbeDate(120 + Double(index) * 60)).isEmpty)
            #expect(monitor.nextDeadline() == nil)
        }
        #expect(monitor.observe(state: t5ProbeState(), connection: .online, now: t5ProbeDate(300)).isEmpty)
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(301)).isEmpty)
        #expect(monitor.nextDeadline() == t5ProbeDate(361))
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(361)) == [.unreachable(since: t5ProbeDate(301))])
    }

    @Test("online even without state ends the episode before the deadline")
    func onlineWithoutStateEndsEpisode() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true))
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate()).isEmpty)
        #expect(monitor.observe(state: nil, connection: .online, now: t5ProbeDate(59)).isEmpty)
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .connecting, now: t5ProbeDate(100)).isEmpty)
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(101)).isEmpty)
        #expect(monitor.nextDeadline() == t5ProbeDate(161))
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(160)).isEmpty)
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(161)) == [.unreachable(since: t5ProbeDate(101))])
    }

    @Test("Disabled unavailability keeps the start and notifies after enabling")
    func disabledUnreachablePreservesEpisode() {
        var monitor = AlertMonitor(settings: t5ProbeSettings())
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(10)).isEmpty)
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .connecting, now: t5ProbeDate(100)).isEmpty)
        #expect(monitor.nextDeadline() == nil)
        monitor.settings.unreachable = true
        #expect(monitor.nextDeadline() == t5ProbeDate(70))
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(101)) == [.unreachable(since: t5ProbeDate(10))])
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("Toggling unavailability does not repeat within an already notified episode")
    func disabledUnreachableDoesNotRearmEpisode() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true))
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate()).isEmpty)
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(60)) == [.unreachable(since: t5ProbeDate())])
        monitor.settings.unreachable = false
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .connecting, now: t5ProbeDate(100)).isEmpty)
        monitor.settings.unreachable = true
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(200)).isEmpty)
    }

    @Test("The deadline immediately accounts for changes in minutes and the toggle")
    func deadlinesFollowSettings() {
        var monitor = AlertMonitor(settings: t5ProbeSettings(unreachable: true, minutes: 10))
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(30)).isEmpty)
        #expect(monitor.nextDeadline() == t5ProbeDate(630))
        monitor.settings.unreachable = false
        #expect(monitor.nextDeadline() == nil)
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(40)).isEmpty)
        monitor.settings.unreachableMinutes = 2
        monitor.settings.unreachable = true
        #expect(monitor.nextDeadline() == t5ProbeDate(150))
        monitor.settings.unreachableMinutes = 0
        #expect(monitor.nextDeadline() == t5ProbeDate(90))
        monitor.settings.unreachableMinutes = 241
        #expect(monitor.nextDeadline() == t5ProbeDate(14_430))
        monitor.settings.unreachableMinutes = 1
        #expect(monitor.observe(state: nil, connection: .unreachable,
                                now: t5ProbeDate(90)) == [.unreachable(since: t5ProbeDate(30))])
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("All toggles disabled give silence and no deadline")
    func allSwitchesDisabled() {
        var monitor = AlertMonitor(settings: t5ProbeSettings())
        #expect(monitor.observe(state: t5ProbeState(percent: 0, fault: .motorStuck), connection: .online,
                                now: t5ProbeDate()).isEmpty)
        #expect(monitor.observe(state: t5ProbeState(percent: 0, fault: .sensorLost), connection: .unreachable,
                                now: t5ProbeDate(1)).isEmpty)
        #expect(monitor.observe(state: nil, connection: .unreachable, now: t5ProbeDate(86_400)).isEmpty)
        #expect(monitor.memory == AlertMemory())
        #expect(monitor.nextDeadline() == nil)
    }

    @Test("Simultaneous fresh notifications are ordered: malfunction, filter")
    func resultOrder() {
        var monitor = AlertMonitor(settings: .standard)
        #expect(monitor.observe(state: t5ProbeState(percent: 8, fault: .sensorLost), connection: .online,
                                now: t5ProbeDate()) == [.fault(.sensorLost), .filterLow(percent: 8)])
        #expect(monitor.observe(state: t5ProbeState(percent: 7, fault: .sensorLost), connection: .online,
                                now: t5ProbeDate(1)).isEmpty)
    }

    @Test("Old JSON without alerts keeps its own schedule and threshold")
    func legacyJSONWithoutAlerts() throws {
        let data = Data(#"""
        {
          "schedule": [
            {
              "id": "00000000-0000-0000-0000-000000000005",
              "isEnabled": false,
              "hour": 23,
              "minute": 17,
              "weekdays": 10,
              "action": {"power": true, "mode": 2, "manualLevel": 11}
            }
          ],
          "threshold": {"isEnabled": false, "pm25Limit": 57, "riseDuration": 91, "fallDuration": 303}
        }
        """#.utf8)
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: data)
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005"))
        #expect(settings.schedule == [ScheduleRule(
            id: id, isEnabled: false, hour: 23, minute: 17, weekdays: [.monday, .wednesday],
            action: ScheduleAction(power: true, mode: .manual, manualLevel: 11)
        )])
        #expect(settings.threshold == ThresholdSettings(
            isEnabled: false, pm25Limit: 57, riseDuration: 91, fallDuration: 303
        ))
        #expect(settings.alerts == .standard)
    }

    @Test("Round-trip serialization of AutomationSettings with its own alerts", arguments: [
        AlertSettings(filterLow: false, fault: true, unreachable: false, unreachableMinutes: 37),
        AlertSettings(filterLow: true, fault: false, unreachable: true, unreachableMinutes: 240),
    ])
    func settingsRoundTripWithAlerts(alerts: AlertSettings) throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000006"))
        let settings = AutomationSettings(
            schedule: [ScheduleRule(
                id: id, isEnabled: true, hour: 6, minute: 42, weekdays: [.friday, .sunday],
                action: ScheduleAction(power: false)
            )],
            threshold: ThresholdSettings(isEnabled: true, pm25Limit: 61, riseDuration: 123, fallDuration: 456),
            alerts: alerts
        )
        #expect(settings.alerts == alerts)
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedAlerts = try #require(object["alerts"] as? [String: Any])
        #expect(encodedAlerts["filterLow"] as? Bool == alerts.filterLow)
        #expect(encodedAlerts["fault"] as? Bool == alerts.fault)
        #expect(encodedAlerts["unreachable"] as? Bool == alerts.unreachable)
        #expect(encodedAlerts["unreachableMinutes"] as? Int == alerts.unreachableMinutes)
        let restored = try JSONDecoder().decode(AutomationSettings.self, from: data)
        #expect(restored == settings)
        #expect(restored.schedule == settings.schedule)
        #expect(restored.threshold == settings.threshold)
        #expect(restored.alerts == alerts)
    }
}
