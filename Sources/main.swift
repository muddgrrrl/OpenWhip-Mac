import AppKit
import ApplicationServices
import Carbon

final class OpenWhip: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var item: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var panel: WhipPanel?
    private var whip: WhipView?
    private var target: DeliveryTarget?
    private var alreadySent = false
    private var lastStatus = "Ready"
    private enum HotKey: UInt32 {
        case whip = 1
        case keyboardTest = 2
        case pasteTest = 3
    }

    private var whipHotKey: EventHotKeyRef?
    private var testHotKey: EventHotKeyRef?
    private var pasteHotKey: EventHotKeyRef?
    private var awaitingTest = false
    private var hotKeyHandler: EventHandlerRef?
    private var gesture = UUID()
    private var lastExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuIcon()
        item.button?.image?.isTemplate = true
        item.button?.action = #selector(statusClick)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatus("Ready")
        installHotKeys()
        if CommandLine.arguments.contains("--smoke-test") {
            showSettings()
            showMisc()
            toggleWhip()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self, self.settingsWindow?.isVisible == true,
                      let tabs = self.settingsWindow?.contentViewController as? NSTabViewController,
                      tabs.tabViewItems.map(\.label) == ["Allowed Apps", "Misc"],
                      tabs.selectedTabViewItemIndex == 1,
                      self.panel?.isVisible == true, self.whip != nil else { exit(1) }
                self.whip?.drop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
                    guard self.panel == nil else { exit(1) }
                    print("PASS: settings window, whip panel, drop animation and cleanup")
                    exit(0)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let whipHotKey { UnregisterEventHotKey(whipHotKey) }
        if let testHotKey { UnregisterEventHotKey(testHotKey) }
        if let pasteHotKey { UnregisterEventHotKey(pasteHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        whip?.stop()
    }

    @objc private func statusClick() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
                lastExternalApp = app
            }
            let menu = NSMenu()
            addItem(panel == nil ? "Pick Up Whip" : "Drop Whip", #selector(toggleWhip), to: menu,
                    key: whipHotKey == nil ? "" : "w")
            addItem("Test Typing", #selector(testTyping), to: menu, key: testHotKey == nil ? "" : "t")
            addItem("Test Paste", #selector(testPasting), to: menu, key: pasteHotKey == nil ? "" : "p")
            menu.addItem(.separator())
            let statusItem = NSMenuItem(title: lastStatus, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            if let app = lastExternalApp, let id = app.bundleIdentifier,
               !settings.apps.contains(where: { $0.id == id }), let name = app.localizedName {
                addItem("Allow \(name)…", #selector(allowCurrentApp), to: menu)
            }
            addItem("Settings…", #selector(showSettings), to: menu)
            addItem("Misc…", #selector(showMisc), to: menu)
            menu.addItem(.separator())
            addItem("Quit OpenWhip", #selector(quit), to: menu)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
        } else {
            toggleWhip()
        }
    }

    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if !key.isEmpty { entry.keyEquivalentModifierMask = [.control, .option] }
        menu.addItem(entry)
    }

    @objc private func allowCurrentApp() {
        guard let app = lastExternalApp, let id = app.bundleIdentifier, let name = app.localizedName else { return }
        dismissWhip()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow nudges in \(name)?"
        alert.informativeText = "When \(name) has focus, cracking the whip can type and submit a prompt in its focused text input."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.allow(id: id, name: name)
            showSettings()
        }
    }

    @objc func toggleWhip() {
        if let whip {
            whip.drop()
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            updateStatus("No display available")
            return
        }
        gesture = UUID()
        alreadySent = false
        target = nil
        if !settings.effects.nudgesEnabled {
            updateStatus("Effects only · chat nudges are off")
        } else if settings.nudgeText == nil {
            updateStatus("Effects only · add your custom prompt in Misc")
        } else if !CommandLine.arguments.contains("--smoke-test"),
           let app = NSWorkspace.shared.frontmostApplication,
           let rule = settings.apps.first(where: { $0.id == app.bundleIdentifier }) {
            if AXIsProcessTrusted() {
                target = DeliveryTarget(app: app, rule: rule)
                if let target {
                    updateStatus(target.usesWindowFocus ? "Ready · use the focused Codex message box" : "Ready to nudge \(rule.name)")
                } else {
                    updateStatus("Focus an input in \(rule.name), then pick up again")
                }
            } else {
                updateStatus("Grant Accessibility in Settings to send nudges")
            }
        } else if AXIsProcessTrusted() {
            updateStatus("Effects only · allow the app in Settings to send nudges")
        } else {
            updateStatus("Effects only · open Settings to enable nudges")
        }

        let overlay = WhipPanel(screen: screen)
        let view = WhipView(frame: CGRect(origin: .zero, size: screen.frame.size), effects: settings.effects)
        view.onCrack = { [weak self] in self?.sendNudge() }
        view.onDrop = { [weak self] in self?.panel?.ignoresMouseEvents = true }
        view.onFinish = { [weak self] in self?.dismissWhip() }
        overlay.contentView = view
        panel = overlay
        whip = view
        overlay.orderFrontRegardless()
        view.start()
    }

    private func sendNudge() {
        guard settings.effects.nudgesEnabled, let target, let message = settings.nudgeText, !alreadySent else { return }
        guard stillAllowed(target) else {
            updateStatus("Nudge skipped · focus or app permission changed")
            return
        }
        alreadySent = true
        if target.rule.mode == .interrupt {
            guard target.interrupt() else {
                updateStatus("Could not send Ctrl-C")
                return
            }
            let currentGesture = gesture
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, currentGesture == self.gesture, self.stillAllowed(target) else { return }
                self.submit(message, to: target)
            }
        } else {
            submit(message, to: target)
        }
    }

    private func stillAllowed(_ target: DeliveryTarget) -> Bool {
        settings.apps.contains(target.rule) && target.isCurrent()
    }

    private func submit(_ message: String, to target: DeliveryTarget) {
        guard settings.effects.nudgesEnabled else { return }
        if !CGPreflightPostEventAccess() {
            updateStatus("Keyboard posting blocked · check Accessibility")
        } else {
            updateStatus(target.submit(message) ? "Nudge keys posted to \(target.rule.name)" : "Could not send nudge")
        }
    }

    private func dismissWhip() {
        whip?.stop()
        panel?.orderOut(nil)
        whip = nil
        panel = nil
        target = nil
    }

    private func updateStatus(_ status: String) {
        lastStatus = status
        item.button?.toolTip = "OpenWhip — \(status)\nClick to pick up or drop. Right-click for Settings."
        item.button?.setAccessibilityLabel("OpenWhip")
    }

    @objc private func showSettings() { presentSettings(tab: 0) }

    @objc private func showMisc() { presentSettings(tab: 1) }

    private func presentSettings(tab: Int) {
        gesture = UUID()
        dismissWhip()
        if settingsWindow == nil {
            let controller = NSTabViewController()
            controller.tabStyle = .segmentedControlOnTop
            let apps = NSTabViewItem(viewController: SettingsController(settings: settings))
            apps.label = "Allowed Apps"
            controller.addTabViewItem(apps)
            let misc = NSTabViewItem(viewController: MiscSettingsController(settings: settings))
            misc.label = "Misc"
            controller.addTabViewItem(misc)

            let window = NSWindow(contentViewController: controller)
            window.title = "OpenWhip Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 570, height: 406))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        if let tabs = settingsWindow?.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = tab
            if tab == 0 { (tabs.tabViewItems[0].viewController as? SettingsController)?.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func menuIcon() -> NSImage {
        NSImage(size: NSSize(width: 19, height: 19), flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: 3, y: 3))
            path.curve(to: NSPoint(x: 5, y: 10), controlPoint1: NSPoint(x: 15, y: 5), controlPoint2: NSPoint(x: 16, y: 16))
            path.curve(to: NSPoint(x: 16, y: 16), controlPoint1: NSPoint(x: 0, y: 6), controlPoint2: NSPoint(x: 1, y: 17))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
    }

    private func installHotKeys() {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handler = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4F574850, let kind = HotKey(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            guard NSApp.modalWindow == nil else { return noErr }
            let app = Unmanaged<OpenWhip>.fromOpaque(context).takeUnretainedValue()
            if kind == .whip && GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                app.toggleWhip()
            } else if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                if kind == .keyboardTest { app.testTyping() }
                if kind == .pasteTest { app.testPasting() }
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        guard handler == noErr else { return }
        RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: 0x4F574850, id: HotKey.whip.rawValue),
                            GetApplicationEventTarget(), 0, &whipHotKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: 0x4F574850, id: HotKey.keyboardTest.rawValue),
                            GetApplicationEventTarget(), 0, &testHotKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: 0x4F574850, id: HotKey.pasteTest.rawValue),
                            GetApplicationEventTarget(), 0, &pasteHotKey)
    }

    @objc private func testTyping() { tryTextInput(usePaste: false) }

    @objc private func testPasting() { tryTextInput(usePaste: true) }

    private func tryTextInput(usePaste: Bool) {
        guard !awaitingTest else { return }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            updateStatus("Typing test blocked · enable Accessibility")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let rule = settings.apps.first(where: { $0.id == app.bundleIdentifier }) else {
            updateStatus("Typing test skipped · allow the foreground app in Settings")
            return
        }
        guard rule.mode == .chat, let target = DeliveryTarget(app: app, rule: rule) else {
            updateStatus("Typing test skipped · focus a text box in an allowed Chat app")
            return
        }
        awaitingTest = true
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        waitForShortcutRelease(target: target, deadline: deadline, usePaste: usePaste)
    }

    private func waitForShortcutRelease(target: DeliveryTarget, deadline: TimeInterval, usePaste: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
            guard let self else { return }
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
            if !modifiers.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty {
                if ProcessInfo.processInfo.systemUptime < deadline {
                    self.waitForShortcutRelease(target: target, deadline: deadline, usePaste: usePaste)
                } else {
                    self.awaitingTest = false
                    self.updateStatus("Typing test skipped · release the shortcut keys")
                }
                return
            }
            self.awaitingTest = false
            guard self.stillAllowed(target) else {
                self.updateStatus("Typing test skipped · focus or app permission changed")
                return
            }
            let delivered = usePaste ? target.pasteKeyboardTest() : target.typeKeyboardTest()
            let action = usePaste ? "Paste requested" : "Test keys posted"
            self.updateStatus(delivered
                ? "\(action) in \(target.rule.name) · Return was not sent"
                : "Input test blocked · check Accessibility and text box focus")
        }
    }
}

if CommandLine.arguments.contains("--diagnose") {
    print("Accessibility: \(AXIsProcessTrusted()); keyboard posting: \(CGPreflightPostEventAccess())")
    if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier {
        print("Foreground app: \(id); allowed: \(Settings().apps.contains(where: { $0.id == id }))")
        if AXIsProcessTrusted() { print(DeliveryTarget.diagnostics(app: app)) }
    }
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    precondition(WhipView.qualifies(age: 0.7, sinceSwing: 0.1, sinceCrack: 1, tipTravel: 58))
    precondition(!WhipView.qualifies(age: 0.2, sinceSwing: 0.1, sinceCrack: 1, tipTravel: 58))
    precondition(!WhipView.qualifies(age: 0.7, sinceSwing: 0.4, sinceCrack: 1, tipTravel: 58))
    precondition(!WhipView.qualifies(age: 0.7, sinceSwing: 0.1, sinceCrack: 0.2, tipTravel: 58))
    let testEvents = DeliveryTarget.textKeyEvents(DeliveryTarget.keyboardTestText)!
    precondition(testEvents.count == DeliveryTarget.keyboardTestText.utf16.count * 2)
    precondition(testEvents.allSatisfy {
        $0.getIntegerValueField(.keyboardEventKeycode) != kVK_Return && $0.flags.isEmpty
    })
    precondition(NudgePhrase.allCases.compactMap(\.preset).allSatisfy { DeliveryTarget.textKeyEvents($0) != nil })
    precondition(WhipView.qualifies(age: 0.7, sinceSwing: 0.1, sinceCrack: 1, tipTravel: 17, sensitivity: .easy))
    precondition(!WhipView.qualifies(age: 0.7, sinceSwing: 0.1, sinceCrack: 1, tipTravel: 17))
    precondition(!WhipView.qualifies(age: 0.7, sinceSwing: 0.1, sinceCrack: 1, tipTravel: 29, sensitivity: .hard))
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("previous contents", forType: .string)
    precondition(PasteTest.run(on: pasteboard, text: DeliveryTarget.keyboardTestText) {
        pasteboard.string(forType: .string) == DeliveryTarget.keyboardTestText
    })
    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
    precondition(pasteboard.string(forType: .string) == "previous contents")
    pasteboard.releaseGlobally()
    let suite = "OpenWhip-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = Settings(defaults: defaults)
    precondition(settings.apps.isEmpty)
    precondition(settings.effects == WhipPreferences())
    settings.effects = WhipPreferences(sensitivity: .easy, style: .rainbow, phrase: .buzzBuzz,
                                      soundEnabled: false, nudgesEnabled: false)
    precondition(Settings(defaults: defaults).effects == settings.effects)
    let customPrompt = "  Finish step #2: café? 🐝\nThen test it.  "
    settings.customPrompt = customPrompt
    settings.effects.phrase = .custom
    let reloaded = Settings(defaults: defaults)
    precondition(reloaded.effects.style == .rainbow)
    precondition(reloaded.customPrompt == customPrompt)
    let expectedMessage = "Finish step #2: café? 🐝 Then test it."
    precondition(reloaded.nudgeText == expectedMessage)
    let customEvents = DeliveryTarget.textKeyEvents(expectedMessage)!
    let typedCharacters = customEvents.filter { $0.type == .keyDown }.map { event in
        var count = 0
        var units = [UInt16](repeating: 0, count: expectedMessage.utf16.count)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        return String(decoding: units.prefix(count), as: UTF16.self)
    }
    precondition(typedCharacters.joined() == expectedMessage)
    settings.customPrompt = " \t "
    precondition(settings.nudgeText == nil)
    settings.customPrompt = customPrompt
    settings.effects.phrase = .buzzBuzz
    precondition(settings.nudgeText == NudgePhrase.buzzBuzz.preset)
    precondition(Settings(defaults: defaults).customPrompt == customPrompt)
    settings.allow(id: "test.Editor", name: "Editor")
    settings.allow(id: "test.Editor", name: "Duplicate")
    settings.apps[0].mode = .interrupt
    precondition(Settings(defaults: defaults).apps == [AllowedApp(id: "test.Editor", name: "Editor", mode: .interrupt)])
    settings.apps.removeAll()
    precondition(Settings(defaults: defaults).apps.isEmpty)
    defaults.removePersistentDomain(forName: suite)
    print("PASS: gesture gating, keyboard events, and app settings persistence")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = OpenWhip()
app.delegate = delegate
app.run()
