import AppKit
import Carbon
import QuartzCore

let cyan = NSColor(calibratedRed: 0.22, green: 0.88, blue: 0.92, alpha: 1)
let pink = NSColor(calibratedRed: 1, green: 0.15, blue: 0.39, alpha: 1)
let yellow = NSColor(calibratedRed: 0.95, green: 0.91, blue: 0.39, alpha: 1)
let ink = NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.07, alpha: 0.97)

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

@MainActor func label(_ text: String, frame: NSRect, size: CGFloat = 12, color: NSColor = .white) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.frame = frame; view.font = mono(size); view.textColor = color
    view.lineBreakMode = .byWordWrapping
    return view
}

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NeonPlate: NSView {
    var accent = cyan
    var pointed = false
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + 9, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX, y: r.minY + 10))
        p.line(to: NSPoint(x: r.maxX - 10, y: r.minY))
        if pointed {
            p.line(to: NSPoint(x: r.midX + 20, y: r.minY))
            p.line(to: NSPoint(x: r.midX + 25, y: r.minY - 8))
            p.line(to: NSPoint(x: r.midX + 5, y: r.minY))
        }
        p.line(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.minX, y: r.maxY - 9)); p.close()
        ink.setFill(); p.fill(); accent.withAlphaComponent(0.9).setStroke(); p.lineWidth = 1; p.stroke()
        pink.setFill(); NSRect(x: 1, y: r.minY + 9, width: 2, height: r.height - 24).fill()
    }
}

enum LocalCommand: Equatable {
    case web(String), youtube(String), open(String), time, date, help, sleep, wake, pet, perch
    static func parse(_ input: String) -> LocalCommand? {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        if ["help", "/help", "what can you do?", "what can you do"].contains(lower) { return .help }
        if ["sleep", "go to sleep", "take a nap"].contains(lower) { return .sleep }
        if ["wake", "wake up", "wake up capri"].contains(lower) { return .wake }
        if ["pet", "pat", "pet capri", "pat capri"].contains(lower) { return .pet }
        if ["perch", "perch on window", "sit on window"].contains(lower) { return .perch }
        if ["time", "what time is it", "what time is it?"].contains(lower) { return .time }
        if ["date", "what's today's date", "what's today's date?", "what is today's date?"].contains(lower) { return .date }
        for prefix in ["search youtube for ", "youtube search ", "youtube ", "find on youtube "] where lower.hasPrefix(prefix) {
            let query = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : .youtube(query)
        }
        for prefix in ["search the web for ", "search for ", "search ", "google "] where lower.hasPrefix(prefix) {
            let query = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : .web(query)
        }
        if lower.hasPrefix("open ") {
            let name = String(lower.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if ["youtube", "google", "safari", "calculator", "notes", "music", "finder", "calendar"].contains(name) { return .open(name) }
        }
        return nil
    }
    static func searchURL(query: String, youtube: Bool) -> URL {
        var parts = URLComponents(string: youtube ? "https://www.youtube.com/results" : "https://www.google.com/search")!
        parts.queryItems = [URLQueryItem(name: youtube ? "search_query" : "q", value: query)]
        return parts.url!
    }
}

enum CompanionAppearance: String {
    case starScreen = "star-screen"
    case fullBody = "full-body"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let brain = CompanionBrain()
    let voice = CompanionVoice()
    let capriVoice = ElevenLabsVoice()
    let summonShortcut = RightCommandShortcut()
    let interactions = WindowInteractionController()
    let defaults = UserDefaults.standard
    var panel: CompanionPanel!
    var root: NSView!
    var character: CharacterView!
    var bubble: NeonPlate!
    var toolbar: NeonPlate!
    var statusLabel: NSTextField!
    var userLabel: NSTextField!
    var bubbleCloseButton: NSButton!
    var replyView: NSTextView!
    var replyScroll: NSScrollView!
    var input: NSTextField!
    var micButton: NSButton!
    var sendButton: NSButton!
    var footer: NSTextField!
    var tray: NSStatusItem!
    var settings: NSWindow?
    var backendPicker: NSPopUpButton?
    var chatGPTAccountWindow: NSWindow?
    var chatGPTAccountButton: NSButton?
    var chatGPTStatus: NSTextField?
    var chatGPTSignInButton: NSButton?
    var chatGPTSignOutButton: NSButton?
    var chatGPTModelPicker: NSPopUpButton?
    var chatGPTModels: [ChatGPTModel] = []
    var chatGPTAccountTask: Task<Void, Never>?
    var chatGPTAccountGeneration = 0
    var modelLabel: NSTextField?
    var modelField: NSTextField?
    var settingsStatus: NSTextField?
    var voiceProviderPicker: NSPopUpButton?
    var voiceKeyField: NSSecureTextField?
    var voiceIDField: NSTextField?
    var voiceStatus: NSTextField?
    var voiceSpeedSlider: NSSlider?
    var voiceSpeedValue: NSTextField?
    var shortcutStatus: NSTextField?
    var appearancePicker: NSPopUpButton?
    var interactionCheck: NSButton?
    var appearance: CompanionAppearance = .starScreen
    var useCapriVoice = true
    var mouseTimer: Timer?
    var chatTask: Task<Void, Never>?
    var animationTask: Task<Void, Never>?
    var spaceArrivalTask: Task<Void, Never>?
    var spaceChangeObserver: NSObjectProtocol?
    var hotKey: EventHotKeyRef?
    var visibilityHotKey: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var hotKeyDelivery = HotKeyDeliveryGate()
    var localKeyMonitor: Any?
    var generation = 0
    var busy = false {
        didSet { character?.idleSuppressed = busy || voice.isListening || capriVoice.isPreparing }
    }
    var voiceOn = false
    var acceptsVoiceDraft = false
    var chatVisible = false
    var conversationHasMessage = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["voice": true, "motion": true, "alwaysOnTop": true, "size": 1.0, "backend": "chatgpt", "chatGPTModel": "gpt-6.1-sol", "ollamaModel": "", "voiceProvider": "elevenlabs", "voiceID": "MkTSSXNgnBULS6ek4pon", "voiceSpeed": ElevenLabsVoice.defaultSpeed, "appearance": "star-screen", "windowInteractions": true])
        if !CommandLine.arguments.contains("--render-preview"), !defaults.bool(forKey: "chatGPTDefaultV1") {
            defaults.set("chatgpt", forKey: "backend")
            defaults.set(true, forKey: "chatGPTDefaultV1")
        }
        if !CommandLine.arguments.contains("--render-preview"), !defaults.bool(forKey: "windowCompanionV4") {
            // Activate the requested window look once; later LOOK choices persist.
            defaults.set("star-screen", forKey: "appearance")
            defaults.set(true, forKey: "windowCompanionV4")
        }
        appearance = CompanionAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .starScreen
        // Preview styles are deterministic and never change the saved choice.
        if CommandLine.arguments.contains("--render-preview") { appearance = .starScreen }
        if CommandLine.arguments.contains("--preview-star") { appearance = .starScreen }
        if CommandLine.arguments.contains("--preview-full-body") { appearance = .fullBody }
        chatVisible = CommandLine.arguments.contains("--preview-expanded")
        if CommandLine.arguments.contains("--render-preview") {
            // Build an offscreen view tree only. A preview must never install
            // shortcuts, create a tray item, open a window or receive input.
            setupPanel()
            setReply("Hey, choom. Link's up. What's on your mind?", state: "CAPRI // ONLINE")
            if CommandLine.arguments.contains("--preview-speaking") { character.speaking = true }
            if CommandLine.arguments.contains("--preview-reaction") { character.react() }
            let idlePreview = CommandLine.arguments.drop(while: { $0 != "--preview-idle" }).dropFirst().first
            if let idlePreview {
                let cue: IdleAnimationDirector.Cue = idlePreview == "glance" ? .glance : (idlePreview == "grin" ? .grin : .gesture)
                character.previewIdleCue(cue)
            }
            let previewDelay = CommandLine.arguments.contains("--preview-reaction") || idlePreview != nil ? 0.4 : 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + previewDelay) {
                self.character.updateForPreview()
                self.renderPreview()
                NSApp.terminate(nil)
            }
            return
        }
        voiceOn = defaults.bool(forKey: "voice")
        useCapriVoice = defaults.string(forKey: "voiceProvider") != "mac"
        capriVoice.voiceID = defaults.string(forKey: "voiceID") ?? "MkTSSXNgnBULS6ek4pon"
        capriVoice.speed = defaults.double(forKey: "voiceSpeed")
        switch defaults.string(forKey: "backend") {
        case "apple": brain.backend = .apple
        case "ollama": brain.backend = .ollama
        default: brain.backend = .chatGPT
        }
        brain.chatGPTModel = defaults.string(forKey: "chatGPTModel") ?? "gpt-6.1-sol"
        brain.ollamaModel = defaults.string(forKey: "ollamaModel") ?? ""
        setupPanel(); setupTray(); setupVoice(); setupInteractions(); registerShortcut()
        summonShortcut.onSummon = { [weak self] in self?.toggleSummonShortcut() }
        summonShortcut.onStatusChange = { [weak self] trusted in
            self?.shortcutStatus?.stringValue = trusted ? "Right ⌘ opens Capri. Press it again to close." : "Enable Accessibility for right ⌘ across apps."
        }
        summonShortcut.start()
        let greeting = "Hey, choom. Link's up. What's on your mind?"
        setReply(greeting, state: "CAPRI // ONLINE")
        showCompanion(focus: false)
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSpaceArrival() }
        }
    }

    func setupPanel() {
        panel = CompanionPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Capri for Mac"; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = defaults.bool(forKey: "alwaysOnTop") ? .floating : .normal
        panel.delegate = self
        root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 500))
        panel.contentView = root
        character = CharacterView(frame: NSRect(x: 80, y: 64, width: 220, height: 270))
        character.motionEnabled = defaults.bool(forKey: "motion")
        character.onClick = { [weak self] in self?.characterClicked() }
        character.onMove = { [weak self] delta in
            guard let self else { return }
            self.panel.setFrameOrigin(NSPoint(x: self.panel.frame.minX + delta.x, y: self.panel.frame.minY + delta.y))
            self.savePosition()
        }
        character.onDragBegin = { [weak self] in self?.interactions.beginDragging() }
        character.onDragEnd = { [weak self] in
            guard let self else { return }
            self.interactions.endDragging(at: self.panel.frame.origin)
            self.savePosition()
        }
        character.onPat = { [weak self] in
            if self?.chatVisible == true { self?.footer.stringValue = "PAT RECEIVED  ·  DIGITAL EGO BOOSTED" }
        }
        character.onMenu = { [weak self] event in
            guard let self, let menu = self.tray.menu else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self.character)
        }
        root.addSubview(character)
        bubble = NeonPlate(frame: NSRect(x: 12, y: 342, width: 356, height: 154))
        bubble.pointed = true
        statusLabel = label("CAPRI // ONLINE", frame: NSRect(x: 13, y: 130, width: 298, height: 17), size: 10, color: yellow)
        bubble.addSubview(statusLabel)
        let close = button("xmark", title: "Collapse Capri (Escape)", action: #selector(hideChat), frame: NSRect(x: 325, y: 126, width: 23, height: 23))
        bubbleCloseButton = close; bubble.addSubview(close)
        userLabel = label("LOCAL BRAIN. SMALL DIGITAL MENACE.", frame: NSRect(x: 13, y: 107, width: 330, height: 18), size: 10, color: .secondaryLabelColor)
        userLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        userLabel.lineBreakMode = .byTruncatingTail
        bubble.addSubview(userLabel)
        replyScroll = NSScrollView(frame: NSRect(x: 13, y: 14, width: 330, height: 89))
        replyScroll.drawsBackground = false; replyScroll.hasVerticalScroller = true; replyScroll.autohidesScrollers = true
        replyView = NSTextView(frame: replyScroll.bounds)
        replyView.isEditable = false; replyView.isSelectable = true; replyView.drawsBackground = false
        replyView.textColor = NSColor(calibratedWhite: 0.95, alpha: 1); replyView.font = mono(12)
        replyView.textContainerInset = NSSize(width: 0, height: 0)
        replyView.textContainer?.lineFragmentPadding = 0
        replyView.textContainer?.widthTracksTextView = true
        replyView.isVerticallyResizable = true; replyView.autoresizingMask = [.width]
        replyScroll.documentView = replyView; bubble.addSubview(replyScroll); root.addSubview(bubble)
        toolbar = NeonPlate(frame: NSRect(x: 12, y: 23, width: 356, height: 38))
        input = NSTextField(frame: NSRect(x: 12, y: 9, width: 237, height: 22))
        input.placeholderString = "Talk to Capri…"; input.font = mono(12); input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.textColor = .white; input.delegate = self; input.target = self; input.action = #selector(send)
        input.setAccessibilityLabel("Message Capri")
        toolbar.addSubview(input)
        micButton = button("mic", title: "Dictate a message", action: #selector(toggleMic), frame: NSRect(x: 251, y: 5, width: 29, height: 29))
        sendButton = button("arrow.up", title: "Send message", action: #selector(send), frame: NSRect(x: 282, y: 5, width: 29, height: 29))
        let gear = button("slider.horizontal.3", title: "Capri settings", action: #selector(showSettings), frame: NSRect(x: 317, y: 5, width: 29, height: 29))
        toolbar.addSubview(micButton); toolbar.addSubview(sendButton); toolbar.addSubview(gear); root.addSubview(toolbar)
        footer = label("DRAG TO MOVE  ·  RIGHT ⌘ OPENS / CLOSES", frame: NSRect(x: 15, y: 2, width: 350, height: 15), size: 9, color: cyan)
        footer.alignment = .center; root.addSubview(footer)
        setChatVisible(chatVisible)
        if CommandLine.arguments.contains("--render-preview") {
            panel.ignoresMouseEvents = true
            return
        }
        if defaults.object(forKey: "x") != nil {
            panel.setFrameOrigin(NSPoint(x: defaults.double(forKey: "x"), y: defaults.double(forKey: "y")))
            constrainToScreen()
        } else { bringHere() }
    }

    func button(_ symbol: String, title: String, action: Selector, frame: NSRect) -> NSButton {
        let b = NSButton(frame: frame)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.bezelStyle = .regularSquare; b.isBordered = false; b.contentTintColor = cyan
        b.target = self; b.action = action; b.toolTip = title; b.setAccessibilityLabel(title)
        return b
    }

    func setupTray() {
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        tray.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Capri")
        let menu = NSMenu()
        addMenu(menu, "Talk to Capri", #selector(summon))
        addMenu(menu, "Show / hide Capri  ·  ⌃⌥⌘C", #selector(toggleVisibility))
        addMenu(menu, "Bring Capri here", #selector(bringHere))
        addMenu(menu, "Perch on front window", #selector(perchOnFrontWindow))
        menu.addItem(.separator())
        addMenu(menu, "Settings…", #selector(showSettings), ",")
        addMenu(menu, "ChatGPT account…", #selector(showChatGPTAccount))
        addMenu(menu, "Manage ChatGPT usage…", #selector(manageChatGPTUsage))
        addMenu(menu, "New conversation", #selector(resetConversation))
        addMenu(menu, "How to use Capri", #selector(showHelp))
        menu.addItem(.separator())
        addMenu(menu, "Quit Capri", #selector(quit), "q")
        tray.menu = menu
        let main = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = menu.copy() as? NSMenu; main.addItem(appItem)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
    }
    func addMenu(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    func setupVoice() {
        voice.onTranscript = { [weak self] text, final in
            guard let self, self.acceptsVoiceDraft else { return }
            self.character.noteActivity()
            self.input.stringValue = text
            if final { self.footer.stringValue = "REVIEW YOUR MESSAGE, THEN PRESS RETURN" }
        }
        voice.onListeningChange = { [weak self] on in
            guard let self else { return }
            self.character.idleSuppressed = self.busy || on || self.capriVoice.isPreparing
            self.character.noteActivity()
            self.micButton.contentTintColor = on ? pink : cyan
            self.micButton.image = NSImage(systemSymbolName: on ? "stop.fill" : "mic", accessibilityDescription: on ? "Stop dictation" : "Dictate a message")
            self.footer.stringValue = on ? "LISTENING  ·  CLICK STOP WHEN FINISHED" : "REVIEW YOUR MESSAGE, THEN PRESS RETURN"
        }
        voice.onSpeakingChange = { [weak self] on in
            self?.character.speaking = on
            if !on, self?.busy == false { self?.statusLabel.stringValue = "CAPRI // ONLINE" }
        }
        voice.onError = { [weak self] message in self?.setReply(message, state: "CAPRI // VOICE") }
        capriVoice.onSpeakingChange = { [weak self] on in
            guard let self else { return }
            self.character.speaking = on
            if !self.busy {
                self.statusLabel.stringValue = on ? "CAPRI // TALKING" :
                    (self.capriVoice.isPreparing ? "CAPRI // VOICE LOADING" : "CAPRI // ONLINE")
            }
        }
        capriVoice.onPreparingChange = { [weak self] on in
            guard let self else { return }
            self.character.idleSuppressed = self.busy || self.voice.isListening || on
            self.character.noteActivity()
            if !self.busy, !self.capriVoice.isSpeaking {
                self.statusLabel.stringValue = on ? "CAPRI // VOICE LOADING" : "CAPRI // ONLINE"
            }
        }
        capriVoice.onError = { [weak self] message in
            self?.voiceStatus?.stringValue = message
            self?.footer.stringValue = "VOICE: " + message
            self?.footer.toolTip = message
        }
    }
    func registerShortcut() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, event.keyCode == UInt16(kVK_Escape), event.window === self.panel, self.chatVisible {
                self.hideChat(); return nil
            }
            // Local events also cover app-targeted input that Carbon may not
            // receive. Pair duplicate local/Carbon deliveries below.
            if let self, let action = CompanionHotKeyAction.matching(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                if !event.isARepeat { self.handleHotKey(action, from: .local) }
                return nil
            }
            return event
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == CompanionHotKeyAction.signature,
                  let action = CompanionHotKeyAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().handleHotKey(action, from: .carbon) }
            return noErr
        }, 1, &eventType, pointer, &hotKeyHandler)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_C), CompanionHotKeyAction.summon.carbonModifiers, EventHotKeyID(signature: CompanionHotKeyAction.signature, id: CompanionHotKeyAction.summon.rawValue), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { footer.stringValue = "USE THE ✦ MENU TO SUMMON CAPRI" }
        let visibilityStatus = RegisterEventHotKey(UInt32(kVK_ANSI_C), CompanionHotKeyAction.visibility.carbonModifiers, EventHotKeyID(signature: CompanionHotKeyAction.signature, id: CompanionHotKeyAction.visibility.rawValue), GetApplicationEventTarget(), 0, &visibilityHotKey)
        if visibilityStatus != noErr { footer.stringValue = "⌃⌥⌘C IS UNAVAILABLE  ·  USE THE ✦ MENU TO SHOW / HIDE" }
    }

    func setupInteractions() {
        interactions.onPosition = { [weak self] origin in
            // Transparent panel margins may extend beyond the desktop; the
            // interaction controller keeps the visible character in bounds.
            self?.panel.setFrameOrigin(origin)
        }
        interactions.onPerchedChanged = { [weak self] perched in
            self?.character.perched = perched
        }
        syncInteractionState()
        interactions.setPanelOrigin(panel.frame.origin)
        if !CommandLine.arguments.contains("--render-preview") { interactions.start(); settleIfAppropriate() }
    }
    func syncInteractionState() {
        interactions.enabled = appearance == .fullBody && defaults.bool(forKey: "windowInteractions")
        let feet = character.convert(character.standingAnchor(), to: root)
        let seat = character.convert(character.seatingAnchor(), to: root)
        let horizontalClearance = max(feet.x - character.frame.minX, character.frame.maxX - feet.x,
                                      seat.x - character.frame.minX, character.frame.maxX - seat.x)
        interactions.configure(standingAnchor: feet, seatingAnchor: seat,
                               bodyWidth: horizontalClearance * 2,
                               headClearance: max(16, character.frame.maxY - seat.y))
        interactions.motionEnabled = character.motionEnabled
        interactions.isSuspended = !panel.isVisible || chatVisible
    }
    func settleIfAppropriate() {
        guard appearance == .fullBody, defaults.bool(forKey: "windowInteractions"),
              !chatVisible, panel.isVisible, !CommandLine.arguments.contains("--render-preview") else { return }
        interactions.endDragging(at: panel.frame.origin)
    }
    @objc func perchOnFrontWindow() {
        if appearance != .fullBody {
            appearance = .fullBody; defaults.set(appearance.rawValue, forKey: "appearance")
            appearancePicker?.selectItem(at: 1)
        }
        defaults.set(true, forKey: "windowInteractions")
        interactionCheck?.state = .on
        hideChat(); showCompanion(focus: false); syncInteractionState(); interactions.setPanelOrigin(panel.frame.origin)
        if !interactions.perchOnFrontmostWindow() {
            setReply("No reachable window ledge right now. Drag me above a window, or I can stand on the desktop.", state: "CAPRI // INTERACTIONS")
            summon()
        }
    }

    @objc func send() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        character.noteActivity()
        acceptsVoiceDraft = false; voice.stopListening(); voice.stopSpeaking(); capriVoice.stop(); animationTask?.cancel()
        input.stringValue = ""; userLabel.stringValue = "> you: " + text
        conversationHasMessage = true; character.isSleeping = false
        setChatVisible(true); character.react()
        generation += 1; let request = generation
        if let action = LocalCommand.parse(text) { execute(action); return }
        busy = true; sendButton.isEnabled = false; input.isEnabled = false; micButton.isEnabled = false
        setReply("One sec, choom…", state: "CAPRI // THINKING")
        chatTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.brain.reply(to: text)
                guard request == self.generation, !Task.isCancelled else { return }
                self.finishRequest(); self.deliver(answer)
            } catch {
                guard request == self.generation, !Task.isCancelled else { return }
                self.finishRequest(); self.setReply(error.localizedDescription, state: "CAPRI // CONNECTION")
                // Keep the failed message ready for an intentional retry. Never
                // resend automatically: the previous request may have used allowance.
                if self.input.stringValue.isEmpty { self.input.stringValue = text }
            }
        }
    }
    func finishRequest() {
        busy = false; sendButton.isEnabled = true; input.isEnabled = true; micButton.isEnabled = true
        updateBrainSettings()
    }
    func execute(_ action: LocalCommand) {
        let request = generation
        switch action {
        case .web(let query): openURL(LocalCommand.searchURL(query: query, youtube: false), message: "Opening a web search for “\(query)”.")
        case .youtube(let query): openURL(LocalCommand.searchURL(query: query, youtube: true), message: "Pulling up “\(query)” on YouTube, choom.")
        case .open(let name):
            if name == "youtube" || name == "google" {
                openURL(URL(string: "https://www.\(name).com")!, message: "Opening \(name.capitalized).")
            } else {
                let ids = ["safari": "com.apple.Safari", "calculator": "com.apple.calculator", "notes": "com.apple.Notes", "music": "com.apple.Music", "finder": "com.apple.finder", "calendar": "com.apple.iCal"]
                guard let id = ids[name], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { setReply("I couldn't find that app on this Mac.", state: "CAPRI // APPS"); return }
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                    Task { @MainActor in
                        guard self?.generation == request else { return }
                        if let error { self?.setReply(error.localizedDescription, state: "CAPRI // APPS") }
                        else { self?.deliver("Opened \(name.capitalized). What's next?") }
                    }
                }
            }
        case .time:
            let formatter = DateFormatter(); formatter.timeStyle = .short
            deliver("It's \(formatter.string(from: Date())). Time flies when you're haunting a desktop.")
        case .date:
            let formatter = DateFormatter(); formatter.dateStyle = .full
            deliver(formatter.string(from: Date()))
        case .help: showHelp()
        case .sleep:
            character.isSleeping = true; setReply("Power nap. Click me when you need me.", state: "CAPRI // DORMANT")
            if appearance == .starScreen { hideChat() }
        case .wake:
            character.isSleeping = false; deliver("Back online. What are we getting into?")
        case .pet: character.pat()
        case .perch: perchOnFrontWindow()
        }
    }
    func openURL(_ url: URL, message: String) {
        if NSWorkspace.shared.open(url) { deliver(message) }
        else { setReply("I couldn't open your browser. Try again in a moment.", state: "CAPRI // BROWSER") }
    }
    func deliver(_ answer: String) {
        setReply(answer, state: "CAPRI // TALKING")
        // An intentional collapse keeps the finished reply for the next summon.
        // It must not reopen the screen or start speaking over another app.
        if !panel.isVisible || (!chatVisible && appearance == .starScreen) {
            character.speaking = false; statusLabel.stringValue = "CAPRI // ONLINE"
            return
        }
        if voiceOn && useCapriVoice && capriVoice.hasAPIKey { capriVoice.speak(answer) }
        else if voiceOn && !useCapriVoice { voice.speak(answer) }
        else {
            if voiceOn && useCapriVoice { footer.stringValue = "CAPRI VOICE: CONNECT ELEVENLABS IN SETTINGS" }
            character.speaking = true
            animationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(min(8.0, max(1.5, Double(answer.count) / 28))))
                guard !Task.isCancelled else { return }
                self?.character.speaking = false; self?.statusLabel.stringValue = "CAPRI // ONLINE"
            }
        }
    }
    func setReply(_ text: String, state: String) {
        replyView.string = text; statusLabel.stringValue = state
        layoutReplyBubble(); replyView.scrollToBeginningOfDocument(nil)
        if CommandLine.arguments.contains("--render-preview") {
            footer.stringValue = "LOCAL ANIMATION PREVIEW"
            return
        }
        if brain.backend == .chatGPT {
            footer.stringValue = ChatGPTAuth.shared.hasPlanAccess ? (busy ? "USING CHATGPT PLAN · THINKING" : "USING CHATGPT PLAN · RIGHT ⌘ OPENS / CLOSES") : "CONNECT CHATGPT IN SETTINGS"
        } else { footer.stringValue = busy ? "LOCAL AI  ·  THINKING" : "DRAG TO MOVE  ·  RIGHT ⌘ OPENS / CLOSES" }
    }
    func layoutReplyBubble() {
        let textWidth: CGFloat = 330
        let attributed = NSAttributedString(string: replyView.string, attributes: [.font: replyView.font ?? mono(12)])
        let measured = ceil(attributed.boundingRect(
            with: NSSize(width: textWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 3
        if appearance == .fullBody {
            bubble.frame = NSRect(x: 12, y: 342, width: 356, height: 154)
            statusLabel.frame = NSRect(x: 13, y: 130, width: 298, height: 17)
            userLabel.frame = NSRect(x: 13, y: 107, width: 330, height: 18)
            userLabel.isHidden = false
            bubbleCloseButton.frame.origin.y = 126
            replyScroll.frame = NSRect(x: 13, y: 14, width: textWidth, height: 89)
        } else {
            let headerHeight: CGFloat = conversationHasMessage ? 52 : 35
            let contentHeight = min(154 - headerHeight, max(28, measured))
            let height = contentHeight + headerHeight
            // Match the reference's compact bubble; long answers scroll.
            bubble.frame = NSRect(x: 12, y: 342, width: 356, height: height)
            statusLabel.frame = NSRect(x: 13, y: contentHeight + 16, width: 298, height: 15)
            userLabel.frame = NSRect(x: 13, y: contentHeight + 32, width: 300, height: 15)
            userLabel.isHidden = !conversationHasMessage
            bubbleCloseButton.frame.origin.y = height - 26
            replyScroll.frame = NSRect(x: 13, y: 12, width: textWidth, height: contentHeight)
        }
        replyView.setFrameSize(NSSize(width: textWidth, height: max(measured, replyScroll.contentSize.height)))
        bubble.needsDisplay = true
    }
    @objc func toggleMic() {
        setChatVisible(true); showCompanion(focus: true)
        if voice.isListening { voice.stopListening() }
        else { acceptsVoiceDraft = true; voice.stopSpeaking(); capriVoice.stop(); voice.startListening() }
    }
    func setChatVisible(_ visible: Bool) {
        let wasVisible = chatVisible
        chatVisible = visible; bubble.isHidden = !visible; toolbar.isHidden = !visible; footer.isHidden = !visible
        applySize(defaults.double(forKey: "size"))
        if visible { character.isSleeping = false }
        else { panel.makeFirstResponder(nil); panel.resignKey() }
        syncInteractionState()
        if wasVisible != visible { interactions.setPanelOrigin(panel.frame.origin) }
        if wasVisible && !visible { settleIfAppropriate() }
        updateClickThrough()
    }
    func characterClicked() {
        if appearance == .starScreen { summon(); character.react() }
        else { toggleChat() }
    }
    func toggleChat() {
        if character.isSleeping { character.isSleeping = false; character.react() }
        setChatVisible(!chatVisible)
        if chatVisible { showCompanion(focus: true) }
        else { acceptsVoiceDraft = false; voice.stopListening() }
    }
    @objc func hideChat() {
        character.noteActivity()
        acceptsVoiceDraft = false; voice.stopListening(); voice.stopSpeaking(); capriVoice.stop()
        animationTask?.cancel(); character.speaking = false
        setChatVisible(false)
    }
    @objc func summon() { setChatVisible(true); showCompanion(focus: true) }
    func handleHotKey(_ action: CompanionHotKeyAction, from source: HotKeyDeliveryGate.Source) {
        guard hotKeyDelivery.accepts(action, from: source, at: ProcessInfo.processInfo.systemUptime) else { return }
        switch action {
        case .summon: toggleSummonShortcut()
        case .visibility: toggleVisibility()
        }
    }
    func toggleSummonShortcut() {
        if panel.isVisible && chatVisible { hideChat() }
        else { summon() }
    }
    func showCompanion(focus: Bool) {
        guard !CommandLine.arguments.contains("--render-preview") else { return }
        character.noteActivity()
        cancelSpaceArrival()
        if chatVisible { constrainToScreen(forChat: true); interactions.setPanelOrigin(panel.frame.origin) }
        panel.ignoresMouseEvents = false
        if focus { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(input); input.selectText(nil) }
        else { panel.orderFrontRegardless() }
        syncInteractionState()
    }
    @objc func toggleVisibility() {
        cancelSpaceArrival()
        if panel.isVisible {
            character.noteActivity()
            acceptsVoiceDraft = false; voice.stopListening(); voice.stopSpeaking(); capriVoice.stop()
            animationTask?.cancel(); animationTask = nil; character.speaking = false
            panel.orderOut(nil); interactions.isSuspended = true; savePosition()
        }
        else { showCompanion(focus: false) }
    }
    @objc func bringHere() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.minY + 25))
            interactions.setPanelOrigin(panel.frame.origin)
            savePosition(); showCompanion(focus: false); settleIfAppropriate()
        }
    }
    func savePosition() {
        guard !CommandLine.arguments.contains("--render-preview") else { return }
        defaults.set(panel.frame.minX, forKey: "x"); defaults.set(panel.frame.minY, forKey: "y")
    }
    func constrainToScreen(forChat: Bool = false) {
        if appearance == .fullBody, defaults.bool(forKey: "windowInteractions"), !chatVisible, !forChat {
            syncInteractionState()
            let feet = character.convert(character.standingAnchor(), to: root)
            let lowerEdge = character.perched ? character.frame.minY + 4 : feet.y
            let body = NSRect(x: character.frame.minX + 4, y: lowerEdge,
                              width: max(1, character.frame.width - 8),
                              height: max(1, character.frame.maxY - 4 - lowerEdge))
            let worldCenter = NSPoint(x: panel.frame.minX + body.midX, y: panel.frame.minY + body.midY)
            func distance(to frame: NSRect) -> CGFloat {
                let dx = max(frame.minX - worldCenter.x, 0, worldCenter.x - frame.maxX)
                let dy = max(frame.minY - worldCenter.y, 0, worldCenter.y - frame.maxY)
                return dx*dx + dy*dy
            }
            guard let frame = NSScreen.screens.map(\.visibleFrame).min(by: { distance(to: $0) < distance(to: $1) }) else { return }
            let origin = NSPoint(
                x: max(frame.minX - body.minX, min(panel.frame.minX, frame.maxX - body.maxX)),
                y: max(frame.minY - body.minY, min(panel.frame.minY, frame.maxY - body.maxY))
            )
            if origin != panel.frame.origin {
                panel.setFrameOrigin(origin)
                interactions.setPanelOrigin(origin)
                settleIfAppropriate()
            }
            return
        }
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main
        guard let screen else { return }; let f = screen.visibleFrame; let p = panel.frame
        panel.setFrameOrigin(NSPoint(x: max(f.minX, min(p.minX, f.maxX - p.width)), y: max(f.minY, min(p.minY, f.maxY - p.height))))
    }
    @objc func screensChanged() { constrainToScreen(); interactions.setPanelOrigin(panel.frame.origin); settleIfAppropriate() }
    func cancelSpaceArrival() {
        spaceArrivalTask?.cancel()
        spaceArrivalTask = nil
        panel.alphaValue = 1
    }
    func scheduleSpaceArrival() {
        spaceArrivalTask?.cancel()
        // Spaces are animated by WindowServer. This softens Capri's return on
        // the newly active Space; it does not try to draw over that transition.
        guard panel.isVisible, character.motionEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancelSpaceArrival()
            return
        }
        spaceArrivalTask = Task { [weak self] in
            // Collapse successive notifications from a quick series of swipes.
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self,
                  self.panel.isVisible, !self.character.isDragging,
                  self.character.motionEnabled,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            self.character.arriveOnSpace()
            self.panel.alphaValue = 0.18
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
            }, completionHandler: nil)
            self.spaceArrivalTask = nil
        }
    }
    func updateClickThrough() {
        guard panel.isVisible, !character.isDragging else { return }
        let point = root.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inCharacter = character.containsCharacter(at: character.convert(point, from: root))
        let inChat = chatVisible && (bubble.frame.contains(point) || toolbar.frame.contains(point))
        panel.ignoresMouseEvents = !(inCharacter || inChat)
    }
    @objc func resetConversation() {
        generation += 1; chatTask?.cancel(); chatTask = nil; finishRequest()
        acceptsVoiceDraft = false; brain.reset(); voice.stopSpeaking(); capriVoice.stop(); voice.stopListening(); animationTask?.cancel(); character.speaking = false
        userLabel.stringValue = "FRESH START"; conversationHasMessage = false
        setReply("Clean slate, choom. What's on your mind?", state: "CAPRI // ONLINE"); summon()
    }
    @objc func showHelp() {
        setChatVisible(true)
        setReply("Click the star or tap right ⌘ to open Capri's screen. Press right ⌘ again to go dormant; ⌥⌘C also toggles it. Escape or × collapses it too. Control–Option–Command–C hides Capri completely, including the star; press it again to restore her previous form. Drag to move; right-click for the menu.\n\nChat naturally, or try:\n• search YouTube for cyberpunk music\n• open Safari\n• what time is it?\n• sleep / wake up\n\nSettings → LOOK also has the full-body companion: double-click to pat, or drop her above a window to perch. Window interactions pause while chatting.\n\nThe mic listens only when clicked. Review your draft, then Return. Capri never reads window contents or typing in other apps.", state: "CAPRI // CONTROLS")
        showCompanion(focus: false)
    }

    @objc func showSettings() {
        if let settings { settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 730), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Capri · Mainframe"; window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ink
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 730)); window.contentView = v
        v.addSubview(label("CAPRI // MAINFRAME", frame: NSRect(x: 24, y: 683, width: 420, height: 24), size: 17, color: cyan))
        v.addSubview(label("Your desktop. A little more alive.", frame: NSRect(x: 24, y: 659, width: 420, height: 20), size: 11, color: .lightGray))
        v.addSubview(label("BRAIN", frame: NSRect(x: 24, y: 620, width: 90, height: 20), size: 11, color: yellow))
        let picker = NSPopUpButton(frame: NSRect(x: 136, y: 617, width: 310, height: 26))
        picker.addItems(withTitles: ["ChatGPT · your plan", "Apple Intelligence · on this Mac", "Ollama · local server"])
        picker.selectItem(at: CompanionBrain.Backend.allCases.firstIndex(of: brain.backend) ?? 0); picker.target = self; picker.action = #selector(backendChanged)
        v.addSubview(picker); backendPicker = picker
        let status = label(brain.statusDescription, frame: NSRect(x: 24, y: 577, width: 422, height: 32), size: 10, color: .lightGray)
        v.addSubview(status); settingsStatus = status
        let ml = label("Ollama model", frame: NSRect(x: 24, y: 550, width: 110, height: 22), size: 11)
        v.addSubview(ml); modelLabel = ml
        let model = NSTextField(frame: NSRect(x: 136, y: 550, width: 310, height: 24))
        model.stringValue = brain.ollamaModel; model.placeholderString = "Installed model name"; model.target = self; model.action = #selector(modelChanged)
        model.isEnabled = brain.backend == .ollama; model.delegate = self
        v.addSubview(model); modelField = model
        let account = NSButton(title: "ChatGPT account…", target: self, action: #selector(showChatGPTAccount))
        account.bezelStyle = .rounded; account.frame = NSRect(x: 24, y: 547, width: 422, height: 28)
        v.addSubview(account); chatGPTAccountButton = account
        updateBrainSettings()
        v.addSubview(label("VOICE", frame: NSRect(x: 24, y: 510, width: 90, height: 20), size: 11, color: yellow))
        let voices = NSPopUpButton(frame: NSRect(x: 136, y: 507, width: 310, height: 26))
        voices.addItems(withTitles: ["Capri · ElevenLabs", "Mac system voice"])
        voices.selectItem(at: useCapriVoice ? 0 : 1); voices.target = self; voices.action = #selector(voiceProviderChanged)
        voiceProviderPicker = voices; v.addSubview(voices)
        let key = NSSecureTextField(frame: NSRect(x: 24, y: 471, width: 306, height: 24))
        key.placeholderString = "ElevenLabs API key"; key.setAccessibilityLabel("ElevenLabs API key")
        voiceKeyField = key; v.addSubview(key)
        let save = NSButton(title: "Save key", target: self, action: #selector(saveVoiceKey))
        save.bezelStyle = .rounded; save.frame = NSRect(x: 340, y: 469, width: 106, height: 28); v.addSubview(save)
        v.addSubview(label("Voice ID", frame: NSRect(x: 24, y: 435, width: 100, height: 22), size: 11))
        let id = NSTextField(frame: NSRect(x: 136, y: 435, width: 310, height: 24))
        id.stringValue = capriVoice.voiceID; id.target = self; id.action = #selector(voiceIDChanged); id.delegate = self
        voiceIDField = id; v.addSubview(id)
        let note = label("", frame: NSRect(x: 24, y: 388, width: 422, height: 38), size: 10, color: .lightGray)
        voiceStatus = note; v.addSubview(note); refreshVoiceStatus()
        for (title, action, x, width) in [("Test voice", #selector(testVoice), 24.0, 125.0), ("Forget key", #selector(forgetVoiceKey), 160.0, 125.0), ("Get API key…", #selector(openVoiceKeys), 296.0, 150.0)] {
            let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 351, width: width, height: 28); v.addSubview(b)
        }
        addCheck(v, title: "Speak replies", y: 316, on: voiceOn, action: #selector(voiceChanged), width: 165)
        v.addSubview(label("Voice speed", frame: NSRect(x: 195, y: 318, width: 80, height: 20), size: 10))
        let speed = NSSlider(value: capriVoice.speed, minValue: ElevenLabsVoice.speedRange.lowerBound,
                             maxValue: ElevenLabsVoice.speedRange.upperBound, target: self, action: #selector(voiceSpeedChanged))
        speed.frame = NSRect(x: 277, y: 316, width: 115, height: 24)
        speed.isContinuous = true; speed.isEnabled = useCapriVoice
        speed.setAccessibilityLabel("ElevenLabs voice speed")
        speed.toolTip = "ElevenLabs speaking pace, from 0.70× to 1.20×. Applies to the next reply or Test voice."
        voiceSpeedSlider = speed; v.addSubview(speed)
        let speedValue = label(String(format: "%.2f×", capriVoice.speed), frame: NSRect(x: 398, y: 318, width: 48, height: 20), size: 10, color: useCapriVoice ? cyan : .secondaryLabelColor)
        voiceSpeedValue = speedValue; v.addSubview(speedValue)
        addCheck(v, title: "Idle animations", y: 286, on: character.motionEnabled, action: #selector(motionChanged), width: 200)
        interactionCheck = addCheck(v, title: "Window interactions", y: 286, on: defaults.bool(forKey: "windowInteractions"), action: #selector(interactionsChanged), x: 254, width: 190)
        addCheck(v, title: "Always on top", y: 256, on: defaults.bool(forKey: "alwaysOnTop"), action: #selector(topChanged))
        v.addSubview(label("LOOK", frame: NSRect(x: 24, y: 226, width: 90, height: 20), size: 11, color: yellow))
        let look = NSPopUpButton(frame: NSRect(x: 136, y: 223, width: 310, height: 26))
        look.addItems(withTitles: ["Star + screen", "Full-body companion"])
        look.selectItem(at: appearance == .starScreen ? 0 : 1)
        look.target = self; look.action = #selector(appearanceChanged)
        look.setAccessibilityLabel("Companion appearance")
        v.addSubview(look); appearancePicker = look
        v.addSubview(label("SIZE", frame: NSRect(x: 24, y: 190, width: 70, height: 20), size: 11, color: yellow))
        let size = NSSlider(value: defaults.double(forKey: "size"), minValue: 0.7, maxValue: 1.15, target: self, action: #selector(sizeChanged))
        size.frame = NSRect(x: 95, y: 188, width: 350, height: 25); v.addSubview(size)
        v.addSubview(label("OPEN / CLOSE · TAP RIGHT ⌘", frame: NSRect(x: 24, y: 151, width: 420, height: 20), size: 11, color: yellow))
        let enable = NSButton(title: "Enable shortcut…", target: self, action: #selector(enableShortcut))
        enable.bezelStyle = .rounded; enable.frame = NSRect(x: 24, y: 116, width: 164, height: 28); v.addSubview(enable)
        let shortcutNote = label(summonShortcut.isAccessibilityTrusted ? "Right ⌘ opens Capri.\nPress it again to close." : "Needs Accessibility permission.\n⌥⌘C also opens / closes.", frame: NSRect(x: 201, y: 108, width: 245, height: 42), size: 10, color: .lightGray)
        shortcutStatus = shortcutNote; v.addSubview(shortcutNote)
        v.addSubview(label("SHOW / HIDE CAPRI COMPLETELY · ⌃⌥⌘C", frame: NSRect(x: 24, y: 90, width: 422, height: 16), size: 10, color: cyan))
        v.addSubview(label("ChatGPT sends chat context to OpenAI using your plan.\nCapri voice sends replies to ElevenLabs using its credits.\nCredentials stay in Keychain. No local chat archive.\nUnofficial Mac adaptation · Capri Desktop artwork.", frame: NSRect(x: 24, y: 19, width: 422, height: 70), size: 10, color: .lightGray))
        settings = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @discardableResult func addCheck(_ parent: NSView, title: String, y: CGFloat, on: Bool, action: Selector, x: CGFloat = 24, width: CGFloat = 380) -> NSButton {
        let check = NSButton(checkboxWithTitle: title, target: self, action: action)
        check.frame = NSRect(x: x, y: y, width: width, height: 24); check.state = on ? .on : .off
        parent.addSubview(check)
        return check
    }
    @objc func appearanceChanged(_ sender: NSPopUpButton) {
        appearance = sender.indexOfSelectedItem == 0 ? .starScreen : .fullBody
        defaults.set(appearance.rawValue, forKey: "appearance")
        // Changing the look preserves the conversation, input draft and voice.
        applySize(defaults.double(forKey: "size")); syncInteractionState(); constrainToScreen(); updateClickThrough(); settleIfAppropriate()
    }
    @objc func backendChanged(_ sender: NSPopUpButton) {
        generation += 1; chatTask?.cancel(); finishRequest(); brain.reset()
        brain.backend = CompanionBrain.Backend.allCases[sender.indexOfSelectedItem]
        defaults.set(["chatgpt", "apple", "ollama"][sender.indexOfSelectedItem], forKey: "backend")
        updateBrainSettings()
        setReply(brain.statusDescription, state: "CAPRI // READY")
    }
    func updateBrainSettings() {
        modelField?.isHidden = brain.backend == .chatGPT
        modelLabel?.isHidden = brain.backend == .chatGPT
        modelField?.isEnabled = brain.backend == .ollama
        chatGPTAccountButton?.isHidden = brain.backend != .chatGPT
        settingsStatus?.stringValue = brain.statusDescription
    }
    @objc func modelChanged() {
        guard let field = modelField else { return }
        let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if model != brain.ollamaModel { generation += 1; chatTask?.cancel(); finishRequest() }
        brain.ollamaModel = model
        defaults.set(brain.ollamaModel, forKey: "ollamaModel"); settingsStatus?.stringValue = brain.statusDescription
        if brain.backend == .ollama { setReply(brain.statusDescription, state: "CAPRI // READY") }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === modelField { modelChanged() }
        if obj.object as? NSTextField === voiceIDField { voiceIDChanged() }
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === input { character.noteActivity() }
    }
    @objc func voiceChanged(_ sender: NSButton) { voiceOn = sender.state == .on; defaults.set(voiceOn, forKey: "voice"); if !voiceOn { voice.stopSpeaking(); capriVoice.stop() } }
    @objc func voiceProviderChanged(_ sender: NSPopUpButton) {
        voice.stopSpeaking(); capriVoice.stop(); useCapriVoice = sender.indexOfSelectedItem == 0
        defaults.set(useCapriVoice ? "elevenlabs" : "mac", forKey: "voiceProvider"); refreshVoiceStatus()
    }
    @objc func voiceSpeedChanged(_ sender: NSSlider) {
        capriVoice.speed = (sender.doubleValue * 100).rounded() / 100
        sender.doubleValue = capriVoice.speed
        defaults.set(capriVoice.speed, forKey: "voiceSpeed")
        voiceSpeedValue?.stringValue = String(format: "%.2f×", capriVoice.speed)
    }
    @objc func voiceIDChanged() {
        let value = voiceIDField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        capriVoice.voiceID = value.isEmpty ? "MkTSSXNgnBULS6ek4pon" : value
        defaults.set(capriVoice.voiceID, forKey: "voiceID"); refreshVoiceStatus()
    }
    @objc func saveVoiceKey() {
        guard let key = voiceKeyField?.stringValue, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { voiceStatus?.stringValue = "Paste your ElevenLabs API key in the secure field first."; return }
        do { try capriVoice.saveAPIKey(key); voiceKeyField?.stringValue = ""; refreshVoiceStatus() }
        catch { voiceStatus?.stringValue = error.localizedDescription }
    }
    @objc func forgetVoiceKey() {
        do { capriVoice.stop(); try capriVoice.forgetAPIKey(); voiceKeyField?.stringValue = ""; refreshVoiceStatus() }
        catch { voiceStatus?.stringValue = error.localizedDescription }
    }
    func refreshVoiceStatus() {
        voiceSpeedSlider?.isEnabled = useCapriVoice
        voiceSpeedValue?.textColor = useCapriVoice ? cyan : .secondaryLabelColor
        voiceStatus?.stringValue = useCapriVoice ? (capriVoice.hasAPIKey ? "Key saved. Test the original Capri voice to check access." : "Original Capri voice selected. Add your ElevenLabs key to enable it.") : "Uses a built-in Mac voice. This is not Capri's original voice."
    }
    @objc func testVoice() {
        setChatVisible(true); showCompanion(focus: false)
        voiceIDChanged(); voice.stopSpeaking(); capriVoice.stop()
        if useCapriVoice { capriVoice.speak("Voice link online. Miss me, choom?") }
        else { voice.speak("Voice link online. Miss me, choom?") }
    }
    @objc func openVoiceKeys() { NSWorkspace.shared.open(URL(string: "https://elevenlabs.io/app/api/api-keys")!) }
    @objc func enableShortcut() { summonShortcut.requestPermission() }
    @objc func motionChanged(_ sender: NSButton) { character.motionEnabled = sender.state == .on; defaults.set(character.motionEnabled, forKey: "motion"); syncInteractionState() }
    @objc func topChanged(_ sender: NSButton) { let on = sender.state == .on; panel.level = on ? .floating : .normal; defaults.set(on, forKey: "alwaysOnTop") }
    @objc func interactionsChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "windowInteractions")
        syncInteractionState(); interactions.setPanelOrigin(panel.frame.origin)
        if sender.state == .off { constrainToScreen() } else { settleIfAppropriate() }
    }
    @objc func sizeChanged(_ sender: NSSlider) { defaults.set(sender.doubleValue, forKey: "size"); applySize(sender.doubleValue); syncInteractionState(); constrainToScreen() }
    func applySize(_ scale: Double) {
        let s = max(0.7, min(scale, 1.15))
        if appearance == .fullBody {
            character.presentation = .standing
            character.frame = NSRect(x: (380 - 220*s)/2, y: 64, width: 220*s, height: 270*s)
            toolbar.frame.origin.y = 23; footer.frame.origin.y = 2
            character.toolTip = "Click to show or hide chat. Drag to move Capri."
        } else if chatVisible {
            character.presentation = .screen
            // Keep the wide portrait inside the panel at the largest setting.
            let screenScale = min(s, 1)
            let width = 356 * screenScale, height = width / 1.74
            character.frame = NSRect(x: (380 - width)/2, y: 332 - height, width: width, height: height)
            toolbar.frame.origin.y = 332 - height - 48
            footer.frame.origin.y = toolbar.frame.minY - 21
            character.toolTip = "Capri's screen. Drag to move. Escape collapses to the star."
        } else {
            character.presentation = .dormant
            character.frame = NSRect(x: (380 - 100*s)/2, y: 64, width: 100*s, height: 130*s)
            character.toolTip = "Click or tap right Command to talk to Capri. Drag to move."
        }
        layoutReplyBubble()
    }
    func renderPreview() {
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let path = CommandLine.arguments.drop(while: { $0 != "--render-preview" }).dropFirst().first ?? "/tmp/capri-preview.png"
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if CommandLine.arguments.contains("--render-preview") {
            character.stopAnimation()
            return
        }
        cancelSpaceArrival()
        if let observer = spaceChangeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        interactions.stop(); savePosition()
        chatGPTAccountTask?.cancel(); ChatGPTAuth.shared.cancelSignIn()
        voice.stopListening(); voice.stopSpeaking(); capriVoice.stop(); summonShortcut.stop(); chatTask?.cancel(); animationTask?.cancel(); mouseTimer?.invalidate(); character.stopAnimation()
        if let hotKey { UnregisterEventHotKey(hotKey) }; if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let visibilityHotKey { UnregisterEventHotKey(visibilityHotKey) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}

@main
struct CapriMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--self-test") {
            precondition(LocalCommand.parse("search YouTube for cyberpunk music") == .youtube("cyberpunk music"))
            precondition(LocalCommand.parse("search for café & robots") == .web("café & robots"))
            precondition(LocalCommand.parse("open Calculator") == .open("calculator"))
            precondition(LocalCommand.parse("open /etc/passwd") == nil)
            precondition(LocalCommand.parse("please delete my files") == nil)
            precondition(LocalCommand.parse("hello") == nil)
            let url = LocalCommand.searchURL(query: "café & cats #1?", youtube: true)
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "café & cats #1?")
            print("PASS: command routing and URL encoding (7 checks)")
            print("Brain: \(CompanionBrain().statusDescription)")
            return
        }
        if CommandLine.arguments.contains("--brain-test") {
            let brain = CompanionBrain(); print(brain.statusDescription)
            do {
                let started = ProcessInfo.processInfo.systemUptime
                print(try await brain.reply(to: "Hello Capri! Say a short hello from my Mac."))
                print("Processing tier: \(brain.chatGPT.lastServiceTier ?? "not reported")")
                print(String(format: "Reply completed in %.1f seconds", ProcessInfo.processInfo.systemUptime - started))
            }
            catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
