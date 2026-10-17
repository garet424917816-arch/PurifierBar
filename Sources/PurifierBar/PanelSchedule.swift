// Schedule in the panel: a tile in the main screen's grid and a separate screen over
// it. The panel window size does not change: the schedule screen fits into the same
// bounds that the main content sets. Any edit goes straight to the settings
// through the model - without a "Save" button. No timers: the "next event"
// is computed from `now`, which is refreshed when the tile/screen appears, when the panel
// opens, and after each edit.
import Foundation
import PurifierCore
import SwiftUI

// MARK: - "next ..." row

/// Labels of the next event - shared by the main screen tile and the header
/// of the separate schedule screen.
private enum ScheduleSummary {
    /// Full label for the screen header: "next today 22:00".
    static func next(after now: Date, rules: [ScheduleRule]) -> String {
        if let next = PanelFormat.scheduleNext(after: now, rules: rules, calendar: .current) {
            return String(localized: "next \(next)")
        }
        return rules.isEmpty ? String(localized: "no rules") : String(localized: "off")
    }

    /// Short label for the tile: only the time if the event is today, otherwise
    /// "tomorrow 07:00" / "Fri 07:00"; "-" when nothing is scheduled.
    static func tileNext(after now: Date, rules: [ScheduleRule]) -> String {
        guard let next = PanelFormat.scheduleNext(after: now, rules: rules, calendar: .current)
        else { return "-" }
        let today = String(localized: "today ")
        return next.hasPrefix(today) ? String(next.dropFirst(today.count)) : next
    }
}

// MARK: - What to open the screen with

/// Intent to open the schedule screen: just the list, the editor of an existing rule,
/// or the editor of a newly created one. The tile passes it along with showing the screen.
enum ScheduleOpen {
    case list
    case rule(UUID)
    case newRule
}

// MARK: - Tile on the main screen

/// The schedule tile in the main screen's grid: icon, name and a small label
/// of the next event. The dot at the top right is warm when there is at least one enabled
/// rule, and grey when there are none. A tap opens the schedule screen with the list.
struct PanelScheduleTile: View {
    let model: AppModel
    let onOpen: () -> Void

    /// The moment used to compute the "next event". Updated without timers.
    @State private var now = Date()

    var body: some View {
        Button(action: onOpen) {
            PanelTileBody(
                icon: "clock",
                title: String(localized: "Schedule"),
                isSelected: false,
                isOn: hasEnabledRule,
                subtitle: ScheduleSummary.tileNext(after: now, rules: model.settings.schedule)
            )
        }
        .buttonStyle(.plain)
        .help("Schedule")
        .onAppear { now = Date() }
        .onChange(of: model.panelVisible) { _, visible in
            if visible { now = Date() }
        }
    }

    private var hasEnabledRule: Bool {
        model.settings.schedule.contains(where: \.isEnabled)
    }
}

// MARK: - Schedule screen

/// The schedule screen over the main one: a "back" row at the top and a scrollable
/// list of rules with the editor. It takes exactly the allotted bounds, so the panel
/// height does not change.
struct PanelScheduleScreen: View {
    let model: AppModel
    /// What the screen was opened with: the list, the rule editor, or the new-rule editor.
    let open: ScheduleOpen
    let onBack: () -> Void

    /// The rule whose editor is open; at most one at a time.
    @State private var editingID: UUID?
    /// The moment used to compute the "next event". Updated without timers.
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 0) {
                    if sortedRules.isEmpty {
                        emptyRow
                    } else {
                        rulesList
                    }
                    addButton
                    if let error = model.lastSaveError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
                .panelCard()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanelTheme.background)
        .onAppear {
            now = Date()
            apply(open)
        }
        .onChange(of: model.panelVisible) { _, visible in
            if visible { now = Date() }
        }
    }

    /// Initial state by the open intent: the list, the editor of an existing rule,
    /// or creating a new one with the editor opened straight away.
    private func apply(_ open: ScheduleOpen) {
        switch open {
        case .list:
            break
        case .rule(let id):
            editingID = id
        case .newRule:
            addRule()
        }
    }

    // MARK: - Screen header

    /// "Back" to the main screen on the left, "next ..." on the right.
    private var topBar: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Schedule")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(summary)
                .truncationTooltip(summary)
                .font(.system(size: 11))
                .foregroundStyle(PanelTheme.labelText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var summary: String {
        ScheduleSummary.next(after: now, rules: model.settings.schedule)
    }

    // MARK: - Rule list

    /// Stable order by time: on ties the original index decides,
    /// the `settings.schedule` array itself stays unchanged.
    private var sortedRules: [ScheduleRule] { sortedSchedule(model.settings.schedule) }

    @ViewBuilder
    private var rulesList: some View {
        ForEach(Array(sortedRules.enumerated()), id: \.element.id) { entry in
            if entry.offset > 0 { separator }
            ScheduleRuleRowView(
                rule: entry.element,
                onToggle: { update(entry.element.id) { $0.isEnabled.toggle() } },
                onOpen: { toggleEditor(entry.element.id) }
            )
            if editingID == entry.element.id {
                ruleEditor(entry.element)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(PanelTheme.cardStroke).frame(height: 1)
    }

    private func toggleEditor(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) {
            editingID = editingID == id ? nil : id
        }
    }

    // MARK: - Rule editor

    private func ruleEditor(_ rule: ScheduleRule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            timeEditor(rule)
            field("Days") { weekdayCapsules(rule) }
            field("Power") { powerCapsules(rule) }
            field("Mode") { modeCapsules(rule) }
            if rule.action.mode == .manual { levelRow(rule) }
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    delete(rule.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { editingID = nil }
                } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PanelTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
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

    /// Time: two pairs of "-"/"+" around the hours and the minutes.
    private func timeEditor(_ rule: ScheduleRule) -> some View {
        HStack(spacing: 6) {
            PanelRoundButton(system: "minus", size: 34) { stepHour(rule.id, up: false) }
            timeNumber(rule.hour)
            PanelRoundButton(system: "plus", size: 34) { stepHour(rule.id, up: true) }
            Text(":")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(PanelTheme.labelText)
                .padding(.horizontal, 2)
            PanelRoundButton(system: "minus", size: 34) { stepMinute(rule.id, up: false) }
            timeNumber(rule.minute)
            PanelRoundButton(system: "plus", size: 34) { stepMinute(rule.id, up: true) }
        }
        .frame(maxWidth: .infinity)
    }

    private func timeNumber(_ value: Int) -> some View {
        Text(String(format: "%02d", value))
            .font(.system(size: 22, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(PanelTheme.valueText)
            .frame(minWidth: 30)
    }

    private func weekdayCapsules(_ rule: ScheduleRule) -> some View {
        HStack(spacing: 4) {
            ForEach(PanelWeekday.options, id: \.day.rawValue) { option in
                WeekdayCapsule(
                    title: option.title,
                    isSelected: rule.weekdays.contains(option.day)
                ) {
                    update(rule.id) { $0.weekdays.formSymmetricDifference(option.day) }
                }
            }
        }
    }

    private func powerCapsules(_ rule: ScheduleRule) -> some View {
        HStack(spacing: 8) {
            ScheduleCapsule(title: String(localized: "No change"), isSelected: rule.action.power == nil) {
                update(rule.id) { $0.action.power = nil }
            }
            ScheduleCapsule(title: String(localized: "On"), isSelected: rule.action.power == true) {
                update(rule.id) { $0.action.power = true }
            }
            ScheduleCapsule(title: String(localized: "Off"), isSelected: rule.action.power == false) {
                update(rule.id) { $0.action.power = false }
            }
        }
    }

    private func modeCapsules(_ rule: ScheduleRule) -> some View {
        HStack(spacing: 8) {
            ScheduleCapsule(title: String(localized: "No change"), isSelected: rule.action.mode == nil) {
                setMode(rule.id, nil)
            }
            ScheduleCapsule(title: String(localized: "Auto"), isSelected: rule.action.mode == .auto) {
                setMode(rule.id, .auto)
            }
            ScheduleCapsule(title: String(localized: "Sleep"), isSelected: rule.action.mode == .sleep) {
                setMode(rule.id, .sleep)
            }
            ScheduleCapsule(title: String(localized: "Manual"), isSelected: rule.action.mode == .manual) {
                setMode(rule.id, .manual)
            }
        }
    }

    private func levelRow(_ rule: ScheduleRule) -> some View {
        field("Level") {
            HStack(spacing: 10) {
                PanelRoundButton(system: "minus", size: 34) {
                    update(rule.id) {
                        $0.action.manualLevel = max(0, ($0.action.manualLevel ?? 7) - 1)
                    }
                }
                Text("\(rule.action.manualLevel ?? 7)")
                    .font(.system(size: 17, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(PanelTheme.valueText)
                    .frame(minWidth: 24)
                PanelRoundButton(system: "plus", size: 34) {
                    update(rule.id) {
                        $0.action.manualLevel = min(14, ($0.action.manualLevel ?? 7) + 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - List buttons

    private var emptyRow: some View {
        Text("No rules yet")
            .font(.system(size: 12))
            .foregroundStyle(PanelTheme.labelText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
    }

    private var addButton: some View {
        Button(action: addRule) {
            Label("Add rule", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PanelTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Edits (straight to settings)

    private func update(_ id: UUID, _ mutate: (inout ScheduleRule) -> Void) {
        mutateRule(model, id, mutate)
        now = Date()
    }

    /// A level makes sense only for manual mode: when "Manual" is chosen without a level
    /// we set 7, when any other mode is chosen - we remove the level.
    private func setMode(_ id: UUID, _ newMode: PurifierMode?) {
        update(id) { rule in
            rule.action.mode = newMode
            if newMode == .manual {
                if rule.action.manualLevel == nil { rule.action.manualLevel = 7 }
            } else {
                rule.action.manualLevel = nil
            }
        }
    }

    /// Hours - in a cycle 0...23.
    private func stepHour(_ id: UUID, up: Bool) {
        update(id) { $0.hour = steppedHour($0.hour, up: up) }
    }

    /// Minutes - in steps of 5 in a cycle; if the value is not a multiple of 5, the first step
    /// rounds to the nearest multiple in the step direction.
    private func stepMinute(_ id: UUID, up: Bool) {
        update(id) { $0.minute = steppedMinute($0.minute, up: up) }
    }

    /// New rule 08:00 daily, enabled, no action - and its editor straight away.
    private func addRule() {
        let rule = ScheduleRule(hour: 8, minute: 0, weekdays: .everyday, action: ScheduleAction())
        var settings = model.settings
        settings.schedule.append(rule)
        model.applySettings(settings)
        now = Date()
        withAnimation(.easeOut(duration: 0.2)) { editingID = rule.id }
    }

    private func delete(_ id: UUID) {
        var settings = model.settings
        settings.schedule.removeAll { $0.id == id }
        model.applySettings(settings)
        now = Date()
        withAnimation(.easeOut(duration: 0.2)) {
            if editingID == id { editingID = nil }
        }
    }
}

// MARK: - Shared elements

/// A rule row in the list on the schedule screen: a capsule toggle on the left, the time
/// and "days - action" on the right. A tap on the toggle is `onToggle`, a tap on the text -
/// `onOpen`.
struct ScheduleRuleRowView: View {
    let rule: ScheduleRule
    let onToggle: () -> Void
    let onOpen: () -> Void

    private var actionSummary: String {
        PanelFormat.scheduleWeekdays(rule.weekdays) + " · " + PanelFormat.scheduleAction(rule.action)
    }

    /// Fixed row height: the card computes the visible list height from it.
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            RuleTogglePill(isOn: rule.isEnabled, action: onToggle)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PanelFormat.scheduleTime(hour: rule.hour, minute: rule.minute))
                        .font(.system(size: 17, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(PanelTheme.valueText)
                    Text(actionSummary)
                        .truncationTooltip(actionSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(PanelTheme.labelText)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .opacity(rule.isEnabled ? 1 : 0.45)
    }
}

/// Stable order by time: on ties the original index decides, the array itself
/// stays unchanged.
private func sortedSchedule(_ rules: [ScheduleRule]) -> [ScheduleRule] {
    rules.enumerated()
        .sorted { lhs, rhs in
            (lhs.element.hour, lhs.element.minute, lhs.offset)
                < (rhs.element.hour, rhs.element.minute, rhs.offset)
        }
        .map(\.element)
}

/// Point edit of a rule through the model: the other settings and the array order are
/// unchanged.
@MainActor
private func mutateRule(_ model: AppModel, _ id: UUID, _ mutate: (inout ScheduleRule) -> Void) {
    var settings = model.settings
    guard let index = settings.schedule.firstIndex(where: { $0.id == id }) else { return }
    mutate(&settings.schedule[index])
    model.applySettings(settings)
}
