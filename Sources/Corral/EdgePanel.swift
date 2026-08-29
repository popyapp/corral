import AppKit
import Combine
import SwiftUI

/// The panel that grows out of the edge of the screen.
///
/// Corral's window answers "what is running and what should I do about it".
/// This answers the smaller question you have twenty times a day — how much
/// have I got left — and it has to answer it without being opened, moved or
/// arranged.
///
/// It is one window in two sizes, not two windows. Closed it is a strip or a
/// line; opening grows the same shape. That matters more than it sounds: two
/// windows would have to be kept in step, and the moment they drifted apart the
/// illusion that this is one object attached to the screen would be gone.
///
/// AppKit rather than a SwiftUI `Scene`, for three reasons that come from the
/// same place. It must not take focus from whatever you are typing in, which
/// needs a non-activating panel. It must sit over other apps on every desktop
/// and above the menu bar, which needs a window level and a collection
/// behaviour no `Scene` exposes. And it must survive its own app being hidden,
/// which needs `canHide` turned off.
@MainActor
final class EdgePanelController {
    static let shared = EdgePanelController()

    /// Above other apps' floating windows, not merely above their documents.
    /// `.floating` is what a palette in *your own* app uses; a strip meant to be
    /// readable while you work in an editor has to outrank the editor's own
    /// panels.
    private static let level = NSWindow.Level.statusBar

    /// How long the rail takes to open, and how long the pointer is ignored
    /// for afterwards. One number, because they have to be the same number:
    /// see `beginSettling`.
    private static let openDuration: TimeInterval = 0.24
    private static let settleDelay: TimeInterval = openDuration + 0.12

    private var window: HUDPanel?
    private var hosting: NSHostingView<AnyView>?
    private var interceptor: ClickInterceptor?
    private var railTracker: RailInterceptor?

    private var popover: NSPanel?
    private var popoverHost: NSHostingView<AnyView>?

    /// A ring whose popover was clicked open, and so stays when the pointer
    /// leaves. Without it the panel can only be read with the mouse held still.
    private var pinned: Int?
    /// Which ring the popover is describing.
    private var hoveredIndex: Int?
    /// Pending collapse, cancelled if the pointer comes back.
    private var collapseWork: DispatchWorkItem?
    /// True while the rail is still growing. See `beginSettling`.
    private var settling = false
    private var settleWork: DispatchWorkItem?

    private var model: CorralViewModel?
    private var anchor: HUDAnchor = .top
    private var expanded = false
    private var cancellables = Set<AnyCancellable>()
    private let dismissal = PanelDismissal()
    /// When the panel last closed. See `toggle`.
    private var collapsedAt: Date = .distantPast

    private init() {}

    func apply(model: CorralViewModel) {
        self.model = model

        PanelSettings.shared.$placement
            .removeDuplicates()
            .sink { [weak self] placement in
                guard let anchor = placement.anchor else { return self?.tearDown() ?? () }
                self?.install(anchor: anchor, model: model)
            }
            .store(in: &cancellables)

        // The screen can be unplugged, resized, or gain a Dock along the edge
        // the panel is sitting on.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout(animated: false) }
            .store(in: &cancellables)

        // The strip carries a live number, so it is redrawn as the inventory
        // moves — which it does every couple of seconds.
        model.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    // ─ Building ─────────────────────────────────────────────────────────────

    private func install(anchor: HUDAnchor, model: CorralViewModel) {
        self.anchor = anchor
        expanded = false
        pinned = nil
        hoveredIndex = nil

        detachInterceptor()
        railTracker?.removeFromSuperview()
        railTracker = nil

        if window == nil {
            let panel = HUDPanel(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // No window shadow. The panel is pretending to be part of the
            // bezel, and a shadow where it meets the screen edge is the one
            // thing that would give it away as a rectangle sitting in front.
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = Self.level
            panel.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
            ]
            // Cmd-H must not take it away. Hiding Corral is how you get its
            // window out of the way; the point of this strip is that it stays.
            panel.canHide = false
            panel.delegate = dismissal
            dismissal.onResign = { [weak self] in self?.collapse() }

            let host = NSHostingView(rootView: AnyView(EmptyView()))
            panel.contentView = host
            hosting = host
            window = panel
        }

        render()
        layout(animated: false)
        switch anchor {
        case .top: attachInterceptor()
        case .right: attachRailTracker(model: model)
        }
        window?.orderFront(nil)
    }

    private func tearDown() {
        hidePopover()
        popover = nil
        popoverHost = nil
        window?.orderOut(nil)
        window = nil
        hosting = nil
        interceptor = nil
        railTracker = nil
        pinned = nil
        hoveredIndex = nil
        expanded = false
    }

    /// Draw the current state. Deliberately does *not* lay out — see `refresh`.
    private func render() {
        guard let hosting, let model else { return }
        switch anchor {
        case .top:
            hosting.rootView = AnyView(
                HUDPanelView(anchor: .top, expanded: expanded).environmentObject(model)
            )
        case .right:
            hosting.rootView = AnyView(
                RailView(hovering: hoveredIndex, expanded: expanded)
                    .environmentObject(model)
            )
            railTracker?.count = model.vendorUsages.count
        }
    }

    /// Redraw on the inventory's clock, and resize only if the size changed.
    ///
    /// `render` used to lay out as well, which quietly finished every animation
    /// before it began: opening and closing each set the frame instantly and
    /// then asked to animate to a frame the window had already reached.
    private func refresh() {
        render()
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let target = frame(on: screen)
        guard target.size != window.frame.size else { return }
        window.setFrame(target, display: true)
    }

    // ─ The rail: a line until you go near it ────────────────────────────────

    /// The pointer arrived. Open.
    private func railEntered() {
        collapseWork?.cancel()
        guard anchor == .right, !expanded else { return }
        expanded = true
        hoveredIndex = nil
        hidePopover()
        render()
        layout(animated: true)
        beginSettling()
    }

    /// Ignore the pointer until the rail has stopped moving.
    ///
    /// Opening puts rings underneath a pointer that never moved, so a popover
    /// appears immediately — and it is placed against a frame that is still
    /// growing, so the next event corrects it and the whole card jumps across
    /// the screen. Nothing is shown until the geometry is final. Then whichever
    /// ring the pointer is genuinely over is picked up, from where the mouse
    /// actually is rather than from an event that predates the resize.
    private func beginSettling() {
        settling = true
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settling = false
            self.hover(self.railTracker?.indexUnderPointer())
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// It left. Close, but not immediately.
    ///
    /// A short grace is the difference between a panel and a flicker: the
    /// pointer crosses the edge of a five-point line on the way to almost
    /// anything, and closing on the first frame outside would snap the rail
    /// shut while somebody was still arriving at it.
    private func railExited() {
        collapseWork?.cancel()
        // A pinned popover means somebody is reading it.
        guard pinned == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapseRail() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func collapseRail() {
        guard anchor == .right, expanded else { return }
        settleWork?.cancel()
        settling = false
        expanded = false
        hoveredIndex = nil
        hidePopover()
        render()
        layout(animated: true)
    }

    // ─ The popover beside a ring ────────────────────────────────────────────

    private func hover(_ index: Int?) {
        // While it is still a line there are no rings to be over, and while it
        // is still growing there is nowhere stable to put a popover.
        guard expanded, !settling else { return }
        // A pinned ring outlasts the pointer. Moving over another ring still
        // switches to it — pinning holds the panel open, it does not lock it.
        hoveredIndex = index ?? pinned
        render()
        show(ring: hoveredIndex)
    }

    private func click(_ index: Int?) {
        guard expanded else { return railEntered() }
        // Somebody who clicked has decided; they should not be made to wait out
        // an animation that is only there to stop the panel jumping.
        settleWork?.cancel()
        settling = false
        guard let index else {
            pinned = nil
            hover(nil)
            return
        }
        pinned = (pinned == index) ? nil : index
        hover(index)
    }

    private func show(ring index: Int?) {
        guard anchor == .right, let index else { return hidePopover() }
        guard let model, let rail = window, index < model.vendorUsages.count
        else { return hidePopover() }
        let usage = model.vendorUsages[index]

        if popover == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = Self.level
            panel.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
            ]
            panel.canHide = false
            // It is a tooltip, not a surface. Letting it take the mouse would
            // mean tracking the pointer across the gap between two windows, and
            // every version of that reads to the user as flicker.
            panel.ignoresMouseEvents = true

            let host = NSHostingView(rootView: AnyView(EmptyView()))
            panel.contentView = host
            popoverHost = host
            popover = panel
        }

        popoverHost?.rootView = AnyView(
            UsagePopoverView(usage: usage).environmentObject(model)
        )
        guard let popover, let host = popoverHost else { return }

        let height = max(host.fittingSize.height, 60)
        // The ring's middle, measured down from the top of the rail and turned
        // back into a screen coordinate, which runs the other way.
        let centre = rail.frame.maxY - RailLayout.centre(of: index)
        let screen = (rail.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let top = min(max(centre - height / 2, screen.minY + 8), screen.maxY - height - 8)

        popover.setFrame(
            NSRect(
                x: rail.frame.minX - UsagePopoverView.totalWidth - 2,
                y: top,
                width: UsagePopoverView.totalWidth,
                height: height
            ),
            display: true
        )
        popover.orderFront(nil)
    }

    private func hidePopover() {
        popover?.orderOut(nil)
    }

    // ─ The strip at the top: click to open ──────────────────────────────────

    /// Clicking the strip opens the panel, and clicking it again closes it.
    ///
    /// The second half needs help. Clicking the strip while the panel is open
    /// takes key status away from it first, so it has already closed by the
    /// time the click arrives here — "is it open" answers no, and the click
    /// reopens what it was meant to dismiss. The panel is treated as still open
    /// for long enough to swallow the click that closed it.
    func toggle() {
        guard anchor == .top else { return }
        if expanded {
            collapse()
            return
        }
        guard Date().timeIntervalSince(collapsedAt) > 0.3 else { return }
        expand()
    }

    func expand() {
        guard window != nil, anchor == .top else { return }
        expanded = true
        render()
        layout(animated: true)
        detachInterceptor()
        // Key only while open: that is what makes clicking elsewhere close it.
        // Closed it never asks, so it never takes focus from your editor.
        window?.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        guard expanded, anchor == .top else { return }
        expanded = false
        collapsedAt = Date()
        render()
        layout(animated: true)
        attachInterceptor()
        window?.resignKey()
    }

    /// Summoned from a menu, from an app that may not be frontmost.
    func reveal() {
        if PanelSettings.shared.placement == .off {
            PanelSettings.shared.placement = .top
        }
        anchor == .right ? railEntered() : expand()
    }

    // ─ Mouse handling ───────────────────────────────────────────────────────

    /// A transparent AppKit view over the closed strip.
    ///
    /// It exists only while closed, and swallows every mouse event so the strip
    /// behaves as one object: one click opens it, one drag moves it. Open, it is
    /// taken away and SwiftUI gets the mouse back — a panel of scrolling content
    /// cannot sit under something that eats clicks.
    private func attachInterceptor() {
        guard let window, interceptor == nil else { return }
        let view = ClickInterceptor()
        view.onClick = { [weak self] in self?.toggle() }
        view.onDrag = { [weak self] in self?.rememberPosition() }
        view.axis = anchor
        view.frame = window.contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        interceptor = view
    }

    private func detachInterceptor() {
        interceptor?.removeFromSuperview()
        interceptor = nil
    }

    /// The rail's pointer tracking, which has to keep working while another app
    /// is frontmost — see `RailInterceptor`.
    private func attachRailTracker(model: CorralViewModel) {
        guard let window, railTracker == nil else { return }
        // Tracking areas that ask for `.mouseMoved` still need the window to be
        // willing to deliver them.
        window.acceptsMouseMovedEvents = true

        let view = RailInterceptor()
        view.count = model.vendorUsages.count
        view.onEnter = { [weak self] in self?.railEntered() }
        view.onExit = { [weak self] in self?.railExited() }
        view.onHover = { [weak self] index in self?.hover(index) }
        view.onClick = { [weak self] index in self?.click(index) }
        view.onDrag = { [weak self] _ in self?.hidePopover() }
        view.onDrop = { [weak self] in self?.rememberPosition() }
        view.frame = window.contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        railTracker = view
    }

    // ─ Placement ────────────────────────────────────────────────────────────

    private func layout(animated: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let frame = self.frame(on: screen)
        guard animated else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.openDuration
            // Just past its own end and back. AppKit has no spring, and a
            // control point above 1 is what overshoot there is — enough to give
            // the edge some life, not so much that it bounces like a toy.
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22, 1.18, 0.42, 1
            )
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Everything is measured off `visibleFrame` rather than `frame`.
    ///
    /// `frame` is the glass; `visibleFrame` is what is left after the menu bar
    /// and the Dock. Pinning to the glass would put the panel underneath a Dock
    /// that happens to live on the same edge — visible, and unclickable.
    private func frame(on screen: NSScreen) -> NSRect {
        let size = HUDMetrics.size(
            anchor: anchor,
            expanded: expanded,
            rings: model?.vendorUsages.count ?? 1,
            on: screen
        )
        let glass = screen.frame
        let usable = screen.visibleFrame
        let position = PanelSettings.shared.position

        switch anchor {
        case .top:
            // Pinned to the glass, not to `visibleFrame`: the panel is meant to
            // start where the bezel does and hang down over the menu bar. That
            // is the whole effect.
            let travel = max(0, usable.width - size.width)
            return NSRect(
                x: usable.minX + travel * position,
                y: glass.maxY - size.height,
                width: size.width,
                height: size.height
            )

        case .right:
            // The glass edge too, unless something is parked on it.
            let edge = usable.maxX < glass.maxX ? usable.maxX : glass.maxX
            // Anchored by its middle, not its top: the line and the open rail
            // are different heights, and growing downward from a fixed top
            // would read as the panel sliding rather than opening.
            let centre = usable.maxY - RailLayout.railMargin
                - (usable.height - RailLayout.railMargin * 2) * position
            let y = min(
                max(centre - size.height / 2, usable.minY),
                usable.maxY - size.height
            )
            return NSRect(x: edge - size.width, y: y, width: size.width, height: size.height)
        }
    }

    /// Store where along its edge the panel was dropped.
    private func rememberPosition() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let usable = screen.visibleFrame
        let frame = window.frame

        let fraction: Double
        switch anchor {
        case .top:
            let travel = usable.width - frame.width
            guard travel > 0 else { return }
            fraction = (frame.minX - usable.minX) / travel
        case .right:
            let travel = usable.height - RailLayout.railMargin * 2
            guard travel > 0 else { return }
            fraction = (usable.maxY - RailLayout.railMargin - frame.midY) / travel
        }
        PanelSettings.shared.position = min(max(fraction, 0), 1)
    }
}

// ─ Sizes ────────────────────────────────────────────────────────────────────

enum HUDMetrics {
    static func size(
        anchor: HUDAnchor, expanded: Bool, rings: Int, on screen: NSScreen
    ) -> CGSize {
        let usable = screen.visibleFrame
        switch anchor {
        case .top:
            return expanded
                ? CGSize(width: 420, height: min(430, usable.height - 60))
                : CGSize(width: 268, height: 40)

        case .right:
            // Closed, it is a line on the edge of the screen. That is how it
            // sits for nearly all of its life, and the width it grows *from* is
            // what makes opening read as coming out of the side rather than
            // appearing in place.
            guard expanded else { return CGSize(width: 5, height: 110) }
            return CGSize(
                width: RailView.width,
                height: min(RailView.height(for: rings), usable.height - 40)
            )
        }
    }
}

// ─ Windows ──────────────────────────────────────────────────────────────────

/// A borderless panel that can take the keyboard when it is asked to.
///
/// Borderless windows refuse key status by default, and this one needs it for
/// exactly one reason: losing it is how the open panel knows to close. It is
/// only ever *asked* while open, so the closed strip never takes focus.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Escape closes it, the way every other transient panel on the system does.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { EdgePanelController.shared.collapse() }
    }
}

private final class PanelDismissal: NSObject, NSWindowDelegate {
    var onResign: (() -> Void)?

    func windowDidResignKey(_ notification: Notification) {
        onResign?()
    }
}

/// Pointer tracking for the rail.
///
/// This exists because of one flag. SwiftUI's `onHover` installs a tracking
/// area that is live only while its own app is frontmost, and the rail's whole
/// purpose is to be readable *while you are working somewhere else*. An
/// `.activeAlways` tracking area is the difference between a rail that responds
/// and one that appears broken — which is exactly how it appeared.
private final class RailInterceptor: NSView {
    var count = 0
    /// The pointer arriving on the rail and leaving it, which is what opens and
    /// closes it. Separate from `onHover`, because a rail that is still a line
    /// has no rings to be over.
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    /// The ring under the pointer, or nil when there is none.
    var onHover: (Int?) -> Void = { _ in }
    /// A click on a ring, which pins its popover open.
    var onClick: (Int?) -> Void = { _ in }
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDrop: () -> Void = {}

    /// Top-down, so the arithmetic in `RailLayout` reads the same here as it
    /// does in the SwiftUI that drew it.
    override var isFlipped: Bool { true }

    private static let dragThreshold: CGFloat = 3

    private var tracker: NSTrackingArea?
    private var current: Int?
    private var grabbedAt: NSPoint = .zero
    private var originAtGrab: NSPoint = .zero
    private var moved = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracker { removeTrackingArea(tracker) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracker = area
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { onEnter() }
        report(event)
    }

    override func mouseMoved(with event: NSEvent) { report(event) }

    override func mouseExited(with event: NSEvent) {
        current = nil
        MainActor.assumeIsolated {
            onHover(nil)
            onExit()
        }
    }

    /// The ring under the pointer right now.
    ///
    /// Computed from the live mouse position rather than the last event, which
    /// may predate the rail resizing underneath a pointer that never moved —
    /// the event that opened the rail was measured against a five-point line.
    func indexUnderPointer() -> Int? {
        guard let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard bounds.contains(local) else { return nil }
        current = RailLayout.index(atDepth: local.y, count: count)
        return current
    }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = RailLayout.index(atDepth: point.y, count: count)
        // Only on a change: this fires on every pixel of movement, and
        // rebuilding the popover each time would make it flicker.
        guard index != current else { return }
        current = index
        MainActor.assumeIsolated { onHover(index) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        grabbedAt = NSEvent.mouseLocation
        originAtGrab = window.frame.origin
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let travelled = NSEvent.mouseLocation.y - grabbedAt.y
        if abs(travelled) > Self.dragThreshold { moved = true }
        guard moved else { return }

        let usable = screen.visibleFrame
        var frame = window.frame
        frame.origin.y = min(
            max(originAtGrab.y + travelled, usable.minY),
            usable.maxY - frame.height
        )
        window.setFrame(frame, display: true)
        MainActor.assumeIsolated { onDrag(0) }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            if moved {
                onDrop()
            } else {
                onClick(RailLayout.index(
                    atDepth: convert(event.locationInWindow, from: nil).y, count: count
                ))
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Click and drag for the closed strip at the top.
private final class ClickInterceptor: NSView {
    var onClick: () -> Void = {}
    /// Called once when the strip is let go, to persist where it landed.
    var onDrag: () -> Void = {}
    /// The strip slides along the edge it is attached to, and only along it.
    /// One that could be dragged into the middle of the screen would be an
    /// ordinary floating window with extra steps.
    var axis: HUDAnchor = .top

    /// Below this, a mouse-up is a click. Above it, the gesture was a move and
    /// must not also open the panel — dragging the strip out of the way would
    /// otherwise leave the panel open in front of you.
    private static let dragThreshold: CGFloat = 3

    private var grabbedAt: NSPoint = .zero
    private var originAtGrab: NSPoint = .zero
    private var moved = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        grabbedAt = NSEvent.mouseLocation
        originAtGrab = window.frame.origin
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let now = NSEvent.mouseLocation
        let delta = CGPoint(x: now.x - grabbedAt.x, y: now.y - grabbedAt.y)
        if max(abs(delta.x), abs(delta.y)) > Self.dragThreshold { moved = true }
        guard moved else { return }

        let usable = screen.visibleFrame
        var frame = window.frame
        switch axis {
        case .top:
            frame.origin.x = min(
                max(originAtGrab.x + delta.x, usable.minX),
                usable.maxX - frame.width
            )
        case .right:
            frame.origin.y = min(
                max(originAtGrab.y + delta.y, usable.minY),
                usable.maxY - frame.height
            )
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        moved ? onDrag() : onClick()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Five points of colour cannot explain themselves, and the drag is the
    /// half nobody would think to try.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        toolTip = "Corral usage — click to open, drag to move"
    }
}
