import AppKit
import ImageIO

/// Native renderer for Capri's published full-body strips and original show art.
/// All interaction callbacks run on the main thread. `onMove` uses screen points
/// (positive y is up), so moving the panel does not change the next drag delta.
@MainActor
final class CharacterView: NSView {
    enum Presentation { case standing, dormant, screen }
    var presentation: Presentation = .dormant {
        didSet {
            guard presentation != oldValue else { return }
            transitionStarted = clock
            transitionActive = animationsAllowed
            noteActivity()
            screenGestureStarted = -.infinity
            if presentation == .screen {
                screenFrame = Self.screenIdleFrame
                beginScreenGesture()
            }
            refreshAnimation()
        }
    }
    var speaking = false {
        didSet {
            guard speaking != oldValue else { return }
            noteActivity()
            screenGestureStarted = -.infinity
            if speaking {
                isSleeping = false
                speakingStarted = clock
                play(perched ? "perch" : "idle")
            }
            refreshAnimation()
        }
    }

    var isSleeping = false {
        didSet {
            guard isSleeping != oldValue else { return }
            noteActivity()
            screenGestureStarted = -.infinity
            play(isSleeping ? "sleep" : (animationsAllowed ? "wake" : restingClip))
            if !isSleeping { beginScreenGesture() }
            refreshAnimation()
        }
    }

    var motionEnabled = true {
        didSet {
            guard motionEnabled != oldValue else { return }
            noteActivity()
            screenGestureStarted = -.infinity
            play(restingClip)
            refreshAnimation()
        }
    }

    var perched = false {
        didSet {
            guard perched != oldValue else { return }
            if !isSleeping {
                play(animationsAllowed ? (perched ? "perch_glitch" : "grin") : restingClip)
            }
            refreshAnimation()
        }
    }

    var onClick: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onDragBegin: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onPat: (() -> Void)?
    private(set) var isDragging = false
    /// The controller suspends idle performances while thinking or dictating.
    var idleSuppressed = false {
        didSet { if idleSuppressed != oldValue { noteActivity() } }
    }

    private struct Clip {
        let image: NSImage
        let bitmap: NSBitmapImageRep
        let frames: Int
        let fps: Double
        let cellWidth: Int
        let height: Int
    }

    /// Decode the original GIF lazily, retaining its real per-frame timing.
    /// The bounded cache avoids decoding every frame on every repaint.
    @MainActor
    private final class ScreenAnimation {
        private let source: CGImageSource
        private let frames = NSCache<NSNumber, NSImage>()
        let delays: [TimeInterval]
        let size: NSSize

        init?(url: URL) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            self.source = source
            size = NSSize(width: first.width, height: first.height)
            delays = (0..<CGImageSourceGetCount(source)).map { index in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                    ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0.1
                return delay > 0 ? delay : 0.1
            }
            frames.countLimit = 48
            frames.totalCostLimit = 32 * 1024 * 1024
            frames.setObject(NSImage(cgImage: first, size: size), forKey: 0,
                             cost: first.width * first.height * 4)
        }

        func image(at index: Int) -> NSImage? {
            let index = min(max(index, 0), delays.count - 1)
            let key = NSNumber(value: index)
            if let image = frames.object(forKey: key) { return image }
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            frames.setObject(result, forKey: key, cost: image.width * image.height * 4)
            return result
        }

        func duration(of indices: ClosedRange<Int>) -> TimeInterval {
            indices.filter { delays.indices.contains($0) }.reduce(0) { $0 + delays[$1] }
        }

        func frame(in indices: ClosedRange<Int>, elapsed: TimeInterval) -> Int {
            var remaining = max(0, elapsed)
            let valid = indices.filter { delays.indices.contains($0) }
            for index in valid {
                if remaining < delays[index] { return index }
                remaining -= delays[index]
            }
            return valid.last ?? 0
        }
    }

    // Frame counts and original timing from Capri's published site/app.js.
    private static let definitions: [(String, Int, Double)] = [
        ("idle", 16, 8), ("blink", 4, 8), ("blink_glitch", 4, 8),
        ("grin", 16, 8), ("glitch", 10, 15), ("dangle", 24, 10),
        ("sleep", 16, 6), ("wake", 13, 15), ("perch", 16, 8),
        ("perch_blink", 4, 8), ("perch_blink_glitch", 4, 8),
        ("perch_glitch", 10, 15), ("mouth", 5, 12)
    ]

    private var clips: [String: Clip] = [:]
    private var screenAnimation: ScreenAnimation?
    private var screenStills: [String: NSImage] = [:]
    // The final upright shot matches the reference video. The brief preceding
    // upright gesture is reserved for explicit reactions, never the speech loop.
    private static let screenPoseFrames = 156...162
    private static let screenGestureFrames = 128...162
    private static let screenIdleFrame = 156
    private static let screenTalkingFrame = 160
    private var screenFrame = CharacterView.screenIdleFrame
    private var screenGestureStarted: TimeInterval = -.infinity
    private var screenGestureRange = CharacterView.screenGestureFrames
    private var screenGestureRate = 1.0
    private var screenGestureHold: TimeInterval = 0
    private var screenGestureIsIdle = false
    private var screenGestureBlend = 1.0
    private var idleDirector = IdleAnimationDirector()
    private var clipName = "idle"
    private var clipStarted = ProcessInfo.processInfo.systemUptime
    private var speakingStarted = ProcessInfo.processInfo.systemUptime
    private var cell = 0
    private var mouthCell: Int?
    private var nextBlink = ProcessInfo.processInfo.systemUptime + 3
    private var nextGlitch = ProcessInfo.processInfo.systemUptime + 22
    private var timer: Timer?
    private var accessibilityObserver: NSObjectProtocol?
    private var pressPoint: NSPoint?
    private var lastDragPoint: NSPoint?
    private var pressClickCount = 0
    private var pendingClick: Task<Void, Never>?
    private var hoverTracking: NSTrackingArea?
    private var hoveringCharacter = false
    private var nextHoverReaction: TimeInterval = 0
    private var patStarted: TimeInterval = -.infinity
    private var patWasVisible = false
    private var standingContact = NSPoint(x: 147.0 / 240.0, y: 20.0 / 384.0)
    private var transitionStarted: TimeInterval = -.infinity
    private var transitionActive = false
    private var spacePulseStarted: TimeInterval = -.infinity
    private var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var animationsAllowed: Bool {
        motionEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var restingClip: String { isSleeping ? "sleep" : (perched ? "perch" : "idle") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepare()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepare()
    }

    private func prepare() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Capri companion")
        setAccessibilityHelp("Click to chat. Double-click to pat. Drag to move. Right-click for options.")
        loadClips()
        loadScreenArtwork()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // This observer is explicitly delivered on OperationQueue.main.
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.noteActivity()
                self.screenGestureStarted = -.infinity
                self.play(self.restingClip)
                self.refreshAnimation()
            }
        }
    }

    isolated deinit {
        timer?.invalidate()
        pendingClick?.cancel()
        if let observer = accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func loadClips() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("assets/sprites") else { return }
        for (name, frames, fps) in Self.definitions {
            let url = root.appendingPathComponent(name).appendingPathExtension("png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  cgImage.width % frames == 0 else { continue }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            clips[name] = Clip(image: NSImage(cgImage: cgImage, size: size),
                               bitmap: NSBitmapImageRep(cgImage: cgImage),
                               frames: frames, fps: fps,
                               cellWidth: cgImage.width / frames, height: cgImage.height)
        }
        // The standing sheet includes transparent padding below the feet. Use
        // the first idle frame's lowest solid pixels as a stable floor contact.
        if let idle = clips["idle"] {
            for y in stride(from: idle.height - 1, through: 0, by: -1) {
                let xs = (0..<idle.cellWidth).filter {
                    (idle.bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) >= 0.12
                }
                if let first = xs.first, let last = xs.last {
                    standingContact = NSPoint(
                        x: CGFloat(first + last + 1) / (2 * CGFloat(idle.cellWidth)),
                        y: 1 - CGFloat(y + 1) / CGFloat(idle.height)
                    )
                    break
                }
            }
        }
    }

    private func loadScreenArtwork() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("assets/screen") else { return }
        if let animation = ScreenAnimation(url: root.appendingPathComponent("portrait.gif")),
           Self.screenPoseFrames.allSatisfy({ animation.delays.indices.contains($0) }) {
            screenAnimation = animation
        }
        for name in ["portrait-idle", "portrait-talk"] {
            let url = root.appendingPathComponent(name).appendingPathExtension("png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            screenStills[name] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() } else { refreshAnimation() }
    }

    private func refreshAnimation() {
        advance()
        needsDisplay = true
        // Offscreen QA is advanced explicitly; it must not be mistaken for a
        // user-hidden window and cancel the very cue being captured.
        guard !CommandLine.arguments.contains("--render-preview") else { return }
        guard window != nil else { return }
        let interval = presentation == .screen ? 1.0 / 30.0 : 1.0 / 12.0
        if timer?.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // The timer is installed only in RunLoop.main below.
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else {
                    self.noteActivity()
                    return
                }
                self.advance()
            }
        }
        timer.tolerance = min(0.015, interval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Advances a headless artifact render without opening an interactive window.
    func updateForPreview() {
        advance()
        needsDisplay = true
    }

    /// Pauses the renderer and releases its timer, for closing or removing it.
    func stopAnimation() {
        noteActivity()
        timer?.invalidate()
        timer = nil
        pendingClick?.cancel()
        pendingClick = nil
    }

    /// A brief visual reaction. Reduced Motion keeps a static, calm pose.
    func react() {
        noteActivity()
        if isSleeping {
            isSleeping = false
        } else if presentation == .screen {
            beginScreenGesture()
        } else if animationsAllowed && !speaking {
            play(perched ? "perch_glitch" : "glitch")
        }
        refreshAnimation()
    }

    /// A friendly, explicit pat. Uses the published grin/blink animations;
    /// seated Capri keeps her seated pose so her ledge contact does not move.
    func pat() {
        noteActivity()
        cancelPendingClick()
        if isSleeping { isSleeping = false }
        screenGestureStarted = -.infinity
        if animationsAllowed {
            if !speaking { play(perched ? "perch_blink" : "grin") }
            patStarted = clock
        } else {
            patStarted = -.infinity
            play(restingClip)
        }
        refreshAnimation()
        onPat?()
    }

    /// A brief arrival accent after macOS changes Spaces. Preserve an active
    /// reply, sleep, and dragging instead of replacing those animation states.
    func arriveOnSpace() {
        noteActivity()
        guard animationsAllowed, !speaking, !isSleeping, !isDragging else { return }
        spacePulseStarted = clock
        if presentation == .standing { play(perched ? "perch_glitch" : "glitch") }
        if presentation == .screen { beginScreenGesture() }
        refreshAnimation()
    }

    /// One native upright gesture, including its original green burst and
    /// return to the familiar wink. Talking and dragging always take priority.
    private func beginScreenGesture() {
        guard presentation == .screen, animationsAllowed, !isSleeping,
              !speaking, !isDragging, screenAnimation != nil else { return }
        screenGestureStarted = clock
        screenGestureRange = Self.screenGestureFrames
        screenGestureRate = 1
        screenGestureHold = 0
        screenGestureIsIdle = false
        needsDisplay = true
    }

    /// Only visual state changes here: no brain or speech calls. Typing and
    /// visibility changes cancel an idle cue immediately and restart its quiet gap.
    func noteActivity() {
        idleDirector.noteActivity(at: clock)
        if screenGestureIsIdle {
            screenGestureStarted = -.infinity
            screenGestureIsIdle = false
            screenFrame = Self.screenIdleFrame
            screenGestureBlend = 1
            needsDisplay = true
        }
    }

    private var screenGestureDuration: TimeInterval {
        (screenAnimation?.duration(of: screenGestureRange) ?? 0) / screenGestureRate + screenGestureHold
    }

    private func beginIdleCue(_ cue: IdleAnimationDirector.Cue, at now: TimeInterval) {
        // All poses come from the original 498x281 animation. The frequent cues
        // omit its bright green burst; a short crossfade softens the pose change.
        switch cue {
        case .glance:
            screenGestureRange = 128...136
            screenGestureRate = 0.7
            screenGestureHold = 0.65
        case .grin:
            screenGestureRange = 137...141
            screenGestureRate = 0.55
            screenGestureHold = 0.7
        case .gesture:
            screenGestureRange = 152...162
            screenGestureRate = 0.65
            screenGestureHold = 0.3
        }
        screenGestureIsIdle = true
        screenGestureStarted = now
        needsDisplay = true
    }

    /// Deterministic visual QA; the caller uses this only in offscreen preview mode.
    func previewIdleCue(_ cue: IdleAnimationDirector.Cue) {
        beginIdleCue(cue, at: clock)
    }

    private func play(_ requested: String) {
        clipName = clips[requested] != nil ? requested : "idle"
        clipStarted = clock
        cell = 0
        mouthCell = nil
        needsDisplay = true
    }

    private func advance() {
        let now = clock
        if presentation == .screen {
            let eligible = !speaking && !isSleeping && !isDragging && !idleSuppressed
                && animationsAllowed && now - patStarted >= 0.9 && screenAnimation != nil
            if let cue = idleDirector.update(at: now, eligible: eligible) {
                beginIdleCue(cue, at: now)
            }
            let next = screenFrame(at: now)
            let elapsed = now - screenGestureStarted
            let blend = screenGestureIsIdle && elapsed >= 0 && elapsed < screenGestureDuration
                ? max(0, min(1, elapsed / 0.16, (screenGestureDuration - elapsed) / 0.18)) : 1
            if next != screenFrame || blend != screenGestureBlend {
                screenFrame = next
                screenGestureBlend = blend
                needsDisplay = true
            }
        } else {
            _ = idleDirector.update(at: now, eligible: false)
        }
        let patVisible = presentation == .standing && animationsAllowed && now - patStarted < 0.9
        if patVisible || patWasVisible { needsDisplay = true }
        patWasVisible = patVisible
        if transitionActive {
            needsDisplay = true
            if !animationsAllowed || now - transitionStarted >= 0.34 { transitionActive = false }
        }
        if animationsAllowed && (presentation == .dormant || now - spacePulseStarted < 0.5) { needsDisplay = true }
        // The portrait has its own fixed-pose playback. Advancing the unrelated
        // standing sprite would cause needless redraws while the screen is idle.
        if presentation == .screen { return }
        guard let clip = clips[clipName] else { return }
        if !animationsAllowed {
            if clipName != restingClip { play(restingClip) }
            if cell != 0 || mouthCell != nil { needsDisplay = true }
            cell = 0
            mouthCell = nil
            return
        }

        let elapsedFrames = max(0, Int((now - clipStarted) * clip.fps))
        let looped = ["idle", "perch", "sleep", "dangle"].contains(clipName)
        let repeats = clipName == "grin" ? 2 : 1
        if !looped && elapsedFrames >= clip.frames * repeats {
            play(restingClip)
            nextBlink = now + Double.random(in: 2.5...6)
            return
        }

        if !isDragging && !speaking && !isSleeping && !idleSuppressed && (clipName == "idle" || clipName == "perch") {
            if now >= nextGlitch {
                nextGlitch = now + Double.random(in: 25...50)
                play(perched ? "perch_glitch" : "glitch")
                return
            }
            if now >= nextBlink {
                nextBlink = now + Double.random(in: 2.5...6)
                let suffix = Int.random(in: 0..<10) == 0 ? "blink_glitch" : "blink"
                play((perched ? "perch_" : "") + suffix)
                return
            }
        }

        let newCell = elapsedFrames % clip.frames
        var newMouth: Int?
        if speaking && clipName == "idle" && clips["mouth"] != nil {
            // A modest rhythmic flap; callers expose speaking state, not phonemes.
            let pattern = [0, 1, 3, 2, 4, 2, 1, 0, 2, 3, 1, 0]
            let step = max(0, Int((now - speakingStarted) * 12))
            newMouth = pattern[step % pattern.count]
        }
        if cell != newCell || mouthCell != newMouth { needsDisplay = true }
        cell = newCell
        mouthCell = newMouth
    }

    private func screenFrame(at now: TimeInterval) -> Int {
        guard !isSleeping, animationsAllowed else { return Self.screenIdleFrame }
        if speaking {
            guard let animation = screenAnimation else { return Self.screenTalkingFrame }
            // Original closed/open mouth frames at their native GIF delays;
            // this is a same-pose speaking loop, not phoneme synchronization.
            let duration = animation.duration(of: Self.screenPoseFrames)
            guard duration > 0 else { return Self.screenTalkingFrame }
            let phase = max(0, now - speakingStarted).truncatingRemainder(dividingBy: duration)
            return animation.frame(in: Self.screenPoseFrames, elapsed: phase)
        }
        if isDragging { return Self.screenIdleFrame }
        if now - patStarted < 0.45 { return Self.screenTalkingFrame }
        if let animation = screenAnimation {
            let elapsed = now - screenGestureStarted
            if elapsed >= 0, elapsed < screenGestureDuration {
                return animation.frame(in: screenGestureRange, elapsed: elapsed * screenGestureRate)
            }
        }
        // The source holds a wink; it contains no full blink in this pose.
        return Self.screenIdleFrame
    }

    private func spriteRect(for clip: Clip) -> NSRect {
        let available = bounds.insetBy(dx: 4, dy: 4)
        guard available.width > 0, available.height > 0 else { return .zero }
        let ratio = CGFloat(clip.cellWidth) / CGFloat(clip.height)
        let height = min(available.height, available.width / ratio)
        let width = height * ratio
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    /// Feet contact in this view's coordinates; callers convert it into the
    /// containing panel before placing Capri on the desktop's visible floor.
    func standingAnchor() -> NSPoint {
        guard let clip = clips["idle"] else { return NSPoint(x: bounds.midX, y: bounds.minY + 4) }
        let rect = spriteRect(for: clip)
        return NSPoint(x: rect.minX + rect.width * standingContact.x,
                       y: rect.minY + rect.height * standingContact.y)
    }

    /// Hip contact for the original square perch strip. Its source renderer
    /// uses (0.30, 0.79) from the top left; AppKit's y axis points upward.
    func seatingAnchor() -> NSPoint {
        guard let clip = clips["perch"] else { return standingAnchor() }
        let rect = spriteRect(for: clip)
        return NSPoint(x: rect.minX + rect.width * 0.30,
                       y: rect.minY + rect.height * 0.21)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        NSGraphicsContext.current?.imageInterpolation = .high
        if presentation == .dormant {
            drawDormant()
            return
        }
        if presentation == .screen {
            drawScreen()
            return
        }
        guard let clip = clips[clipName] else { return }
        let destination = spriteRect(for: clip)
        draw(clip, cell: cell, in: destination)
        if let mouthCell = mouthCell, let mouth = clips["mouth"] {
            draw(mouth, cell: mouthCell, in: destination)
        }
        drawPatSparkles(around: destination)
    }

    private func drawPatSparkles(around rect: NSRect) {
        let elapsed = clock - patStarted
        guard animationsAllowed, elapsed >= 0, elapsed < 0.9 else { return }
        let progress = CGFloat(elapsed / 0.9)
        let alpha = min(1, progress * 8) * (1 - progress)
        let center = NSPoint(x: rect.midX + rect.width * 0.08,
                             y: rect.minY + rect.height * 0.71)
        let offsets: [(CGFloat, CGFloat, CGFloat)] = [
            (-0.34, 0.02, 12), (0.30, 0.12, 15), (-0.19, 0.27, 10), (0.39, -0.12, 11)
        ]
        for (index, item) in offsets.enumerated() {
            let (x, y, size) = item
            let point = NSPoint(x: center.x + x * rect.width + x * 12 * progress,
                                y: center.y + y * rect.height + 10 * progress)
            let color = index.isMultiple(of: 2) ? displayCyan : displayYellow
            ("✦" as NSString).draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: color.withAlphaComponent(alpha)
            ])
        }
    }

    private func draw(_ clip: Clip, cell: Int, in destination: NSRect) {
        let source = NSRect(x: cell * clip.cellWidth, y: 0,
                            width: clip.cellWidth, height: clip.height)
        clip.image.draw(in: destination, from: source, operation: .sourceOver,
                        fraction: 1, respectFlipped: false, hints: nil)
    }

    private let displayPink = NSColor(calibratedRed: 0.98, green: 0.055, blue: 0.29, alpha: 1)
    private let displayCyan = NSColor(calibratedRed: 0.22, green: 0.95, blue: 0.91, alpha: 1)
    private let displayYellow = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.43, alpha: 1)
    private let displayInk = NSColor(calibratedRed: 0.025, green: 0.025, blue: 0.065, alpha: 1)

    private var transitionProgress: CGFloat {
        guard animationsAllowed, transitionActive else { return 1 }
        return min(1, max(0, CGFloat((clock - transitionStarted) / 0.34)))
    }

    private func polygon(_ points: [NSPoint], fill: NSColor, stroke: NSColor? = nil, width: CGFloat = 1) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
        fill.setFill(); path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = width; path.stroke() }
    }

    private func dormantSymbolRect() -> NSRect {
        let side = max(12, min(bounds.width - 12, bounds.height - 30))
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 + 10, width: side, height: side)
    }

    private func dormantTagRect() -> NSRect {
        let symbol = dormantSymbolRect()
        let width = min(bounds.width - 2, 122)
        return NSRect(x: bounds.midX - width / 2, y: symbol.minY - 19, width: width, height: 15)
    }

    private func drawDormant() {
        var rect = dormantSymbolRect()
        if animationsAllowed { rect.origin.y += CGFloat(sin(clock * 1.7)) * 1.4 }
        let progress = transitionProgress
        let scale: CGFloat = 0.82 + 0.18 * progress
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: rect.midX, byY: rect.midY)
        var t = transform
        t.scale(x: rect.width / 100 * scale, y: rect.height / 100 * scale)
        t.translate(x: -50, y: -50)
        (t as NSAffineTransform).concat()
        let red = displayPink
        let mint = NSColor(calibratedRed: 0.56, green: 0.98, blue: 0.78, alpha: 1)
        // Asymmetrical detached shards around a concentric cybernetic eye.
        let shards: [([NSPoint], NSColor)] = [
            ([.init(x: 41,y: 71), .init(x: 31,y: 96), .init(x: 47,y: 86), .init(x: 48,y: 75)], red),
            ([.init(x: 58,y: 73), .init(x: 70,y: 93), .init(x: 67,y: 72)], mint),
            ([.init(x: 71,y: 64), .init(x: 97,y: 72), .init(x: 86,y: 59), .init(x: 75,y: 57)], red),
            ([.init(x: 75,y: 47), .init(x: 96,y: 37), .init(x: 71,y: 37)], mint),
            ([.init(x: 57,y: 31), .init(x: 59,y: 3), .init(x: 47,y: 17), .init(x: 48,y: 31)], red),
            ([.init(x: 45,y: 29), .init(x: 34,y: 0), .init(x: 36,y: 31)], red),
            ([.init(x: 30,y: 41), .init(x: 9,y: 29), .init(x: 21,y: 48)], mint),
            ([.init(x: 27,y: 56), .init(x: 0,y: 63), .init(x: 21,y: 69), .init(x: 33,y: 62)], red)
        ]
        for (points, color) in shards { polygon(points, fill: color, stroke: displayInk.withAlphaComponent(0.45), width: 0.7) }
        func eyeHex(_ radius: CGFloat) -> [NSPoint] {
            (0..<6).map { index in
                let angle = CGFloat(index) * .pi / 3 + .pi / 6
                return NSPoint(x: 50 + cos(angle) * radius, y: 54 + sin(angle) * radius)
            }
        }
        polygon(eyeHex(18), fill: displayInk, stroke: displayCyan, width: 1.8)
        polygon(eyeHex(12), fill: displayInk, stroke: NSColor(calibratedWhite: 0.91, alpha: 1), width: 1.6)
        polygon(eyeHex(7), fill: displayCyan, stroke: displayInk, width: 1)
        polygon([.init(x: 49,y: 60), .init(x: 53,y: 55), .init(x: 51,y: 48), .init(x: 47,y: 53)], fill: displayInk)
        NSGraphicsContext.restoreGraphicsState()

        let tag = dormantTagRect()
        displayInk.withAlphaComponent(0.93).setFill(); tag.fill()
        displayYellow.withAlphaComponent(0.65).setStroke(); NSBezierPath(rect: tag).stroke()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let text = isSleeping ? "CAPRI // RESTING" : "CAPRI // DORMANT"
        (text as NSString).draw(in: tag.insetBy(dx: 2, dy: 2), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: min(9, tag.width / 12.6), weight: .medium),
            .foregroundColor: displayYellow, .paragraphStyle: style
        ])
        if progress < 1 { drawGlitch(in: rect, intensity: 1 - progress) }
    }

    private func displayRect() -> NSRect {
        // Leave just enough room above the frame for the overlapping name tag.
        let area = NSRect(x: bounds.minX + 4, y: bounds.minY + 4,
                          width: max(0, bounds.width - 8), height: max(0, bounds.height - 13))
        let aspect = screenAnimation.map { $0.size.width / $0.size.height } ?? (498.0 / 281.0)
        let width = min(area.width, area.height * aspect)
        let height = width / aspect
        return NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private func drawScreen() {
        let rect = displayRect()
        let progress = transitionProgress
        let eased = 1 - pow(1 - progress, 3)
        NSGraphicsContext.saveGraphicsState()
        if progress < 1 {
            var t = AffineTransform(translationByX: rect.midX, byY: rect.midY)
            t.scale(x: 0.86 + 0.14 * eased, y: 0.12 + 0.88 * eased)
            t.translate(x: -rect.midX, y: -rect.midY)
            (t as NSAffineTransform).concat()
        }
        displayInk.setFill(); rect.fill()
        let imageRect = rect.insetBy(dx: 6, dy: 6)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        drawPortrait(in: imageRect)
        if isSleeping {
            displayInk.withAlphaComponent(0.24).setFill()
            imageRect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        displayYellow.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)); border.lineWidth = 1.5; border.stroke()
        displayYellow.withAlphaComponent(0.55).setStroke()
        let innerBorder = NSBezierPath(rect: rect.insetBy(dx: 4, dy: 4)); innerBorder.lineWidth = 0.6; innerBorder.stroke()
        displayYellow.setStroke()
        let corners = NSBezierPath(); corners.lineWidth = 3
        for (x, y, dx, dy) in [(rect.minX,rect.minY,CGFloat(1),CGFloat(1)),
                               (rect.maxX,rect.minY,CGFloat(-1),CGFloat(1)),
                               (rect.minX,rect.maxY,CGFloat(1),CGFloat(-1)),
                               (rect.maxX,rect.maxY,CGFloat(-1),CGFloat(-1))] {
            corners.move(to: .init(x: x, y: y + dy * 16)); corners.line(to: .init(x: x, y: y)); corners.line(to: .init(x: x + dx * 16, y: y))
        }
        corners.stroke()
        let title = speaking ? "CAPRI // TALKING" : (isSleeping ? "CAPRI // RESTING" : "CAPRI // CONNECTED")
        let tag = NSRect(x: rect.minX + 12, y: rect.maxY - 9, width: 142, height: 18)
        displayInk.setFill(); tag.fill(); displayYellow.setStroke(); NSBezierPath(rect: tag).stroke()
        (title as NSString).draw(in: tag.insetBy(dx: 5, dy: 3), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: displayYellow
        ])
        NSGraphicsContext.restoreGraphicsState()
        let spaceProgress = animationsAllowed ? max(0, 1 - CGFloat((clock - spacePulseStarted) / 0.45)) : 0
        if progress < 1 || spaceProgress > 0 {
            drawGlitch(in: rect, intensity: max(1 - progress, spaceProgress * 0.35))
        }
    }

    private func drawPortrait(in rect: NSRect) {
        let still = screenFrame >= Self.screenTalkingFrame - 1 ? "portrait-talk" : "portrait-idle"
        guard let image = screenAnimation?.image(at: screenFrame) ?? screenStills[still]
                ?? screenStills["portrait-idle"] else {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            ("CAPRI // NO SIGNAL" as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - 6, width: rect.width, height: 16), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: displayYellow, .paragraphStyle: style
            ])
            return
        }
        // The whole original landscape frame is fitted without stretching or
        // cropping. Native 498x281 source pixels are interpolated for the display;
        // no low-resolution standing-face crop or unrelated mouth layer is used.
        let aspect = image.size.width / image.size.height
        let height = min(rect.height, rect.width / aspect)
        let width = height * aspect
        let destination = NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                                 width: width, height: height)
        if screenGestureBlend < 1, let resting = screenAnimation?.image(at: Self.screenIdleFrame) {
            resting.draw(in: destination, from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: false, hints: nil)
        }
        image.draw(in: destination, from: .zero, operation: .sourceOver,
                   fraction: screenGestureBlend, respectFlipped: false, hints: nil)
    }

    private func drawGlitch(in rect: NSRect, intensity: CGFloat) {
        guard intensity > 0, animationsAllowed else { return }
        let phase = Int(clock * 24)
        for index in 0..<7 {
            let y = rect.minY + rect.height * CGFloat(index + 1) / 8
            let shift = CGFloat(((phase + index * 7) % 9) - 4) * 2
            let width = rect.width * (index % 2 == 0 ? 0.86 : 0.63)
            let color = index % 2 == 0 ? displayCyan : displayPink
            color.withAlphaComponent(intensity * 0.72).setFill()
            NSRect(x: rect.midX - width / 2 + shift, y: y, width: width,
                   height: CGFloat(index % 3 + 1) * 2).fill()
        }
    }

    /// Alpha-aware local hit test for the controller's window click-through logic.
    /// A borderless window must still set `ignoresMouseEvents` outside this area.
    func containsCharacter(at point: NSPoint) -> Bool {
        if presentation == .screen { return displayRect().insetBy(dx: -2, dy: -9).contains(point) }
        if presentation == .dormant {
            let symbol = dormantSymbolRect()
            return NSBezierPath(ovalIn: symbol.insetBy(dx: -2, dy: -2)).contains(point) || dormantTagRect().contains(point)
        }
        guard let clip = clips[clipName] else { return bounds.insetBy(dx: 20, dy: 10).contains(point) }
        let rect = spriteRect(for: clip)
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return false }
        let x = min(clip.cellWidth - 1, max(0, Int((point.x - rect.minX) / rect.width * CGFloat(clip.cellWidth))))
        let y = min(clip.height - 1, max(0, Int((rect.maxY - point.y) / rect.height * CGFloat(clip.height))))
        // A few nearby pixels make thin limbs easier to grab without blocking
        // large transparent areas. Bitmap coordinates start at the upper left.
        for dy in stride(from: -3, through: 3, by: 3) {
            for dx in stride(from: -3, through: 3, by: 3) {
                let sampleX = min(clip.cellWidth - 1, max(0, x + dx)) + cell * clip.cellWidth
                let sampleY = min(clip.height - 1, max(0, y + dy))
                if (clip.bitmap.colorAt(x: sampleX, y: sampleY)?.alphaComponent ?? 0) >= 0.08 { return true }
            }
        }
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return containsCharacter(at: local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { hoveringCharacter = false }

    private func updateHover(with event: NSEvent) {
        guard presentation == .standing else { hoveringCharacter = false; return }
        let inside = containsCharacter(at: convert(event.locationInWindow, from: nil))
        let entered = inside && !hoveringCharacter
        hoveringCharacter = inside
        guard entered, animationsAllowed, !isSleeping, !speaking, !isDragging,
              clock >= nextHoverReaction, clipName == restingClip else { return }
        nextHoverReaction = clock + 6
        play(perched ? "perch_blink" : "blink")
        refreshAnimation()
    }

    private func cancelPendingClick() {
        pendingClick?.cancel()
        pendingClick = nil
    }

    private func queueSingleClick() {
        cancelPendingClick()
        // Wait through the system double-click interval. A second click pats
        // Capri instead of opening and immediately closing the chat panel.
        let delay = NSEvent.doubleClickInterval
        pendingClick = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.window?.isVisible == true else { return }
            self.pendingClick = nil
            self.react()
            self.onClick?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        noteActivity()
        cancelPendingClick()
        if event.modifierFlags.contains(.control) {
            onMenu?(event)
            return
        }
        let location = NSEvent.mouseLocation
        pressPoint = location
        lastDragPoint = location
        pressClickCount = max(1, event.clickCount)
        isDragging = false
        if isSleeping { isSleeping = false }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressPoint, let previous = lastDragPoint else { return }
        let location = NSEvent.mouseLocation
        if !isDragging {
            let dx = location.x - press.x
            let dy = location.y - press.y
            guard dx * dx + dy * dy > 16 else { return }
            isDragging = true
            screenGestureStarted = -.infinity
            onDragBegin?()
            play(animationsAllowed ? "dangle" : restingClip)
            refreshAnimation()
        }
        let delta = NSPoint(x: location.x - previous.x, y: location.y - previous.y)
        lastDragPoint = location
        onMove?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        let moved = isDragging
        let clicks = pressClickCount
        pressPoint = nil
        lastDragPoint = nil
        pressClickCount = 0
        isDragging = false
        if moved {
            play(animationsAllowed && !perched ? "grin" : restingClip)
            refreshAnimation()
            onDragEnd?()
        } else if clicks >= 2 {
            pat()
        } else {
            queueSingleClick()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingClick()
        onMenu?(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            cancelPendingClick()
            react()
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        cancelPendingClick()
        react()
        onClick?()
        return true
    }
}
