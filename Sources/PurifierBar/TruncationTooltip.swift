// Full text of a truncated label. Measurements do not affect the layout,
// and one cancellable task per window replaces timers and polling.
import SwiftUI

@MainActor
@Observable
private final class TruncationTooltipState {
    struct Presentation {
        let text: String
        let point: CGPoint
    }

    var presentation: Presentation?
    private var owner: UUID?
    private var pending: Task<Void, Never>?

    func schedule(owner: UUID, text: String, point: CGPoint) {
        dismiss()
        self.owner = owner
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch { return }
            guard let self, !Task.isCancelled, self.owner == owner else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                self.presentation = Presentation(text: text, point: point)
            }
            self.pending = nil
        }
    }

    func dismiss(owner: UUID? = nil) {
        if let owner, self.owner != owner { return }
        pending?.cancel()
        pending = nil
        self.owner = nil
        presentation = nil
    }
}

private struct TruncationTooltipModifier: ViewModifier {
    let text: String
    let label: Text
    let lineLimit: Int
    let minimumScaleFactor: CGFloat

    @Environment(TruncationTooltipState.self) private var tooltip
    @State private var id = UUID()
    @State private var idealSize: CGSize = .zero
    @State private var actualFrame: CGRect = .zero
    @State private var isHovering = false

    // A single-line Text first shrinks down to minimumScaleFactor, and only
    // then gets truncated. For several lines we compare the full height at the same
    // width. Half a point of tolerance removes geometry rounding errors.
    private var isTruncated: Bool {
        guard actualFrame.width > 0, idealSize.width > 0 else { return false }
        if lineLimit == 1 {
            return idealSize.width * minimumScaleFactor > actualFrame.width + 0.5
        }
        return idealSize.height > actualFrame.height + 0.5
    }

    func body(content: Content) -> some View {
        content
            .lineLimit(lineLimit)
            .minimumScaleFactor(minimumScaleFactor)
            .background {
                label
                    .lineLimit(nil)
                    .fixedSize(horizontal: lineLimit == 1, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { idealSize = $0 }
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("truncationTooltipRoot"))
            } action: { frame in
                actualFrame = frame
                tooltip.dismiss(owner: id)
            }
            .onContinuousHover(coordinateSpace: .named("truncationTooltipRoot")) { phase in
                switch phase {
                case .active(let point):
                    guard !isHovering else { return }
                    isHovering = true
                    if isTruncated { tooltip.schedule(owner: id, text: text, point: point) }
                case .ended:
                    isHovering = false
                    tooltip.dismiss(owner: id)
                }
            }
            .onChange(of: text) { _, _ in tooltip.dismiss(owner: id) }
            .onChange(of: isTruncated) { _, _ in tooltip.dismiss(owner: id) }
            .onDisappear {
                isHovering = false
                tooltip.dismiss(owner: id)
            }
    }
}

/// Places the tooltip near the cursor's entry point, shifting it inside the window.
/// Measurement and placement happen in one pass, with no state per mouse move.
private struct TruncationTooltipPlacement: Layout {
    let point: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let available = ProposedViewSize(width: max(1, min(320, bounds.width - 16)), height: nil)
        let size = bubble.sizeThatFits(available)
        let x = max(8, min(point.x + 8, bounds.width - size.width - 8))
        let y = max(8, min(point.y + 16, bounds.height - size.height - 8))
        bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: available)
    }
}

private struct TruncationTooltipRoot: ViewModifier {
    let isActive: Bool
    @State private var tooltip = TruncationTooltipState()

    func body(content: Content) -> some View {
        content
            .environment(tooltip)
            .overlay {
                if let presentation = tooltip.presentation {
                    TruncationTooltipPlacement(point: presentation.point) {
                        Text(verbatim: presentation.text)
                            .font(.system(size: 12))
                            .foregroundStyle(PanelTheme.valueText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .panelCard(cornerRadius: 8)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .coordinateSpace(name: "truncationTooltipRoot")
            .simultaneousGesture(TapGesture().onEnded { tooltip.dismiss() })
            .onChange(of: isActive) { _, active in
                if !active { tooltip.dismiss() }
            }
            .onDisappear { tooltip.dismiss() }
    }
}

@MainActor
extension Text {
    /// `text` is already localized. The font is set after this modifier,
    /// so that the visible label and the hidden measurement inherit the same style.
    func truncationTooltip(
        _ text: String,
        lineLimit: Int = 1,
        minimumScaleFactor: CGFloat = 1
    ) -> some View {
        modifier(TruncationTooltipModifier(
            text: text, label: self, lineLimit: lineLimit, minimumScaleFactor: minimumScaleFactor
        ))
    }
}

@MainActor
extension View {
    func truncationTooltipOverlay(isActive: Bool = true) -> some View {
        modifier(TruncationTooltipRoot(isActive: isActive))
    }
}
