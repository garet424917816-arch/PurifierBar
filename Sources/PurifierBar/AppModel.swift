// App state: builds the chain transport -> device -> controller -> engine,
// keeps it alive and retries the start after a failure no more often than once per 30 s.
import AppKit
import Foundation
import Observation
import PurifierCore

@MainActor
@Observable
final class AppModel {
    /// Start state: in progress, ready, or a text reason for the failure for the panel.
    enum Status: Equatable {
        case starting
        case ready
        case missingToken
        case unverifiedModel(String)
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var controller: PurifierController?
    private(set) var engine: AutomationEngine?
    private(set) var settings: AutomationSettings
    private(set) var layout: PurifierLayout = .cpa4
    private(set) var host: String
    private(set) var lastSaveError: String?

    /// Panel visibility: both the controller's polling and the glow animation.
    var panelVisible = false {
        didSet { controller?.isPanelOpen = panelVisible }
    }

    /// Before this moment the automatic start retry is not done.
    private(set) var retryAllowedAt = Date.distantPast

    private let store: SettingsStore
    /// Starts and keeps alive the settings window process; in this process
    /// `SettingsView` is never created.
    private let settingsLauncher = SettingsLauncher()
    private var connectTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var settingsObservers: [NSObjectProtocol] = []

    private var alertMonitor: AlertMonitor
    private var lastPersistedMemory: AlertMemory
    private let notifier: Notifier?
    private var deadlineTask: Task<Void, Never>?
    /// Observation generation: grows on each re-arm and chain stop,
    /// so that stale callbacks do not fire.
    private var alertObservationGeneration = 0
    /// Whether there is a live Observation subscription. Holds exactly one - no duplication.
    private var alertObservationArmed = false

    private static let alertMemoryKey = "alertMemory"
    private static let acceptedUnverifiedModelKey = "acceptedUnverifiedModel"
    private static let retryDelay: TimeInterval = 30

    init() {
        let store = SettingsStore(url: SettingsStore.defaultURL)
        self.store = store
        let loaded = store.load()
        self.settings = loaded
        self.host = UserDefaults.standard.string(forKey: SettingsSync.hostKey) ?? SettingsSync.defaultHost
        let memory = Self.loadAlertMemory()
        self.lastPersistedMemory = memory
        self.alertMonitor = AlertMonitor(settings: loaded.alerts, memory: memory)
        // Outside the bundle UNUserNotificationCenter is unavailable - there will be no notifications.
        self.notifier = Bundle.main.bundleIdentifier == nil ? nil : Notifier()
    }

    // MARK: - Lifecycle

    /// One-time start: subscriptions to system events and the connection loop.
    func start() {
        guard connectTask == nil else { return }
        registerSystemObservers()
        registerSettingsObservers()
        notifier?.requestAuthorizationIfNeeded(alerts: settings.alerts)
        alertTick()
        beginConnectLoop()
    }

    /// Panel visible -> the controller polls more often, the glow is alive.
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
    }

    /// Open (or raise) the settings window in a separate process.
    func openSettings() {
        settingsLauncher.open()
    }

    /// Manual retry after a failure. Not more often than once per 30 s, same as the automatic retry.
    func retryNow() {
        if case .unverifiedModel = status { return }
        guard Date() >= retryAllowedAt else { return }
        beginConnectLoop()
    }

    /// Consent applies only to the displayed model; reconnect through the normal authenticated path.
    func acceptUnverifiedModel() {
        guard case .unverifiedModel(let model) = status else { return }
        UserDefaults.standard.set(model, forKey: Self.acceptedUnverifiedModelKey)
        restartChain()
    }

    /// Changing the device IP: restarts the chain.
    func changeHost(_ newHost: String) {
        let trimmed = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != host else { return }
        host = trimmed
        UserDefaults.standard.set(trimmed, forKey: SettingsSync.hostKey)
        restartChain()
    }

    /// Reread settings changed in the settings process: file -> model,
    /// engine and alert monitor; the IP change is handled by the same chain restart.
    /// This is a consequence, not a source of the event, so `automationChanged` is not sent from here.
    func reloadFromDisk() {
        let loaded = store.load()
        settings = loaded
        engine?.settings = loaded
        alertMonitor.settings = loaded.alerts
        notifier?.requestAuthorizationIfNeeded(alerts: loaded.alerts)
        alertTick()

        // The value was written by another process - we reread from cfprefsd, not from the cache.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let latestHost = UserDefaults.standard.string(forKey: SettingsSync.hostKey) ?? SettingsSync.defaultHost
        if latestHost != host {
            host = latestHost
            restartChain()
        }
    }

    /// Saving automation settings: to the file, the engine and the alert monitor.
    func applySettings(_ newSettings: AutomationSettings) {
        settings = newSettings
        engine?.settings = newSettings
        alertMonitor.settings = newSettings.alerts
        do {
            try store.save(newSettings)
            lastSaveError = nil
        } catch {
            lastSaveError = String(localized: "Could not save settings")
        }
        alertTick()
        // Schedule edits from the panel - the settings process must learn about them
        // if the window is open. There is no return signal - no loop.
        SettingsSync.post(.automationChanged)
    }

    /// Restart of the chain from scratch: the shared part of `changeHost` and the IP reread.
    private func restartChain() {
        stopChain()
        status = .starting
        retryAllowedAt = .distantPast
        beginConnectLoop()
    }

    // MARK: - Connection

    private func beginConnectLoop() {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let finished = await self.connectOnce()
                if finished || Task.isCancelled { return }
                // Error: the next attempt not earlier than in 30 s.
                self.retryAllowedAt = Date().addingTimeInterval(Self.retryDelay)
                try? await Task.sleep(for: .seconds(Self.retryDelay))
            }
        }
    }

    private func connectOnce() async -> Bool {
        stopChain()
        status = .starting
        do {
            // Keychain may wait for a permission dialog - we do not block the main thread.
            let token = try await Task.detached { try TokenStore.load() }.value
            try Task.checkCancellation()
            let transport = try UDPTransport(host: host, token: token)
            let deviceID = try await transport.resolveDeviceID()
            try Task.checkCancellation()
            let client = MIoTClient(transport: transport, deviceID: String(deviceID))
            // miIO.info is token-authenticated. Select the map before reading properties.
            let model = try? await client.model()
            try Task.checkCancellation()
            if model != nil { commitResolvedHost(transport.currentHost) }
            let decision = SupportedModels.decision(
                for: model,
                acceptedUnverifiedModel: UserDefaults.standard.string(forKey: Self.acceptedUnverifiedModelKey)
            )
            guard let layout = SupportedModels.layout(for: model, decision: decision) else {
                if let model { status = .unverifiedModel(model) }
                alertTick()
                // Wait for consent or a settings change without automatic retries.
                return true
            }
            let device = MIoTPurifier(client: client, layout: layout)
            _ = try await device.readState()
            try Task.checkCancellation()
            // Without model information the property read authenticates the address (T13).
            commitResolvedHost(transport.currentHost)
            self.layout = layout
            UserDefaults.standard.set(layout.favoriteLevelRange.upperBound, forKey: SettingsSync.favoriteLevelMaximumKey)

            let controller = PurifierController(device: device, policy: .standard)
            let engine = AutomationEngine(
                controller: controller, settings: settings, favoriteLevelRange: layout.favoriteLevelRange
            )
            controller.isPanelOpen = panelVisible
            controller.start()
            engine.start()

            self.controller = controller
            self.engine = engine
            retryAllowedAt = .distantPast
            status = .ready
            alertTick()
            return true
        } catch {
            // A settings change may have started another connection while this one was suspended.
            guard !Task.isCancelled else { return true }
            if let miio = error as? MiIOError, miio == .invalidToken {
                status = .missingToken
            } else {
                status = .failed(Self.message(for: error))
            }
            alertTick()
            return false
        }
    }

    private func commitResolvedHost(_ resolved: String) {
        if resolved != host {
            host = resolved
            UserDefaults.standard.set(resolved, forKey: SettingsSync.hostKey)
        }
    }

    private func stopChain() {
        // The chain disappears - stale observations and the deadline must not be allowed to fire.
        alertObservationGeneration += 1
        alertObservationArmed = false
        deadlineTask?.cancel()
        deadlineTask = nil
        engine?.stop()
        controller?.stop()
        engine = nil
        controller = nil
    }

    // MARK: - Notifications

    /// One wake-up point: evaluate, show, re-arm the observation and the deadline.
    private func alertTick() {
        syncAlerts()
        armAlertObservation()
        armAlertDeadline()
    }

    /// Feeds the monitor the fresh state and availability, keeps the memory, shows notifications.
    private func syncAlerts() {
        guard let inputs = alertInputs() else { return }
        let fired = alertMonitor.observe(
            state: inputs.state,
            connection: inputs.connection,
            now: Date()
        )
        if alertMonitor.memory != lastPersistedMemory {
            lastPersistedMemory = alertMonitor.memory
            Self.saveAlertMemory(alertMonitor.memory)
        }
        for alert in fired {
            notifier?.post(alert)
        }
    }

    /// What to feed the monitor. `nil` - feed nothing (no token).
    private func alertInputs() -> (state: PurifierState?, connection: Connection)? {
        if let controller {
            return (controller.state, controller.connection)
        }
        switch status {
        case .starting:
            return (nil, .connecting)
        case .failed:
            return (nil, .unreachable)
        case .missingToken, .unverifiedModel:
            return nil
        case .ready:
            return nil
        }
    }

    /// Watches the status and (when present) the controller state and availability - no timers.
    private func armAlertObservation() {
        guard !alertObservationArmed else { return }
        alertObservationArmed = true
        alertObservationGeneration += 1
        let generation = alertObservationGeneration
        let controller = self.controller
        withObservationTracking {
            _ = self.status
            if let controller {
                _ = controller.state
                _ = controller.connection
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                // Stale subscription (the chain was restarted) - has no effect.
                guard let self, self.alertObservationGeneration == generation else { return }
                self.alertObservationArmed = false
                self.alertTick()
            }
        }
    }

    /// One task sleeps until the nearest notification deadline and then wakes `alertTick`.
    private func armAlertDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = alertMonitor.nextDeadline() else { return }
        let interval = max(0, deadline.timeIntervalSince(Date()))
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(min(1, interval)))
            guard !Task.isCancelled else { return }
            self?.alertTick()
        }
    }

    private static func loadAlertMemory() -> AlertMemory {
        guard let data = UserDefaults.standard.data(forKey: alertMemoryKey),
              let memory = try? JSONDecoder().decode(AlertMemory.self, from: data)
        else {
            return AlertMemory()
        }
        return memory
    }

    private static func saveAlertMemory(_ memory: AlertMemory) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: alertMemoryKey)
    }

    // MARK: - System events

    private func registerSystemObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.systemClockChanged() }
            })
        }
    }

    /// Events from the settings process: saving settings and quitting.
    private func registerSettingsObservers() {
        guard settingsObservers.isEmpty else { return }
        settingsObservers.append(SettingsSync.observe(.settingsChanged) { [weak self] in
            self?.reloadFromDisk()
        })
        settingsObservers.append(SettingsSync.observe(.tokenChanged) { [weak self] in
            self?.restartChain()
        })
        settingsObservers.append(SettingsSync.observe(.quit) {
            NSApp.terminate(nil)
        })
    }

    /// Mac wake-up: a fresh read and recalculation of the schedule.
    private func systemDidWake() {
        guard let controller else { return }
        Task { await controller.refreshNow() }
        engine?.reschedule()
    }

    private func systemClockChanged() {
        engine?.reschedule()
    }

    private static func message(for error: Error) -> String {
        guard error is MiIOError else {
            return String(localized: "Could not connect to the device")
        }
        return String(localized: "Device not responding")
    }
}
