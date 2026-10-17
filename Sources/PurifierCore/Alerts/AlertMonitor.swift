// Decides when to notify: the filter is running out, a malfunction, long unavailability.
// A pure type without timers and network: time is supplied from outside, so it is tested on synthetic time.
import Foundation

/// Notification state machine. Each `observe` call is a new point in time.
public struct AlertMonitor: Sendable {
    /// Notify when the filter life is less than this value.
    public static let filterLowThreshold = 10
    /// Life is again not less than this value -> the filter was replaced, the flag is reset.
    public static let filterResetThreshold = 50

    public var settings: AlertSettings
    public private(set) var memory: AlertMemory

    /// Start of the current unavailability episode; `nil` - no episode.
    private var unreachableSince: Date?
    /// In this episode we have already notified - we do not bother again.
    private var unreachableNotified = false
    /// The last seen malfunction in the fresh state (not stored between launches).
    private var lastFault: PurifierFault = .none

    public init(settings: AlertSettings, memory: AlertMemory = AlertMemory()) {
        self.settings = settings
        self.memory = memory
    }

    /// Evaluates one snapshot: the fresh state (if any) and availability.
    /// Returns notifications in the order: unavailability, malfunction, filter.
    public mutating func observe(
        state: PurifierState?,
        connection: Connection,
        now: Date
    ) -> [PurifierAlert] {
        var alerts: [PurifierAlert] = []

        updateEpisode(connection: connection, now: now)
        if let since = unreachableSince, !unreachableNotified, settings.unreachable,
           now.timeIntervalSince(since) >= TimeInterval(settings.clampedMinutes * 60) {
            unreachableNotified = true
            alerts.append(.unreachable(since: since))
        }

        // Filter and malfunction - only from the fresh state.
        if connection == .online, let state {
            if state.fault != .none, state.fault != lastFault, settings.fault {
                alerts.append(.fault(state.fault))
            }
            lastFault = state.fault

            if settings.filterLow {
                if state.filterPercent < Self.filterLowThreshold {
                    if !memory.filterLowNotified {
                        memory.filterLowNotified = true
                        alerts.append(.filterLow(percent: state.filterPercent))
                    }
                } else if state.filterPercent >= Self.filterResetThreshold {
                    memory.filterLowNotified = false
                }
            }
        }

        return alerts
    }

    /// When the unavailability notification fires if nothing changes; `nil` - not expected
    /// (no episode, already notified, or the toggle is off).
    public func nextDeadline() -> Date? {
        guard settings.unreachable else { return nil }
        guard let since = unreachableSince, !unreachableNotified else { return nil }
        return since.addingTimeInterval(TimeInterval(settings.clampedMinutes * 60))
    }

    /// An episode starts with the first `.unreachable` and ends with the first `.online`.
    /// `.connecting` neither starts nor ends an episode.
    private mutating func updateEpisode(connection: Connection, now: Date) {
        switch connection {
        case .online:
            unreachableSince = nil
            unreachableNotified = false
        case .unreachable:
            if unreachableSince == nil {
                unreachableSince = now
                unreachableNotified = false
            }
        case .connecting:
            break
        }
    }
}
