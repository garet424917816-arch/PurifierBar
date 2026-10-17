// Settings window in the panel style: device IP, PM2.5 threshold and rules schedule.
// Edits live in a local draft; "Save" writes the file and notifies the main
// process. The view exists only in the settings process and works through `SettingsSession`.
import PurifierCore
import SwiftUI

struct SettingsView: View {
    let session: SettingsSession

    @AppStorage(SettingsSync.favoriteLevelMaximumKey) private var favoriteLevelMaximum = 14

    private var boostLevelRange: ClosedRange<Int> {
        0...min(14, max(0, favoriteLevelMaximum))
    }

    @State private var draft = AutomationSettings.standard
    @State private var host = ""
    @State private var token = ""
    @State private var loaded = false
    @State private var isDraggingBoostLevel = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    deviceSection
                    thresholdSection
                    scheduleSection
                    alertsSection
                    systemSection
                    quitSection
                }
                .padding(16)
            }
            saveBar
        }
        // The width is fixed, the height can be dragged (the window `.contentSize` takes the bounds from here).
        .frame(width: 480)
        .frame(minHeight: 420, idealHeight: 700, maxHeight: .infinity)
        .background(PanelTheme.background)
        .preferredColorScheme(.dark)
        .truncationTooltipOverlay()
        .onAppear {
            guard !loaded else { return }
            host = session.host
            draft = session.settings
            loaded = true
        }
        .task { await session.refreshTokenStatus() }
        // Schedule edits from the panel are visible in the window, but an unsaved draft
        // of the window (when its schedule has diverged from the model) is not overwritten.
        .onChange(of: session.settings.schedule) { old, new in
            if draft.schedule == old { draft.schedule = new }
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        sectionCard("Device") {
            cardRow {
                TextField("Device IP", text: $host)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(PanelTheme.valueText)
                    .tint(PanelTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(PanelTheme.control)
                    )
                    .onSubmit { session.changeHost(host) }
            }
            cardDivider
            cardRow {
                HStack(alignment: .top, spacing: 8) {
                    hintText("Changing the IP reconnects to the device.")
                    Spacer(minLength: 8)
                    Button("Save IP") { session.changeHost(host) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PanelTheme.accent)
                }
            }
            cardDivider
            cardRow {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Token", text: $token)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(PanelTheme.valueText)
                        .tint(PanelTheme.accent)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(PanelTheme.control))
                        .disabled(session.isSavingToken)
                        .onSubmit { saveToken() }
                    Link("You can get a token using Xiaomi-cloud-tokens-extractor",
                         destination: URL(string: "https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor")!)
                        .font(.system(size: 12))
                        .foregroundStyle(PanelTheme.accent)
                    if let error = session.tokenSaveError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        if let present = session.tokenPresent {
                            Text(present ? String(localized: "Token saved") : String(localized: "No token saved"))
                                .font(.system(size: 12))
                                .foregroundStyle(PanelTheme.labelText)
                        }
                        Spacer(minLength: 8)
                        Button("Save token", action: saveToken)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PanelTheme.accent)
                            .disabled(session.isSavingToken || token.isEmpty)
                    }
                }
            }
        }
    }

    private func saveToken() {
        Task {
            if await session.saveToken(hex: token) { token = "" }
        }
    }

    private var thresholdSection: some View {
        sectionCard("PM2.5 Threshold") {
            cardRow {
                ToggleRow(title: "Enabled", isOn: $draft.threshold.isEnabled)
            }
            cardDivider
            cardRow {
                StepperRow(
                    title: "Threshold: \(draft.threshold.pm25Limit) µg/m³",
                    value: $draft.threshold.pm25Limit,
                    range: 0...600,
                    step: 5
                )
            }
            cardDivider
            cardRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Boost level: \(draft.threshold.boostLevel)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.85))
                    LevelSlider(
                        level: boostLevelSlider,
                        isDragging: $isDraggingBoostLevel,
                        onCommit: { draft.threshold.boostLevel = $0 },
                        onStep: { delta in
                            draft.threshold.boostLevel = min(
                                boostLevelRange.upperBound,
                                max(boostLevelRange.lowerBound,
                                    draft.threshold.boostLevel + delta)
                            )
                        },
                        range: boostLevelRange
                    )
                }
            }
            cardDivider
            cardRow {
                StepperRow(
                    title: "Boost after: \(riseMinutes.wrappedValue) min",
                    value: riseMinutes,
                    range: ThresholdSettings.riseMinutesRange
                )
            }
            cardDivider
            cardRow {
                StepperRow(
                    title: "Stop boost after: \(fallMinutes.wrappedValue) min",
                    value: fallMinutes,
                    range: ThresholdSettings.fallMinutesRange
                )
            }
            cardDivider
            cardRow {
                VStack(alignment: .leading, spacing: 4) {
                    hintText(
                        "If PM2.5 stays above the threshold for \(riseMinutes.wrappedValue) min, boost turns on. After \(fallMinutes.wrappedValue) min at or below it, boost stops and the previous mode returns."
                    )
                    hintText("After a manual command, boost waits until PM2.5 falls to or below the threshold.")
                }
            }
        }
    }

    private var scheduleSection: some View {
        sectionCard("Schedule") {
            ForEach($draft.schedule) { $rule in
                cardRow {
                    ScheduleRuleEditor(rule: $rule) {
                        let id = rule.id
                        draft.schedule.removeAll { $0.id == id }
                    }
                }
                cardDivider
            }
            cardRow {
                Button {
                    draft.schedule.append(ScheduleRule(hour: 8, minute: 0))
                } label: {
                    Label("Add rule", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PanelTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var alertsSection: some View {
        sectionCard("Notifications") {
            cardRow { ToggleRow(title: "Filter running low", isOn: $draft.alerts.filterLow) }
            cardDivider
            cardRow { ToggleRow(title: "Device fault", isOn: $draft.alerts.fault) }
            cardDivider
            cardRow { ToggleRow(title: "Device unavailable", isOn: $draft.alerts.unreachable) }
            cardDivider
            cardRow {
                StepperRow(
                    title: "Unavailable for: \(draft.alerts.unreachableMinutes) min",
                    value: $draft.alerts.unreachableMinutes,
                    range: 1...240
                )
            }
            cardDivider
            cardRow {
                hintText(
                    "Notifications require permission in System Settings > Notifications."
                )
            }
        }
    }

    private var systemSection: some View {
        sectionCard("System") {
            LaunchAtLoginRow()
        }
    }

    private var quitSection: some View {
        sectionCard("Quit") {
            cardRow {
                Button {
                    session.quitApp()
                } label: {
                    Text("Quit Purifier Bar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Pinned "Save" panel

    private var saveBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PanelTheme.cardStroke).frame(height: 1)
            HStack(spacing: 12) {
                if let error = session.lastSaveError {
                    Text(error)
                        .truncationTooltip(error, lineLimit: 2)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    session.applySettings(draft)
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(PanelTheme.tileSelected)
                                .overlay(
                                    Capsule().strokeBorder(PanelTheme.tileSelectedStroke, lineWidth: 1)
                                )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(PanelTheme.background)
    }

    // MARK: - Section frame

    /// Small grey heading and a card with internal padding of 14.
    @ViewBuilder
    private func sectionCard<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PanelTheme.labelText)
                .padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .padding(14)
                .frame(maxWidth: .infinity)
                .panelCard()
        }
    }

    /// Card row with equal vertical padding.
    private func cardRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Thin divider between card rows.
    private var cardDivider: some View {
        Rectangle().fill(PanelTheme.cardStroke).frame(height: 1)
    }

    /// Hint under the row: 11 pt, muted color.
    private func hintText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(PanelTheme.labelText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Derived bindings

    private var riseMinutes: Binding<Int> {
        Binding(
            get: {
                ThresholdSettings.clampedMinutes(
                    for: draft.threshold.riseDuration, in: ThresholdSettings.riseMinutesRange
                )
            },
            set: { draft.threshold.riseDuration = TimeInterval($0) * 60 }
        )
    }

    private var fallMinutes: Binding<Int> {
        Binding(
            get: {
                ThresholdSettings.clampedMinutes(
                    for: draft.threshold.fallDuration, in: ThresholdSettings.fallMinutesRange
                )
            },
            set: { draft.threshold.fallDuration = TimeInterval($0) * 60 }
        )
    }

    /// The stored setting stays intact until edited; the slider uses the device range.
    private var boostLevelSlider: Binding<Double> {
        Binding(
            get: { Double(min(draft.threshold.boostLevel, boostLevelRange.upperBound)) },
            set: { draft.threshold.boostLevel = min(
                boostLevelRange.upperBound,
                max(boostLevelRange.lowerBound, Int($0.rounded()))
            ) }
        )
    }
}

// MARK: - Card row controls

/// Toggle row: name on the left, toggle capsule on the right.
private struct ToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.85))
            Spacer(minLength: 8)
            RuleTogglePill(isOn: isOn) { isOn.toggle() }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
    }
}

/// Step row: value on the left, a pair of round "-"/"+" buttons on the right.
private struct StepperRow: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.85))
            Spacer(minLength: 8)
            PanelRoundButton(system: "minus", size: 30) {
                value = max(range.lowerBound, value - step)
            }
            PanelRoundButton(system: "plus", size: 30) {
                value = min(range.upperBound, value + step)
            }
        }
    }
}

// MARK: - Launch at login

/// Shows the real SMAppService state; a registration error - as text, without a crash.
private struct LaunchAtLoginRow: View {
    @State private var isEnabled = false
    @State private var requiresApproval = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if LaunchAtLogin.isBundled {
                ToggleRow(title: "Launch at login", isOn: enabledBinding)
                if requiresApproval {
                    Text("Approval required. Allow the app in System Settings > General > Login Items.")
                        .font(.system(size: 11))
                        .foregroundStyle(PanelTheme.labelText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        LaunchAtLogin.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PanelTheme.accent)
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ToggleRow(title: "Launch at login", isOn: .constant(false), isEnabled: false)
                Text("Launch at login is only available in the app bundle.")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.labelText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    errorText = nil
                } catch {
                    errorText = String(localized: "Could not change launch at login: \(error.localizedDescription)")
                }
                refresh()
            }
        )
    }

    private func refresh() {
        isEnabled = LaunchAtLogin.isEnabled
        requiresApproval = LaunchAtLogin.requiresApproval
    }
}

// MARK: - Schedule rule editor

/// The rule in the style of the panel editor: toggle and time at the top, then days, power
/// and mode as capsules, and the level for manual mode.
private struct ScheduleRuleEditor: View {
    @Binding var rule: ScheduleRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RuleTogglePill(isOn: rule.isEnabled) { rule.isEnabled.toggle() }
                TimeField(hour: $rule.hour, minute: $rule.minute)
                Spacer(minLength: 8)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            field("Days") { weekdayCapsules }
            field("Power") { powerCapsules }
            field("Mode") { modeCapsules }
            if rule.action.mode == .manual { field("Level") { levelRow } }
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PanelTheme.labelText)
            content()
        }
    }

    private var weekdayCapsules: some View {
        HStack(spacing: 4) {
            ForEach(PanelWeekday.options, id: \.day.rawValue) { option in
                WeekdayCapsule(
                    title: option.title,
                    isSelected: rule.weekdays.contains(option.day)
                ) {
                    rule.weekdays.formSymmetricDifference(option.day)
                }
            }
        }
    }

    private var powerCapsules: some View {
        HStack(spacing: 8) {
            ScheduleCapsule(title: String(localized: "No change", table: "Schedule"), isSelected: rule.action.power == nil) {
                rule.action.power = nil
            }
            ScheduleCapsule(title: String(localized: "Turn on"), isSelected: rule.action.power == true) {
                rule.action.power = true
            }
            ScheduleCapsule(title: String(localized: "Turn off"), isSelected: rule.action.power == false) {
                rule.action.power = false
            }
        }
    }

    private var modeCapsules: some View {
        HStack(spacing: 8) {
            ScheduleCapsule(title: String(localized: "No change", table: "Schedule"), isSelected: rule.action.mode == nil) {
                rule.action.mode = nil
            }
            ScheduleCapsule(title: String(localized: "Auto"), isSelected: rule.action.mode == .auto) {
                rule.action.mode = .auto
            }
            ScheduleCapsule(title: String(localized: "Sleep"), isSelected: rule.action.mode == .sleep) {
                rule.action.mode = .sleep
            }
            ScheduleCapsule(title: String(localized: "Manual"), isSelected: rule.action.mode == .manual) {
                rule.action.mode = .manual
            }
        }
    }

    private var levelRow: some View {
        HStack(spacing: 10) {
            PanelRoundButton(system: "minus", size: 30) {
                rule.action.manualLevel = max(0, (rule.action.manualLevel ?? 0) - 1)
            }
            Text("\(rule.action.manualLevel ?? 0)")
                .font(.system(size: 17, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(PanelTheme.valueText)
                .frame(minWidth: 24)
            PanelRoundButton(system: "plus", size: 30) {
                rule.action.manualLevel = min(14, (rule.action.manualLevel ?? 0) + 1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Rule time

/// Time in the style of the panel editor: "-" hours "+" : "-" minutes "+".
/// Hours - in a cycle, minutes - in steps of 5; the steps are shared with the panel.
private struct TimeField: View {
    @Binding var hour: Int
    @Binding var minute: Int
    var buttonSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 5) {
            PanelRoundButton(system: "minus", size: buttonSize) {
                hour = steppedHour(hour, up: false)
            }
            number(hour)
            PanelRoundButton(system: "plus", size: buttonSize) {
                hour = steppedHour(hour, up: true)
            }
            Text(":")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(PanelTheme.labelText)
                .padding(.horizontal, 1)
            PanelRoundButton(system: "minus", size: buttonSize) {
                minute = steppedMinute(minute, up: false)
            }
            number(minute)
            PanelRoundButton(system: "plus", size: buttonSize) {
                minute = steppedMinute(minute, up: true)
            }
        }
    }

    private func number(_ value: Int) -> some View {
        Text(String(format: "%02d", value))
            .font(.system(size: 20, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(PanelTheme.valueText)
            .frame(minWidth: 28)
    }
}
