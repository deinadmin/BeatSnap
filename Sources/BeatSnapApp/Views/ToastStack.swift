import SwiftUI

/// Newest at the bottom, with two narrow shoulders behind it. The expanded layout owns
/// the hover region, including its gaps, so moving between cards doesn't collapse it.
struct ToastStack: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isHovering = false
    @State private var isWindowVisible = true
    @State private var isExpandedByKeyboard = false

    private var isExpanded: Bool { isHovering || isExpandedByKeyboard || voiceOverEnabled }
    private var isPaused: Bool { isExpanded || !isWindowVisible }
    private var activeItems: [Toast] { center.items.filter { !$0.isDismissing } }

    var body: some View {
        ToastStackLayout(expansion: isExpanded ? 1 : 0) {
            ForEach(center.items) { toast in
                let siblings = toast.isDismissing ? center.items : activeItems
                let depth = siblings.count - 1 - (siblings.firstIndex(where: { $0.id == toast.id }) ?? 0)
                let slidesOut = toast.isDismissing && !reduceMotion
                // Keep overlapping cards in separate glass containers so their
                // surfaces cannot merge or morph into one another.
                GlassEffectContainer(spacing: 0) {
                    ToastCard(toast: toast, dismiss: { center.dismiss(toast.id) })
                }
                .scaleEffect(x: isExpanded ? 1 : 1 - CGFloat(depth) * 0.045, y: 1, anchor: .bottom)
                .blur(radius: slidesOut ? 6 : 0)
                .opacity(toast.isDismissing ? 0 : 1)
                .visualEffect { content, geometry in
                    content.offset(y: slidesOut ? geometry.size.height + 8 : 0)
                }
                .animation(.easeInOut(duration: Toast.dismissalDuration), value: toast.isDismissing)
                .zIndex(Double(center.items.firstIndex(where: { $0.id == toast.id }) ?? 0))
                .allowsHitTesting(!toast.isDismissing && (isExpanded || depth == 0))
                .accessibilityHidden(toast.isDismissing)
                .layoutValue(key: ToastSlotKey.self,
                             value: ToastSlot(id: toast.id, isDismissing: toast.isDismissing))
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity : .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .modifier(active: ToastBlur(radius: 6),
                                                  identity: ToastBlur(radius: 0))),
                    // Eviction must be immediate, even while the new card fades in.
                    removal: .identity
                ))
                .task(id: isPaused) {
                    guard !isPaused else { return }
                    do {
                        try await Task.sleep(for: toast.lifetime)
                        center.dismiss(toast.id)
                    } catch { /* Hovering, hiding, or eviction cancels expiration. */ }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86),
                   value: isExpanded)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86),
                   value: center.items.map(\.id))
        // Reflow starts with the fade, not after the outgoing surface is removed.
        .animation(.easeInOut(duration: Toast.dismissalDuration),
                   value: center.items.filter(\.isDismissing).map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
        .accessibilityAction(named: isExpandedByKeyboard ? "Collapse notifications" : "Expand notifications") {
            isExpandedByKeyboard.toggle()
        }
        .onChange(of: center.items.isEmpty) { _, empty in
            if empty { isHovering = false; isExpandedByKeyboard = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .beatSnapPanelShown)) { _ in
            isWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object is BeatPanel { isWindowVisible = false; isHovering = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in
            if note.object is BeatPanel { isWindowVisible = false; isHovering = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { note in
            if note.object is BeatPanel { isWindowVisible = true }
        }
    }
}

private struct ToastBlur: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

private struct ToastSlot: Equatable {
    let id: Toast.ID
    let isDismissing: Bool
}

private struct ToastSlotKey: LayoutValueKey {
    static let defaultValue: ToastSlot? = nil
}

/// Measures each card's text instead of reserving space for a worst-case message. The
/// newest card stays anchored to the window bottom throughout expansion and collapse.
private struct ToastStackLayout: Layout {
    struct Cache {
        // Bottom-relative frames preserve each outgoing card's position even while the
        // stack's height shrinks and its overlay moves down to remain bottom-aligned.
        var frames: [Toast.ID: CGRect] = [:]
    }

    var expansion: CGFloat
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let ids = Set(subviews.compactMap { $0[ToastSlotKey.self]?.id })
        cache.frames = cache.frames.filter { ids.contains($0.key) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = subviews.filter { $0[ToastSlotKey.self]?.isDismissing != true }
            .map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        guard let newest = sizes.last else {
            // Keep the final outgoing surface at full width while freeing its height.
            return CGSize(width: proposal.width ?? cache.frames.values.map(\.width).max() ?? 0,
                          height: 0)
        }
        let gaps = CGFloat(sizes.count - 1) * 8
        let collapsed = newest.height + gaps
        let expanded = sizes.reduce(0) { $0 + $1.height } + gaps
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: collapsed + (expanded - collapsed) * expansion)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let active = subviews.filter { $0[ToastSlotKey.self]?.isDismissing != true }
        let sizes = active.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        var expandedY = bounds.height
        for index in active.indices.reversed() {
            let subview = active[index]
            let newest = sizes[sizes.count - 1]
            expandedY -= sizes[index].height
            let depth = active.count - 1 - index
            let collapsedY = bounds.height - newest.height - CGFloat(depth) * 8
            let y = collapsedY + (expandedY - collapsedY) * expansion
            let height = newest.height + (sizes[index].height - newest.height) * expansion
            if let slot = subview[ToastSlotKey.self] {
                cache.frames[slot.id] = CGRect(x: 0, y: y - bounds.height, width: bounds.width, height: height)
            }
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            expandedY -= 8
        }
        for subview in subviews {
            guard let slot = subview[ToastSlotKey.self], slot.isDismissing else { continue }
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let frame = cache.frames[slot.id]
                ?? CGRect(x: 0, y: -size.height, width: bounds.width, height: size.height)
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.maxY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: frame.height))
        }
    }
}

private struct ToastCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let toast: Toast
    let dismiss: () -> Void

    // macOS 26 resolves these against the window/container, subtracting the toast inset.
    // Detached cards retain a soft minimum radius as the stack fans out upward.
    private var shape: ConcentricRectangle { .init(corners: .concentric(minimum: .fixed(10))) }

    // An explicit color avoids hierarchical secondary styling being dimmed again
    // by the glass material over the black dark-mode surface.
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color(white: 0.85) : .secondary
    }

    private var tint: Color {
        switch toast.kind {
        case .error: Color(red: 0.88, green: 0.12, blue: 0.19)
        case .info: Color(red: 0.04, green: 0.36, blue: 0.96)
        case .success: Color(red: 0.05, green: 0.58, blue: 0.34)
        }
    }

    private var symbol: String {
        switch toast.kind {
        case .error: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(toast.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss \(toast.title)")
            .help("Dismiss notification")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(colorScheme == .dark ? .black.opacity(0.8) : .white.opacity(0.8)), in: shape)
        .background {
            shape.fill(colorScheme == .dark ? Color.black : Color.white)
        }
        .overlay {
            shape.stroke(colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.16),
                               lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        // Composite each complete surface before shadowing it so the shadow sits
        // over older cards. The upward contact shadow defines the narrow shoulders
        // of the collapsed stack without a heavy halo around the whole stack.
        .compositingGroup()
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 2, y: -1)
        .shadow(color: .black.opacity(0.06), radius: 7, y: 2)
        .help("\(toast.title)\n\(toast.message)")
    }
}
