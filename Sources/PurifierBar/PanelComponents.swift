// Panel building blocks: palette, card, button tile, menu tile,
// toggle tile, level slider and step button. All are pure views
// with no timers and no network: motion stays with the state.
import PurifierCore
import SwiftUI

// MARK: - Palette

enum PanelTheme {
    static let background = Color(white: 0.055)
    static let card = Color(white: 0.11)
    static let cardStroke = Color.white.opacity(0.06)
    static let control = Color(white: 0.13)
    /// Warm light accent: enabled state, selected value.
    static let accent = Color(red: 0.86, green: 0.82, blue: 0.74)
    static let valueText = Color.white
    static let labelText = Color.white.opacity(0.55)
    static let fillLeading = Color(red: 0.36, green: 0.34, blue: 0.30)
    static let fillTrailing = Color(red: 0.24, green: 0.23, blue: 0.21)
    static let thumb = Color(white: 0.92)
    /// Warm lighter background and border of the selected tile.
    static let tileSelected = Color(red: 0.27, green: 0.25, blue: 0.21)
    static let tileSelectedStroke = Color(red: 0.86, green: 0.82, blue: 0.74).opacity(0.55)
}

// MARK: - Card

/// Background and border of the card. The radius and padding are set by the content.
struct PanelCard: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(PanelTheme.card))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(PanelTheme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func panelCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(PanelCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Grid tiles

/// Content of a grid tile: icon on top, name at the bottom. The selected tile is highlighted
/// with a warm background and border; the toggle shows a state dot. `subtitle` adds
/// a small line under the name - the tile height does not change because of it.
struct PanelTileBody: View {
    let icon: String
    let title: String
    let isSelected: Bool
    /// `nil` - a choice tile without an indicator; otherwise - the toggle's state.
    var isOn: Bool?
    /// Small caption under the name; `nil` - a tile without a caption.
    var subtitle: String?

    private let cornerRadius: CGFloat = 12

    var body: some View {
        VStack(spacing: subtitle == nil ? 6 : 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSelected ? PanelTheme.accent : Color.white.opacity(0.82))
            Text(title)
                .truncationTooltip(title, minimumScaleFactor: 0.85)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? PanelTheme.valueText : PanelTheme.labelText)
            if let subtitle {
                Text(subtitle)
                    .truncationTooltip(subtitle, minimumScaleFactor: 0.8)
                    .font(.system(size: 10))
                    .foregroundStyle(PanelTheme.labelText)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isSelected ? PanelTheme.tileSelected : PanelTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    isSelected ? PanelTheme.tileSelectedStroke : PanelTheme.cardStroke,
                    lineWidth: 1
                )
        )
        .overlay(alignment: .topTrailing) {
            if let isOn {
                Circle()
                    .fill(isOn ? PanelTheme.accent : Color.white.opacity(0.18))
                    .frame(width: 8, height: 8)
                    .padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Choice tile: a tap sends the corresponding command at once.
struct PanelChoiceTile: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelTileBody(icon: icon, title: title, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Toggle tile: the whole card is one button, the state is shown by a dot.
struct PanelToggleTile: View {
    let icon: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelTileBody(icon: icon, title: title, isSelected: false, isOn: isOn)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Level slider

/// Track with gradient fill, a light thumb and round "-"/"+" buttons on the sides.
/// While dragging it only changes the value; the command is sent on release.
/// Labels are a separate row below all controls, so the track stays on one
/// horizontal line with the centers of the round buttons.
struct LevelSlider: View {
    @Binding var level: Double
    @Binding var isDragging: Bool
    let onCommit: (Int) -> Void
    let onStep: (Int) -> Void
    var range: ClosedRange<Int> = 0...14

    private let trackHeight: CGFloat = 30
    private let thumbWidth: CGFloat = 22
    private let thumbHeight: CGFloat = 28
    private let buttonSize: CGFloat = 44
    private let spacing: CGFloat = 10
    /// Track edge inset for the labels (matches the former `padding`).
    private let labelInset: CGFloat = 8

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: spacing) {
                PanelRoundButton(system: "minus", size: buttonSize) { onStep(-1) }
                track
                PanelRoundButton(system: "plus", size: buttonSize) { onStep(1) }
            }
            labels
        }
    }

    private var span: Double { Double(range.upperBound - range.lowerBound) }

    /// Track fraction for the current value, 0...1.
    private var fraction: Double {
        guard span > 0 else { return 0 }
        let clamped = min(max(level, Double(range.lowerBound)), Double(range.upperBound))
        return (clamped - Double(range.lowerBound)) / span
    }

    private var track: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - thumbWidth)
            let offset = CGFloat(fraction) * travel
            let radius = trackHeight / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius).fill(PanelTheme.card)
                LinearGradient(
                    colors: [PanelTheme.fillLeading, PanelTheme.fillTrailing],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: offset + thumbWidth / 2)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                RoundedRectangle(cornerRadius: thumbWidth / 2 - 2)
                    .fill(PanelTheme.thumb)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: offset)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let raw = Double(
                            min(max((value.location.x - thumbWidth / 2) / travel, 0), 1)
                        )
                        // Step 1, as in the previous slider.
                        level = Double(range.lowerBound) + (raw * span).rounded()
                    }
                    .onEnded { _ in
                        isDragging = false
                        onCommit(Int(level.rounded()))
                    }
            )
        }
        .frame(height: trackHeight)
    }

    /// "0", the current level and "14" - below the track, with insets for the round buttons.
    private var labels: some View {
        HStack(spacing: 0) {
            Text("\(range.lowerBound)")
            Spacer(minLength: 4)
            Text("\(Int(level.rounded()))")
                .foregroundStyle(PanelTheme.valueText.opacity(0.85))
                .monospacedDigit()
            Spacer(minLength: 4)
            Text("\(range.upperBound)")
        }
        .font(.system(size: 10))
        .foregroundStyle(PanelTheme.labelText)
        .padding(.horizontal, buttonSize + spacing + labelInset)
    }

}

// MARK: - Round step button

/// Round "-"/"+" step button: shared by the level slider and the schedule editor.
struct PanelRoundButton: View {
    let system: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(Circle().fill(PanelTheme.control))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Round power button

struct PowerButton: View {
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? PanelTheme.accent : Color.white.opacity(0.55))
                .frame(width: 40, height: 40)
                .background(Circle().fill(PanelTheme.control))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

// MARK: - Time steps

/// Next hour in a cycle 0...23. Shared by the panel editor and the window.
func steppedHour(_ hour: Int, up: Bool) -> Int {
    ((hour + (up ? 1 : -1)) % 24 + 24) % 24
}

/// Next minute in steps of 5 in a cycle 0...59. If the value is not a multiple of 5,
/// the first step rounds it to the nearest multiple in the step direction.
func steppedMinute(_ minute: Int, up: Bool) -> Int {
    let next: Int
    if minute % 5 == 0 {
        next = minute + (up ? 5 : -5)
    } else if up {
        next = (minute / 5 + 1) * 5
    } else {
        next = (minute / 5) * 5
    }
    return ((next % 60) + 60) % 60
}

// MARK: - Weekdays

/// Weekdays in order Mon..Sun with their labels - shared by the panel and the window.
enum PanelWeekday {
    static let options: [(day: Weekdays, title: String)] = [
        (.monday, String(localized: "Mon")),
        (.tuesday, String(localized: "Tue")),
        (.wednesday, String(localized: "Wed")),
        (.thursday, String(localized: "Thu")),
        (.friday, String(localized: "Fri")),
        (.saturday, String(localized: "Sat")),
        (.sunday, String(localized: "Sun")),
    ]
}

// MARK: - Shared editor controls

/// Small capsule toggle: warm accent when on. Shared by
/// the schedule row in the panel and the toggle rows in the settings window.
struct RuleTogglePill: View {
    let isOn: Bool
    let action: () -> Void

    private let width: CGFloat = 30
    private let height: CGFloat = 18

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? PanelTheme.accent : Color.white.opacity(0.18))
                .frame(width: width, height: height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? Color(white: 0.16) : Color.white.opacity(0.75))
                        .frame(width: height - 4, height: height - 4)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Capsule variant in the editor (power, mode): the selected one has a warm background and border.
struct ScheduleCapsule: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .truncationTooltip(title, minimumScaleFactor: 0.8)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? PanelTheme.valueText : PanelTheme.labelText)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? PanelTheme.tileSelected : PanelTheme.control)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isSelected ? PanelTheme.tileSelectedStroke : PanelTheme.cardStroke,
                                    lineWidth: 1
                                )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// Weekday capsule: fixed width so that the seven days fit in one row.
struct WeekdayCapsule: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? PanelTheme.valueText : PanelTheme.labelText)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? PanelTheme.tileSelected : PanelTheme.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? PanelTheme.tileSelectedStroke : PanelTheme.cardStroke,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
