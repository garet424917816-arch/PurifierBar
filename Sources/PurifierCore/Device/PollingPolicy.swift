// Polling and confirmation policy and the connectivity state.
import Foundation

/// Controller intervals and limits. Defaults - `.standard`.
public struct PollingPolicy: Sendable, Equatable {
    public var panelOpen: Duration       // interval when the panel is open
    public var panelClosed: Duration     // interval when the panel is closed
    public var confirmAttempts: Int      // read-back attempts after a write
    public var confirmInterval: Duration // pause between read-back attempts
    public var failuresBeforeUnreachable: Int // consecutive failures until `.unreachable`

    public static let standard = PollingPolicy(
        panelOpen: .seconds(5),
        panelClosed: .seconds(30),
        confirmAttempts: 8,
        confirmInterval: .milliseconds(250),
        failuresBeforeUnreachable: 2
    )

    public init(
        panelOpen: Duration,
        panelClosed: Duration,
        confirmAttempts: Int,
        confirmInterval: Duration,
        failuresBeforeUnreachable: Int
    ) {
        self.panelOpen = panelOpen
        self.panelClosed = panelClosed
        self.confirmAttempts = confirmAttempts
        self.confirmInterval = confirmInterval
        self.failuresBeforeUnreachable = failuresBeforeUnreachable
    }
}

/// Connectivity state with the device.
public enum Connection: Sendable, Equatable {
    case connecting
    case online
    case unreachable
}
