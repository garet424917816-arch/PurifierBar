// Panel: a large PM2.5 figure on the background of the live glow, device controls,
// connection state and errors. All commands go through `AutomationEngine.userSend`,
// so a manual action cancels the threshold boost.
import PurifierCore
import SwiftUI

struct PanelView: View {
    let model: AppModel

    @State private var level: Double = 0
    @State private var isDraggingLevel = false
    /// Show the schedule screen instead of the main content.
    @State private var showsSchedule = false
    /// What the schedule screen was opened with: the list, a rule, or a new rule.
    @State private var scheduleOpen: ScheduleOpen = .list

    private var state: PurifierState? { model.controller?.state }
    private var levelRange: ClosedRange<Int> { model.layout.favoriteLevelRange }
    private var isUnreachable: Bool { model.controller?.connection == .unreachable }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            footer
        }
        .frame(width: 344)
        .background(PanelTheme.background)
        .preferredColorScheme(.dark)
        .truncationTooltipOverlay(isActive: model.panelVisible)
        .onAppear {
            model.setPanelVisible(true)
            if let favorite = state?.favoriteLevel { level = Double(model.layout.clampedLevel(favorite)) }
        }
        .onDisappear { model.setPanelVisible(false) }
        .background {
            WindowVisibilityReporter { model.setPanelVisible($0) }
                .frame(width: 0, height: 0)
        }
        .onChange(of: state?.favoriteLevel) { _, newValue in
            if !isDraggingLevel, let newValue { level = Double(model.layout.clampedLevel(newValue)) }
        }
        .onChange(of: state?.mode) { _, _ in
            if !isDraggingLevel, let favorite = state?.favoriteLevel {
                level = Double(model.layout.clampedLevel(favorite))
            }
        }
        .onChange(of: model.panelVisible) { _, visible in
            if !visible { showsSchedule = false }
        }
    }

    // MARK: - Main content

    /// The main panel screen. It stays in the layout even when the schedule screen is open -
    /// it sets the fixed window height, and the schedule screen fits into the same
    /// bounds set by `overlay`.
    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            hero
            notices
            if let state {
                controls(state)
            } else {
                placeholder
            }
        }
        .opacity(showsSchedule ? 0 : 1)
        .allowsHitTesting(!showsSchedule)
        .overlay {
            if showsSchedule {
                PanelScheduleScreen(model: model, open: scheduleOpen, onBack: closeSchedule)
                    .transition(.opacity.combined(with: .offset(x: 24)))
            }
        }
        .clipped()
    }

    private func openSchedule(_ open: ScheduleOpen) {
        scheduleOpen = open
        withAnimation(.easeOut(duration: 0.2)) { showsSchedule = true }
    }

    private func closeSchedule() {
        withAnimation(.easeOut(duration: 0.2)) { showsSchedule = false }
    }

    // MARK: - Header

    /// Filter life on the left in a small font, power on the right.
    private var header: some View {
        HStack(spacing: 8) {
            (Text("Filter ").foregroundStyle(PanelTheme.labelText)
                + Text(filterText).foregroundStyle(.white.opacity(0.82)))
                .font(.system(size: 12))
                .monospacedDigit()
            Spacer(minLength: 8)
            PowerButton(isOn: state?.isOn ?? false, isEnabled: state != nil) {
                if let state { send(.power(!state.isOn)) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var filterText: String {
        guard let state else { return "—" }
        return PanelFormat.filter(percent: state.filterPercent, daysLeft: state.filterDaysLeft)
    }

    // MARK: - Glow and indicator

    private var hero: some View {
        ZStack {
            GlowView(
                quality: AirQuality(pm25: state?.pm25 ?? 0),
                isOn: state?.isOn ?? false,
                mode: state?.mode,
                motorRPM: state?.motorRPM ?? 0,
                favoriteLevel: state?.favoriteLevel ?? 0,
                favoriteLevelMax: levelRange.upperBound,
                isBoosting: model.engine?.isBoosting ?? false,
                paused: !model.panelVisible || showsSchedule
            )
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(state.map { "\($0.pm25)" } ?? "—")
                        .font(.system(size: 64, weight: .thin))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("µg/m³")
                        .font(.system(size: 16))
                        .foregroundStyle(PanelTheme.labelText)
                }
                if let state {
                    Text(AirQuality(pm25: state.pm25).title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .opacity(isUnreachable ? 0.45 : 1)
        }
        .frame(height: 168)
    }

    // MARK: - Errors, boost

    /// The connection state is in the bottom row; the error and the boost stay here.
    private var notices: some View {
        VStack(spacing: 8) {
            if let fault = state?.fault, let text = PanelFormat.fault(fault) {
                notice(text, icon: "exclamationmark.triangle.fill", color: .red)
            }
            if model.engine?.isBoosting == true {
                notice(String(localized: "PM2.5 threshold boost"), icon: "bolt.fill", color: PanelTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .panelCard()
    }

    // MARK: - Controls

    private func controls(_ state: PurifierState) -> some View {
        VStack(spacing: 12) {
            if state.mode == .manual {
                LevelSlider(
                    level: $level,
                    isDragging: $isDraggingLevel,
                    onCommit: { send(.manualLevel($0)) },
                    onStep: step,
                    range: levelRange
                )
            }
            tiles(state)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// A 3 x 3 grid of identical tiles: row 1 - modes, row 2 - screen brightness,
    /// row 3 - sound, buttons and schedule. A tap on a tile sends the
    /// command at once; the schedule tile opens a separate screen.
    private func tiles(_ state: PurifierState) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(PurifierMode.allCases, id: \.self) { mode in
                    PanelChoiceTile(
                        icon: modeIcon(mode),
                        title: PanelFormat.mode(mode),
                        isSelected: mode == state.mode
                    ) {
                        send(.mode(mode))
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(screenOrder, id: \.self) { brightness in
                    PanelChoiceTile(
                        icon: screenIcon(brightness),
                        title: PanelFormat.screen(brightness),
                        isSelected: brightness == state.screen
                    ) {
                        send(.screen(brightness))
                    }
                }
            }
            HStack(spacing: 10) {
                PanelToggleTile(
                    icon: "speaker.wave.2",
                    title: String(localized: "Sound"),
                    isOn: state.sound
                ) {
                    send(.sound(!state.sound))
                }
                PanelToggleTile(
                    icon: "lock",
                    title: String(localized: "Buttons"),
                    isOn: state.childLock
                ) {
                    send(.childLock(!state.childLock))
                }
                PanelScheduleTile(model: model) { openSchedule(.list) }
            }
        }
    }

    /// Order of the screen tiles: from off to bright.
    private var screenOrder: [ScreenBrightness] { [.off, .dim, .bright] }

    private func modeIcon(_ mode: PurifierMode) -> String {
        switch mode {
        case .auto: return "wind"
        case .sleep: return "moon.stars"
        case .manual: return "slider.horizontal.3"
        }
    }

    private func screenIcon(_ brightness: ScreenBrightness) -> String {
        switch brightness {
        case .off: return "rectangle.slash"
        case .dim: return "sun.min"
        case .bright: return "sun.max"
        }
    }

    /// "-"/"+" step within the device range, command sent at once.
    private func step(_ delta: Int) {
        let next = model.layout.clampedLevel(Int(level.rounded()) + delta)
        guard next != Int(level.rounded()) else { return }
        level = Double(next)
        isDraggingLevel = false
        send(.manualLevel(next))
    }

    // MARK: - Starting state

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            switch model.status {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .ready:
                ProgressView().controlSize(.small)
                Text("Reading status…")
            case .missingToken:
                Text("Add a token in settings")
                Button("Settings") { openSettings() }
                    .buttonStyle(.plain)
                    .foregroundStyle(PanelTheme.accent)
            case .unverifiedModel(let deviceModel):
                Text(String(format: String(localized: "Model %@ is not verified - controls may not work correctly"), deviceModel))
                Button("Try Anyway") { model.acceptUnverifiedModel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(PanelTheme.accent)
                Button("Settings") { openSettings() }
                    .buttonStyle(.plain)
                    .foregroundStyle(PanelTheme.accent)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(message)
                Button("Retry") { model.retryNow() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PanelTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(PanelTheme.control))
                    .disabled(Date() < model.retryAllowedAt)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.8))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .panelCard()
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Bottom

    /// Connection state on the left, settings gear on the right.
    private var footer: some View {
        HStack(spacing: 6) {
            statusView
            Spacer(minLength: 8)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusView: some View {
        if model.controller?.pending != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            }
            .foregroundStyle(.white.opacity(0.75))
        } else {
            switch model.controller?.connection ?? .connecting {
            case .online:
                statusLine("Connected", icon: "checkmark.circle.fill", color: PanelTheme.accent)
            case .unreachable:
                statusLine("Disconnected", icon: "wifi.slash", color: .orange)
            case .connecting:
                statusLine("Connecting…", icon: "circle.dotted", color: .white.opacity(0.6))
            }
        }
    }

    private func statusLine(_ text: LocalizedStringKey, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12))
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
    }

    private func openSettings() {
        model.openSettings()
    }

    private func send(_ command: PurifierCommand) {
        guard let engine = model.engine else { return }
        Task { try? await engine.userSend(command) }
    }
}
