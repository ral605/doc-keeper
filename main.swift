// =============================================================================
// DockKeeper 1.1
// Keeps the macOS Dock on one display (the main display, the one with the
// menu bar) so it never jumps to another monitor.
//
// HOW IT WORKS
//   macOS moves the Dock to another display when the cursor hits that
//   display's bottom edge and keeps pushing down. DockKeeper installs a
//   session-level mouse event tap. Whenever the cursor tries to reach the
//   bottom edge of any display other than the main one, it is held 2 points
//   above that edge. The Dock never sees the trigger, so it stays put.
//   No system files are modified and nothing is injected into the Dock.
//
//   - Edges with another display directly below them are left alone, so the
//     cursor can still travel between stacked monitors.
//   - Mirrored displays are ignored.
//   - Holding Control + Option lets the cursor through, in case you ever WANT
//     to move the Dock on purpose (idea borrowed from DockLock).
//   - Display changes (plug/unplug, rearrange) are picked up automatically.
//
// SAFETY (added in 1.1)
//   - Mouse events are handled on their own high-priority thread, never on
//     the menu/UI thread, so a busy UI can't stall the mouse.
//   - If macOS reports the tap falling behind 3 times within a minute,
//     DockKeeper switches itself off and lets every event through. The menu
//     then shows "Stopped for safety". Quit and reopen to try again.
//
// MENU BAR
//   Lock icon = active, open lock = paused, warning triangle = stopped for
//   safety. Menu has Pause, Launch at Login, Help (opens the README on
//   GitHub), and Quit. While waiting for permission, the status line opens
//   the Accessibility settings.
//
// PERMISSIONS
//   Needs Accessibility (System Settings > Privacy & Security > Accessibility)
//   because it modifies mouse events. It waits and starts automatically once
//   permission is granted.
// =============================================================================

import Cocoa
import ServiceManagement

final class Keeper {
    private let lock = NSLock()
    private var displayRects: [CGRect] = []
    private var guardedRects: [CGRect] = []   // every display except the Dock's home
    private var _paused = false
    private var _stopped = false               // safety shutoff tripped
    private var timeoutTimes: [Date] = []
    var tap: CFMachPort?
    var onSafetyStop: (() -> Void)?

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

    func rebuildDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let home = CGMainDisplayID()
        let homeRect = CGDisplayBounds(home)
        // Skip displays that mirror another display.
        let active = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let rects = active.map { CGDisplayBounds($0) }
        let guarded = active.filter { $0 != home }
                            .map { CGDisplayBounds($0) }
                            .filter { $0 != homeRect }
        lock.lock(); displayRects = rects; guardedRects = guarded; lock.unlock()
    }

    /// Returns a corrected point if `p` is touching a guarded bottom edge.
    func clamp(_ p: CGPoint) -> CGPoint? {
        lock.lock(); defer { lock.unlock() }
        if _paused || _stopped { return nil }
        for r in guardedRects where p.x >= r.minX && p.x < r.maxX && p.y >= r.minY {
            let limit = r.maxY - 2
            guard p.y > limit else { return nil }
            // Another display directly below? Then this is a passage, not an edge.
            let below = CGPoint(x: p.x, y: r.maxY + 0.5)
            if displayRects.contains(where: { $0.contains(below) }) { return nil }
            return CGPoint(x: p.x, y: limit)
        }
        return nil
    }

    /// Called when macOS disables the tap for being too slow.
    /// Returns true if the tap should be turned back on.
    func recordTimeout() -> Bool {
        lock.lock()
        let now = Date()
        timeoutTimes = timeoutTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if timeoutTimes.count >= 3 { _stopped = true }
        let stop = _stopped
        lock.unlock()
        if stop { DispatchQueue.main.async { self.onSafetyStop?() } }
        return !stop
    }

    func startTap() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged,
                                    .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: tapCallback,
                                        userInfo: nil) else { return false }
        tap = t
        // Run the tap on its own thread so the UI thread can never stall the mouse.
        let thread = Thread {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        thread.name = "DockKeeper.eventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }
}

let keeper = Keeper()

// By default macOS ignores real mouse input for ~0.25s after any cursor warp.
// Pushing against the edge re-warps constantly, which froze the cursor.
// Setting the suppression interval to zero removes that freeze.
// Created once at launch, never inside the event callback.
let warpSource: CGEventSource? = {
    let s = CGEventSource(stateID: .combinedSessionState)
    s?.localEventsSuppressionInterval = 0
    return s
}()

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout {
        // Too slow: re-enable unless the safety shutoff has tripped.
        if let t = keeper.tap, keeper.recordTimeout() { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByUserInput {
        if let t = keeper.tap, !keeper.stopped { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate) {
        return Unmanaged.passUnretained(event)   // deliberate override
    }
    if let fixed = keeper.clamp(event.location) {
        event.location = fixed
        CGWarpMouseCursorPosition(fixed)
        CGAssociateMouseAndMouseCursorPosition(1)  // re-link mouse to cursor right away
    }
    return Unmanaged.passUnretained(event)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = warpSource   // create the event source up front
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(.separator())
        pauseItem.target = self; loginItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let helpItem = NSMenuItem(title: "Help…", action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)
        menu.addItem(NSMenuItem(title: "Quit DockKeeper", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        keeper.rebuildDisplays()
        keeper.onSafetyStop = { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in keeper.rebuildDisplays() }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        tryStart()
        refresh()
    }

    func tryStart() {
        if keeper.startTap() {
            stateItem.action = nil   // plain status label once running
            refresh(); return
        }
        stateItem.title = "Needs Accessibility permission (click to open)"
        stateItem.target = self
        stateItem.action = #selector(openAccessibility)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.tryStart() }
    }

    func refresh() {
        let symbol: String
        if keeper.stopped { symbol = "exclamationmark.triangle" }
        else if keeper.tap != nil && !keeper.paused { symbol = "lock.fill" }
        else { symbol = "lock.open" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DockKeeper")
        if keeper.stopped {
            stateItem.title = "Stopped for safety (quit and reopen to retry)"
        } else if keeper.tap != nil {
            stateItem.title = keeper.paused ? "Paused: Dock can move" : "Dock locked to main display"
        }
        pauseItem.state = keeper.paused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func togglePause() { keeper.paused.toggle(); refresh() }

    @objc func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/ral605/doc-keeper#readme")!)
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, no app switcher entry
app.run()
