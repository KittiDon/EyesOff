import Cocoa
import ServiceManagement

// MARK: - Backlight control
//
// Blanking with a black window still leaves the LCD backlight on, which on an
// LCD panel reads as dark grey rather than black. We additionally drop the
// backlight to zero when we can. Both entry points are private API, so every
// call is guarded and we only ever dim a display whose current brightness we
// managed to read back — that way we always have a value to restore.

private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias CDGet = @convention(c) (CGDirectDisplayID) -> Double
private typealias CDSet = @convention(c) (CGDirectDisplayID, Double) -> Void

final class Backlight {
    private var dsGet: DSGet?
    private var dsSet: DSSet?
    private var cdGet: CDGet?
    private var cdSet: CDSet?
    private var saved: [CGDirectDisplayID: Float] = [:]

    init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let g = dlsym(h, "DisplayServicesGetBrightness"),
               let s = dlsym(h, "DisplayServicesSetBrightness") {
                dsGet = unsafeBitCast(g, to: DSGet.self)
                dsSet = unsafeBitCast(s, to: DSSet.self)
            }
        }
        if let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) {
            if let g = dlsym(h, "CoreDisplay_Display_GetUserBrightness"),
               let s = dlsym(h, "CoreDisplay_Display_SetUserBrightness") {
                cdGet = unsafeBitCast(g, to: CDGet.self)
                cdSet = unsafeBitCast(s, to: CDSet.self)
            }
        }
    }

    var isAvailable: Bool { (dsGet != nil && dsSet != nil) || (cdGet != nil && cdSet != nil) }

    private func read(_ id: CGDirectDisplayID) -> Float? {
        if let get = dsGet {
            var value: Float = 0
            if get(id, &value) == 0, value.isFinite, value >= 0, value <= 1 { return value }
        }
        if let get = cdGet {
            let value = Float(get(id))
            if value.isFinite, value >= 0, value <= 1 { return value }
        }
        return nil
    }

    private func write(_ id: CGDirectDisplayID, _ value: Float) {
        let clamped = max(0, min(1, value))
        if let set = dsSet, set(id, clamped) == 0 { return }
        cdSet?(id, Double(clamped))
    }

    private var displayIDs: [CGDirectDisplayID] {
        NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
    }

    /// Mirror of `saved` on disk. If we're killed while dimmed, the next launch
    /// finds this and puts the brightness back instead of stranding the user
    /// at a black-but-awake screen.
    private static let stashKey = "dimmedBrightnessStash"

    func dim() {
        guard isAvailable else { return }
        for id in displayIDs {
            guard let current = read(id) else { continue }   // can't read -> never touch it
            saved[id] = current
            write(id, 0)
        }
        let stash = saved.reduce(into: [String: Float]()) { $0["\($1.key)"] = $1.value }
        UserDefaults.standard.set(stash, forKey: Backlight.stashKey)
    }

    func restore() {
        for (id, value) in saved { write(id, value) }
        saved.removeAll()
        UserDefaults.standard.removeObject(forKey: Backlight.stashKey)
    }

    /// Called once at launch to recover from a previous crash mid-blank.
    func restoreStashIfNeeded() {
        guard let stash = UserDefaults.standard.dictionary(forKey: Backlight.stashKey) as? [String: Float],
              !stash.isEmpty else { return }
        for (key, value) in stash {
            if let id = UInt32(key) { write(id, value) }
        }
        UserDefaults.standard.removeObject(forKey: Backlight.stashKey)
    }

    var hasDimmedDisplays: Bool { !saved.isEmpty }

    func currentPrimaryBrightness() -> Float {
        guard let id = displayIDs.first else { return -1 }
        return read(id) ?? -1
    }
}

/// Restores brightness from the on-disk stash. Written as a free function with
/// no captured state so it can be called from a signal handler after a crash,
/// when the app's objects can no longer be trusted.
func emergencyRestoreBrightness() {
    guard let stash = UserDefaults.standard.dictionary(forKey: "dimmedBrightnessStash") as? [String: Float],
          !stash.isEmpty,
          let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesSetBrightness") else { return }
    let set = unsafeBitCast(sym, to: DSSet.self)
    for (key, value) in stash {
        if let id = UInt32(key) { _ = set(id, value) }
    }
    UserDefaults.standard.removeObject(forKey: "dimmedBrightnessStash")
    UserDefaults.standard.synchronize()
}

// MARK: - The black window

/// Borderless windows refuse key status by default, and we need key status so
/// keystrokes reach us without asking the user for Accessibility permission.
final class BlackWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [BlackWindow] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let backlight = Backlight()

    private var isBlanked = false
    private var armedAt: Date = .distantPast
    private var signalSources: [DispatchSourceSignal] = []

    /// Input arriving in this window after blanking is ignored, so the release
    /// of the very click that blanked the screen doesn't wake it straight back up.
    private let graceInterval: TimeInterval = 0.45

    private let dimKey = "dimBacklight"

    private var dimsBacklight: Bool {
        get {
            if UserDefaults.standard.object(forKey: dimKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: dimKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: dimKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        backlight.restoreStashIfNeeded()
        installSafetyNet()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = "Click to black out the screen — any activity brings it back"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setIcon(blanked: false)

        // Anything that would leave the screen in a weird state must put the
        // backlight back first.
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(systemWillSleep),
                             name: NSWorkspace.willSleepNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(systemWillSleep),
                             name: NSWorkspace.willPowerOffNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        if CommandLine.arguments.contains("--enable-login") {
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                print("[login] status: \(describe(SMAppService.mainApp.status))")
            } catch {
                print("[login] register failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
            return
        }

        if ProcessInfo.processInfo.environment["EYESOFF_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runSelfTest() }
        }
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:           return "enabled"
        case .notRegistered:     return "notRegistered"
        case .notFound:          return "notFound"
        case .requiresApproval:  return "requiresApproval (approve in System Settings > General > Login Items)"
        @unknown default:        return "unknown"
        }
    }

    /// If we're terminated while the backlight is down, put it back up.
    private func installSafetyNet() {
        // A crash while dimmed would otherwise leave the screen dark until the
        // next launch, so recover on the way down too.
        NSSetUncaughtExceptionHandler { _ in emergencyRestoreBrightness() }
        for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGFPE, SIGTRAP] {
            signal(sig) { _ in
                emergencyRestoreBrightness()
                signal(SIGSEGV, SIG_DFL)
                abort()
            }
        }

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.backlight.restore()
                exit(0)
            }
            source.resume()
            signal(sig, SIG_IGN)
            signalSources.append(source)
        }
    }

    private func makeMouseEvent(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100),
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: windows.first?.windowNumber ?? 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private func runSelfTest() {
        print("[selftest] blanking…")
        let brightnessBefore = self.backlight.currentPrimaryBrightness()
        blank()
        print("[selftest] screens covered: \(self.windows.count) (expected \(NSScreen.screens.count))")
        print("[selftest] backlight dimmed: \(self.backlight.hasDimmedDisplays)")
        print("[selftest] brightness before=\(brightnessBefore) while blanked=\(self.backlight.currentPrimaryBrightness())")

        // The monitor mask decides what is ever delivered to us at all.
        let mask = AppDelegate.wakeMask
        print("[selftest] mask excludes mouseMoved: \(!mask.contains(.mouseMoved)) (expected true)")
        print("[selftest] mask excludes scrollWheel: \(!mask.contains(.scrollWheel)) (expected true)")
        print("[selftest] mask excludes drags: \(!mask.contains(.leftMouseDragged)) (expected true)")
        print("[selftest] mask includes leftMouseDown: \(mask.contains(.leftMouseDown)) (expected true)")
        print("[selftest] mask includes keyDown: \(mask.contains(.keyDown)) (expected true)")

        // Wait out the grace period, then feed real NSEvents straight to the handler.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // NSEvent.mouseEvent(with:) accepts plain mouse types only — feeding it
            // .scrollWheel or tracking types like .mouseExited segfaults, so
            // those are covered by the mask assertions above instead.
            for (label, type) in [("mouseMoved", NSEvent.EventType.mouseMoved),
                                  ("leftMouseDragged", .leftMouseDragged),
                                  ("rightMouseDragged", .rightMouseDragged)] {
                guard let event = self.makeMouseEvent(type) else {
                    print("[selftest] could not build \(label) event — skipped")
                    continue
                }
                _ = self.feedForTest(event)
                print("[selftest] after \(label) still blanked: \(self.isBlanked) (expected true)")
            }

            if let click = self.makeMouseEvent(.leftMouseDown) {
                _ = self.feedForTest(click)
            }
            print("[selftest] woke on click: \(!self.isBlanked) (expected true)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                print("[selftest] brightness after restore=\(self.backlight.currentPrimaryBrightness()) (expected \(brightnessBefore))")
                print("[selftest] windows after restore: \(self.windows.count) (expected 0)")
                print("[selftest] stash cleared: \(UserDefaults.standard.object(forKey: "dimmedBrightnessStash") == nil)")
                self.backlight.restore()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backlight.restore()
    }

    @objc private func systemWillSleep() {
        if isBlanked { unblank() }
    }

    @objc private func screensChanged() {
        // Display layout changed while blanked: rebuild so no screen is left uncovered.
        if isBlanked {
            unblank()
            blank()
        }
    }

    // MARK: Menu bar interaction

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            blank()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let blankItem = NSMenuItem(title: "Black Out Screen", action: #selector(blankFromMenu), keyEquivalent: "")
        blankItem.target = self
        menu.addItem(blankItem)

        menu.addItem(.separator())

        let dimItem = NSMenuItem(title: "Also Turn Off Backlight", action: #selector(toggleDim), keyEquivalent: "")
        dimItem.target = self
        dimItem.state = dimsBacklight ? .on : .off
        dimItem.isEnabled = backlight.isAvailable
        if !backlight.isAvailable {
            dimItem.toolTip = "Not supported on this display"
        }
        menu.addItem(dimItem)

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "Click the eyes to black out · any key, click or",
                                   action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)
        let aboutItem2 = NSMenuItem(title: "mouse move brings it back exactly as it was",
                                    action: nil, keyEquivalent: "")
        aboutItem2.isEnabled = false
        menu.addItem(aboutItem2)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit EyesOff", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore plain click-to-blank behaviour
    }

    @objc private func blankFromMenu() { blank() }

    @objc private func toggleDim() {
        dimsBacklight.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func quit() {
        if isBlanked { unblank() }
        backlight.restore()
        NSApp.terminate(nil)
    }

    /// Template images render monochrome and invert automatically, so the icon
    /// matches Wi-Fi/battery/Bluetooth in both light and dark menu bars.
    private func setIcon(blanked: Bool) {
        guard let button = statusItem.button else { return }
        let name = blanked ? "eye.slash" : "eyes"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "EyesOff")?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = blanked ? "🙈" : "👀"   // fallback if the symbol is unavailable
        }
    }

    // MARK: Blanking

    private func blank() {
        guard !isBlanked else { return }
        let screens = NSScreen.screens
        // Without a cover window there is nothing to click to get back, so
        // never enter the blanked state at all.
        guard !screens.isEmpty else { NSSound.beep(); return }

        isBlanked = true
        armedAt = Date()

        for screen in screens {
            let window = BlackWindow(contentRect: screen.frame,
                                     styleMask: .borderless,
                                     backing: .buffered,
                                     defer: false)
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)

        let mask = AppDelegate.wakeMask
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            _ = self?.handle(event)
        }

        NSCursor.hide()
        if dimsBacklight { backlight.dim() }

        setIcon(blanked: true)
    }

    /// The only input that brings the screen back: clicks and real keypresses.
    /// Deliberately excludes mouseMoved, drags, scrollWheel and flagsChanged, so
    /// a bumped trackpad or a nudged mouse can't wake it.
    static let wakeMask: NSEvent.EventTypeMask = [
        .keyDown,
        .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    private static func isWakeEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: return true
        default: return false
        }
    }

    /// Returns true when the event woke the screen (and should be swallowed).
    private func handle(_ event: NSEvent) -> Bool {
        guard isBlanked else { return false }
        // Belt and braces: the monitor mask should already exclude these, but
        // never wake on anything that isn't an explicit click or keypress.
        guard AppDelegate.isWakeEvent(event.type) else { return false }
        guard Date().timeIntervalSince(armedAt) > graceInterval else { return true }

        unblank()
        return true
    }

    /// Exposed for the self-test.
    fileprivate func feedForTest(_ event: NSEvent) -> Bool { handle(event) }

    private func unblank() {
        guard isBlanked else { return }
        isBlanked = false

        // Backlight first, so the screen is already lit behind the black cover
        // and the desktop doesn't fade in.
        backlight.restore()

        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }

        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        NSCursor.unhide()
        setIcon(blanked: false)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
