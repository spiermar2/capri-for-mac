import AppKit
import CoreGraphics

/// Geometry is kept separate so display layouts and edge occlusion can be
/// checked without observing or moving any real application windows.
enum WindowInteractionGeometry {
    struct Span: Equatable {
        var lower: CGFloat
        var upper: CGFloat
        var width: CGFloat { max(0, upper - lower) }
        func contains(_ x: CGFloat) -> Bool { x >= lower && x <= upper }
        func clamped(_ x: CGFloat) -> CGFloat { min(upper, max(lower, x)) }
    }

    static func appKitRect(fromQuartz rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func subtract(_ obstruction: Span, from spans: [Span]) -> [Span] {
        spans.flatMap { span -> [Span] in
            guard obstruction.upper > span.lower, obstruction.lower < span.upper else { return [span] }
            var pieces: [Span] = []
            if obstruction.lower > span.lower { pieces.append(Span(lower: span.lower, upper: min(span.upper, obstruction.lower))) }
            if obstruction.upper < span.upper { pieces.append(Span(lower: max(span.lower, obstruction.upper), upper: span.upper)) }
            return pieces
        }
    }

    /// Each returned interval describes safe *anchor centers*, not whole edges.
    static func usableTopSpans(window: CGRect, screen: CGRect, occluders: [CGRect],
                               bodyWidth: CGFloat, headClearance: CGFloat) -> [Span] {
        let top = window.maxY
        guard window.width >= 160, window.height >= 100,
              top >= screen.minY + 24, top + headClearance <= screen.maxY + 1 else { return [] }
        let left = max(window.minX, screen.minX)
        let right = min(window.maxX, screen.maxX)
        guard right > left else { return [] }
        var spans = [Span(lower: left, upper: right)]
        for rect in occluders where rect.minY < top + 2 && rect.maxY > top - 2 {
            spans = subtract(Span(lower: rect.minX - 3, upper: rect.maxX + 3), from: spans)
        }
        let margin = max(12, bodyWidth / 2) + 6
        return spans.compactMap { span in
            guard span.width >= margin * 2 else { return nil }
            return Span(lower: span.lower + margin, upper: span.upper - margin)
        }
    }

    static func floorScreen(for point: CGPoint, screens: [CGRect]) -> CGRect? {
        if let screen = screens.first(where: { $0.contains(point) }) { return screen }
        return screens.min { a, b in
            distanceSquared(point, to: a) < distanceSquared(point, to: b)
        }
    }

    static func followedOrigin(window: CGRect?, fraction: CGFloat, spans: [Span], anchor: CGPoint) -> CGPoint? {
        guard let window, !spans.isEmpty else { return nil }
        let desiredX = window.minX + window.width * min(1, max(0, fraction))
        guard let span = spans.min(by: { abs($0.clamped(desiredX) - desiredX) < abs($1.clamped(desiredX) - desiredX) }) else { return nil }
        return CGPoint(x: span.clamped(desiredX) - anchor.x, y: window.maxY - anchor.y)
    }

    static func floorOrigin(for foot: CGPoint, screens: [CGRect], bodyWidth: CGFloat, anchor: CGPoint) -> CGPoint? {
        guard let screen = floorScreen(for: foot, screens: screens) else { return nil }
        let margin = min(screen.width / 2, max(12, bodyWidth / 2))
        let x = min(screen.maxX - margin, max(screen.minX + margin, foot.x))
        return CGPoint(x: x - anchor.x, y: screen.minY - anchor.y)
    }

    private static func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// A titleless, read-only view of window geometry. This controller only moves
/// Capri through its callbacks; it never captures pixels, focuses applications,
/// or changes another application's windows.
@MainActor
final class WindowInteractionController {
    var onPosition: ((NSPoint) -> Void)?
    var onPerchedChanged: ((Bool) -> Void)?

    var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled { detach(preserveContact: true); falling = false; floorLocked = false }
            updateTimers()
        }
    }
    var motionEnabled = true
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            updateTimers()
            if !isSuspended { refreshWindows() }
        }
    }
    private(set) var isPerched = false

    private struct WindowRecord {
        let id: CGWindowID
        let owner: pid_t
        let rect: CGRect
    }
    private struct Surface {
        let window: WindowRecord
        let span: WindowInteractionGeometry.Span
        var top: CGFloat { window.rect.maxY }
    }
    private struct Attachment {
        let id: CGWindowID
        let owner: pid_t
        var fraction: CGFloat
    }

    private var standingAnchor = NSPoint(x: 190, y: 74)
    private var seatingAnchor = NSPoint(x: 190, y: 154)
    private var bodyWidth: CGFloat = 100
    private var headClearance: CGFloat = 150
    private var panelOrigin = NSPoint.zero
    private var currentSurfaces: [Surface] = []
    private var screenFrames: [CGRect] = []
    private var attachment: Attachment?
    private var lastExternalPID: pid_t?
    private var started = false
    private var dragging = false
    private var falling = false
    private var floorLocked = false
    private var fallVelocity: CGFloat = 0
    private var sampleTimer: Timer?
    private var physicsTimer: Timer?
    private var lastStep = ProcessInfo.processInfo.systemUptime
    private var workspaceObservers: [NSObjectProtocol] = []
    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private var running: Bool { started && enabled && !isSuspended }
    private var reducedMotion: Bool { !motionEnabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    isolated deinit {
        sampleTimer?.invalidate()
        physicsTimer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func configure(standingAnchor: NSPoint, seatingAnchor: NSPoint,
                   bodyWidth: CGFloat, headClearance: CGFloat) {
        let oldAnchor = isPerched ? self.seatingAnchor : self.standingAnchor
        let newAnchor = isPerched ? seatingAnchor : standingAnchor
        self.standingAnchor = standingAnchor
        self.seatingAnchor = seatingAnchor
        self.bodyWidth = max(24, bodyWidth)
        self.headClearance = max(24, headClearance)
        if isPerched || floorLocked {
            move(to: NSPoint(x: panelOrigin.x + oldAnchor.x - newAnchor.x,
                             y: panelOrigin.y + oldAnchor.y - newAnchor.y))
        }
        if running { refreshWindows() }
    }

    /// Called for deliberate moves such as summon or dragging. Positions emitted
    /// by `onPosition` must not be fed back into this method.
    func setPanelOrigin(_ origin: NSPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        panelOrigin = origin
        detach()
        falling = false
        floorLocked = false
        updatePhysicsTimer()
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindows() }
            })
        }
        updateTimers()
        refreshWindows()
    }

    func stop() {
        started = false
        sampleTimer?.invalidate(); sampleTimer = nil
        physicsTimer?.invalidate(); physicsTimer = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        falling = false
        floorLocked = false
        detach(preserveContact: true)
    }

    func beginDragging() {
        dragging = true
        falling = false
        floorLocked = false
        detach()
        updatePhysicsTimer()
    }

    func endDragging(at origin: NSPoint) {
        panelOrigin = origin
        dragging = false
        guard running else { return }
        refreshWindows()
        let seat = world(seatingAnchor)
        // A small magnetic zone makes an intentional drop onto a title bar easy.
        if let surface = landingSurfaces().filter({ abs($0.top - seat.y) <= 40 &&
            abs($0.span.clamped(seat.x) - seat.x) <= 28
        }).min(by: { abs($0.top - seat.y) < abs($1.top - seat.y) }) {
            attach(to: surface, x: surface.span.clamped(seat.x))
        } else {
            beginFall()
        }
    }

    /// Explicit menu action. Returns false when the active app has no visible
    /// window edge with enough space above it for Capri's head.
    @discardableResult
    func perchOnFrontmostWindow() -> Bool {
        guard running, !dragging else { return false }
        refreshWindows()
        guard let surface = landingSurfaces().first else { return false }
        attach(to: surface, x: surface.span.clamped(world(standingAnchor).x))
        return true
    }

    private func updateTimers() {
        sampleTimer?.invalidate(); sampleTimer = nil
        if running {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindows() }
            }
            timer.tolerance = 0.025
            RunLoop.main.add(timer, forMode: .common)
            sampleTimer = timer
        }
        updatePhysicsTimer()
    }

    private func updatePhysicsTimer() {
        guard running, falling, !dragging, !screenFrames.isEmpty else {
            physicsTimer?.invalidate(); physicsTimer = nil
            return
        }
        guard physicsTimer == nil else { return }
        lastStep = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFall() }
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        physicsTimer = timer
    }

    private func refreshWindows() {
        guard running else { return }
        let screens = NSScreen.screens
        screenFrames = screens.map(\.visibleFrame)
        updatePhysicsTimer()
        // `screens.first` is the primary/menu-bar display. NSScreen.main can
        // switch when focus moves and therefore cannot define Quartz's origin.
        guard let primaryTop = screens.first?.frame.maxY else { return }
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != selfPID, app.activationPolicy == .regular {
            lastExternalPID = app.processIdentifier
        }
        guard let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            currentSurfaces = []
            if attachment != nil { detachAndFall() }
            return
        }
        var records: [WindowRecord] = []
        for item in descriptions {
            // Intentionally read only these four fields. Window titles, owner
            // names, pixel content, and accessibility elements are never read.
            guard let layer = item[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let owner = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let id = item[kCGWindowNumber as String] as? NSNumber,
                  owner.int32Value != selfPID,
                  let rawBounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let quartzRect = CGRect(dictionaryRepresentation: rawBounds),
                  quartzRect.width > 1, quartzRect.height > 1,
                  quartzRect.minX.isFinite, quartzRect.minY.isFinite,
                  quartzRect.width.isFinite, quartzRect.height.isFinite else { continue }
            let rect = WindowInteractionGeometry.appKitRect(fromQuartz: quartzRect, primaryTop: primaryTop)
            records.append(WindowRecord(id: id.uint32Value, owner: owner.int32Value, rect: rect))
        }
        var occluders: [CGRect] = []
        var surfaces: [Surface] = []
        for record in records {
            let relevantOwner = record.owner == lastExternalPID || record.owner == attachment?.owner
            if relevantOwner,
               NSRunningApplication(processIdentifier: record.owner)?.activationPolicy == .regular {
                for screen in screenFrames {
                    for span in WindowInteractionGeometry.usableTopSpans(window: record.rect, screen: screen,
                        occluders: occluders, bodyWidth: bodyWidth, headClearance: headClearance) {
                        surfaces.append(Surface(window: record, span: span))
                    }
                }
            }
            occluders.append(record.rect)
        }
        currentSurfaces = surfaces
        if !dragging, let attached = attachment {
            let choices = surfaces.filter { $0.window.id == attached.id && $0.window.owner == attached.owner }
            if let origin = WindowInteractionGeometry.followedOrigin(window: choices.first?.window.rect,
                fraction: attached.fraction, spans: choices.map(\.span), anchor: seatingAnchor) {
                move(to: origin)
            } else { detachAndFall() }
        } else if floorLocked, !dragging, !falling {
            settleOnFloor()
        }
    }

    private func landingSurfaces() -> [Surface] {
        currentSurfaces.filter { $0.window.owner == lastExternalPID }
    }

    private func attach(to surface: Surface, x: CGFloat) {
        falling = false
        floorLocked = false
        fallVelocity = 0
        attachment = Attachment(id: surface.window.id, owner: surface.window.owner,
            fraction: min(1, max(0, (x - surface.window.rect.minX) / surface.window.rect.width)))
        setPerched(true)
        move(to: NSPoint(x: x - seatingAnchor.x, y: surface.top - seatingAnchor.y))
        updatePhysicsTimer()
    }

    private func detach(preserveContact: Bool = false) {
        let contact = isPerched && preserveContact ? world(seatingAnchor) : nil
        attachment = nil
        setPerched(false)
        if let contact {
            move(to: NSPoint(x: contact.x - standingAnchor.x, y: contact.y - standingAnchor.y))
        }
    }

    private func detachAndFall() {
        detach(preserveContact: true)
        beginFall()
    }

    private func setPerched(_ value: Bool) {
        guard isPerched != value else { return }
        isPerched = value
        onPerchedChanged?(value)
    }

    private func beginFall() {
        guard running, !dragging else { return }
        detach()
        falling = true
        floorLocked = false
        fallVelocity = 0
        if reducedMotion { settleImmediately() } else { updatePhysicsTimer() }
    }

    private func stepFall() {
        guard running, falling, !dragging else { updatePhysicsTimer(); return }
        if reducedMotion { settleImmediately(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.08, max(0.001, now - lastStep)))
        lastStep = now
        let foot = world(standingAnchor)
        guard let screen = WindowInteractionGeometry.floorScreen(for: foot, screens: screenFrames) else { updatePhysicsTimer(); return }
        let margin = max(12, bodyWidth / 2)
        let x = min(screen.maxX - margin, max(screen.minX + margin, foot.x))
        fallVelocity = min(1300, fallVelocity + 1500 * dt)
        let nextY = foot.y - fallVelocity * dt
        if let surface = landingSurfaces().filter({ $0.span.contains(x) && $0.top <= foot.y + 1 && $0.top >= nextY }).max(by: { $0.top < $1.top }) {
            attach(to: surface, x: x)
        } else if nextY <= screen.minY {
            settleOnFloor(screen: screen, x: x)
        } else {
            move(to: NSPoint(x: x - standingAnchor.x, y: nextY - standingAnchor.y))
        }
    }

    private func settleImmediately() {
        let foot = world(standingAnchor)
        if let surface = landingSurfaces().filter({ $0.span.contains(foot.x) && $0.top <= foot.y + 1 }).max(by: { $0.top < $1.top }) {
            attach(to: surface, x: foot.x)
        } else { settleOnFloor() }
    }

    private func settleOnFloor(screen given: CGRect? = nil, x givenX: CGFloat? = nil) {
        let foot = world(standingAnchor)
        guard let screen = given ?? WindowInteractionGeometry.floorScreen(for: foot, screens: screenFrames) else { return }
        guard let origin = WindowInteractionGeometry.floorOrigin(for: CGPoint(x: givenX ?? foot.x, y: foot.y),
            screens: [screen], bodyWidth: bodyWidth, anchor: standingAnchor) else { return }
        detach()
        falling = false
        floorLocked = true
        fallVelocity = 0
        move(to: origin)
        updatePhysicsTimer()
    }

    private func world(_ anchor: NSPoint) -> NSPoint {
        NSPoint(x: panelOrigin.x + anchor.x, y: panelOrigin.y + anchor.y)
    }

    private func move(to origin: NSPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        panelOrigin = origin
        onPosition?(origin)
    }
}
