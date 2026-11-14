// =============================================================================
// DockKeeper
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
//   - Holding Control + Option lets the cursor through, in case you ever WANT
//     to move the Dock on purpose (idea borrowed from DockLock).
//   - Display changes (plug/unplug, rearrange) are picked up automatically.
//
// MENU BAR
//   Lock icon = active, open lock = paused. Menu has Pause, Launch at Login,
//   Help (opens the README on GitHub), and Quit. While waiting for
//   permission, the status line opens the Accessibility settings.
//
// PERMISSIONS
//   Needs Accessibility (System Settings > Privacy & Security > Accessibility)
//   because it modifies mouse events. It waits and starts automatically once
//   permission is granted.
// =============================================================================

import Cocoa
import ServiceManagement

final class Keeper {
    var displayRects: [CGRect] = []
    var guardedRects: [CGRect] = []   // every display except the Dock's home
    var paused = false
    var tap: CFMachPort?

    func rebuildDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let home = CGMainDisplayID()
        let active = Array(ids.prefix(Int(count)))
        displayRects = active.map { CGDisplayBounds($0) }
        guardedRects = active.filter { $0 != home }.map { CGDisplayBounds($0) }
    }

    /// Returns a corrected point if `p` is touching a guarded bottom edge.
    func clamp(_ p: CGPoint) -> CGPoint? {
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
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }
}

let keeper = Keeper()

// By default macOS ignores real mouse input for ~0.25s after any cursor warp.
// Pushing against the edge re-warps constantly, which froze the cursor.
// Setting the suppression interval to zero removes that freeze.
let warpSource: CGEventSource? = {
    let s = CGEventSource(stateID: .combinedSessionState)
    s?.localEventsSuppressionInterval = 0
    return s
}()

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // macOS disables slow or interrupted taps; turn it straight back on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = keeper.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if keeper.paused { return Unmanaged.passUnretained(event) }
    if event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate) {
        return Unmanaged.passUnretained(event)   // deliberate override
    }
    if let fixed = keeper.clamp(event.location) {
        event.location = fixed
        _ = warpSource
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
        let on = keeper.tap != nil && !keeper.paused
        statusItem.button?.image = NSImage(systemSymbolName: on ? "lock.fill" : "lock.open",
                                           accessibilityDescription: "DockKeeper")
        if keeper.tap != nil {
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
