import AppKit
import ApplicationServices
import Carbon

enum AppMode: String, Codable, CaseIterable, Identifiable {
    case chat = "Chat"
    case terminal = "Terminal"
    case interrupt = "Terminal + Ctrl-C"
    var id: Self { self }
}

struct AllowedApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var mode: AppMode = .chat
}

final class Settings {
    var apps: [AllowedApp] {
        didSet {
            if let data = try? JSONEncoder().encode(apps) {
                defaults.set(data, forKey: "allowedApplications")
            }
        }
    }
    var effects: WhipPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(effects) {
                defaults.set(data, forKey: "whipPreferences")
            }
        }
    }
    var customPrompt: String {
        didSet { defaults.set(customPrompt, forKey: "customPrompt") }
    }

    var nudgeText: String? {
        if let preset = effects.phrase.preset { return preset }
        // Keep the prompt on one line so embedded control characters cannot submit it early.
        let text = String(customPrompt.map { character in
            character.isNewline || character.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
                ? " " : character
        }).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customPrompt = defaults.string(forKey: "customPrompt") ?? ""
        apps = defaults.data(forKey: "allowedApplications")
            .flatMap { try? JSONDecoder().decode([AllowedApp].self, from: $0) } ?? []
        effects = defaults.data(forKey: "whipPreferences")
            .flatMap { try? JSONDecoder().decode(WhipPreferences.self, from: $0) } ?? WhipPreferences()
    }

    func allow(id: String, name: String) {
        guard id != Bundle.main.bundleIdentifier, !apps.contains(where: { $0.id == id }) else { return }
        apps.append(AllowedApp(id: id, name: name))
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct DeliveryTarget {
    static let keyboardTestText = "openwhip test"
    let rule: AllowedApp
    let process: pid_t
    private let application: AXUIElement
    private let window: AXUIElement
    private let field: AXUIElement?
    let usesWindowFocus: Bool

    init?(app: NSRunningApplication, rule: AllowedApp) {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = Self.element(application, kAXFocusedWindowAttribute) else { return nil }

        let focus = Self.focusedElement(in: application, window: window)
        let field = rule.mode == .chat ? Self.editableInput(from: focus) : nil
        let usesWindowFocus = rule.mode == .chat && field == nil
        if usesWindowFocus {
            guard rule.id == "com.openai.codex", Self.allowsCodexWindowFocus(focus) else { return nil }
        }
        self.rule = rule
        process = app.processIdentifier
        self.application = application
        self.window = window
        self.field = field
        self.usesWindowFocus = usesWindowFocus
    }

    func isCurrent() -> Bool {
        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == process,
              front.bundleIdentifier == rule.id,
              let focusedWindow = Self.element(application, kAXFocusedWindowAttribute),
              CFEqual(window, focusedWindow) else { return false }
        if let field {
            let focus = Self.focusedElement(in: application, window: focusedWindow)
            guard let focusedField = Self.editableInput(from: focus), CFEqual(field, focusedField) else { return false }
        }
        if usesWindowFocus {
            let focus = Self.focusedElement(in: application, window: focusedWindow)
            return Self.allowsCodexWindowFocus(focus) || Self.editableInput(from: focus) != nil
        }
        return true
    }

    private static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func isSettable(_ element: AXUIElement, _ key: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, key as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func focusedElement(in application: AXUIElement, window: AXUIElement) -> AXUIElement? {
        if let direct = element(application, kAXFocusedUIElementAttribute)
            ?? element(window, kAXFocusedUIElementAttribute) {
            return direct
        }
        if let systemFocus = element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
            var appPID: pid_t = 0
            var focusPID: pid_t = 0
            if AXUIElementGetPid(application, &appPID) == .success,
               AXUIElementGetPid(systemFocus, &focusPID) == .success,
               appPID == focusPID {
                return systemFocus
            }
        }
        return nil
    }

    private static func allowsCodexWindowFocus(_ focus: AXUIElement?) -> Bool {
        guard !IsSecureEventInputEnabled() else { return false }
        guard let focus else { return true }
        let role = attribute(focus, kAXRoleAttribute) as? String
        return role == "AXWebArea" || role == kAXWindowRole || role == kAXApplicationRole
    }

    private static func editableInput(from focus: AXUIElement?) -> AXUIElement? {
        var candidate = focus
        // Web editors can focus an editable AXGroup or a child inside that group.
        for _ in 0..<8 {
            guard let current = candidate, let role = attribute(current, kAXRoleAttribute) as? String else { break }
            if (attribute(current, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole { return nil }
            if role == kAXTextFieldRole || role == kAXTextAreaRole { return current }
            if role == kAXGroupRole || role == "AXWebArea" {
                let editable = (attribute(current, "AXEditable") as? NSNumber)?.boolValue == true
                if editable || isSettable(current, kAXSelectedTextRangeAttribute)
                    || isSettable(current, kAXSelectedTextAttribute) {
                    return current
                }
            }
            if role == "AXWebArea" || role == kAXWindowRole { break }
            candidate = element(current, kAXParentAttribute)
        }
        return nil
    }

    static func diagnostics(app: NSRunningApplication) -> String {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(application, kAXFocusedWindowAttribute) else { return "No focused window" }
        let field = focusedElement(in: application, window: window)
        let role = field.flatMap { attribute($0, kAXRoleAttribute) as? String } ?? "none"
        let editable = editableInput(from: field) != nil
        let windowFallback = app.bundleIdentifier == "com.openai.codex" && allowsCodexWindowFocus(field)
        return "Focused window: true; focused role: \(role); editable input: \(editable); Codex window fallback: \(windowFallback)"
    }

    func interrupt() -> Bool { CGPreflightPostEventAccess() && post(key: 8, flags: .maskControl) }

    func submit(_ message: String) -> Bool {
        guard CGPreflightPostEventAccess(), let text = Self.textKeyEvents(message),
              let enter = keyboardPair(key: CGKeyCode(kVK_Return), flags: []) else { return false }
        for event in text + enter { event.postToPid(process) }
        return true
    }

    func typeKeyboardTest() -> Bool {
        guard CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(), isCurrent(),
              let events = Self.textKeyEvents(Self.keyboardTestText) else { return false }
        // Exercise the same system keyboard route as physical typing. Focus was just rechecked.
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    func pasteKeyboardTest() -> Bool {
        guard !IsSecureEventInputEnabled(), isCurrent() else { return false }
        return PasteTest.run(on: .general, text: Self.keyboardTestText) {
            guard isCurrent() else { return false }
            if let item = pasteMenuItem(), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                return true
            }
            guard CGPreflightPostEventAccess(), let events = keyboardPair(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else { return false }
            for event in events { event.post(tap: .cghidEventTap) }
            return true
        }
    }

    private func pasteMenuItem() -> AXUIElement? {
        guard let bar = Self.element(application, kAXMenuBarAttribute),
              let menuItems = Self.attribute(bar, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for item in menuItems {
            guard let menus = Self.attribute(item, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for menu in menus {
                guard let entries = Self.attribute(menu, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                if let paste = entries.first(where: { entry in
                    // The menu accelerator identifies Paste even if the app is localized.
                    (Self.attribute(entry, "AXMenuItemCmdChar") as? String)?.lowercased() == "v"
                        && (Self.attribute(entry, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue == 0
                        && (Self.attribute(entry, kAXEnabledAttribute) as? NSNumber)?.boolValue == true
                }) {
                    return paste
                }
            }
        }
        return nil
    }

    static func textKeyEvents(_ text: String) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        var events: [CGEvent] = []
        for character in text {
            let units = Array(String(character).utf16)
            let shiftedBase = shiftedKeys[character]
            let lower = character.lowercased().first ?? character
            let key = ansiKeys[shiftedBase ?? lower] ?? CGKeyCode(kVK_ANSI_A)
            let flags: CGEventFlags = shiftedBase != nil || character.isUppercase ? .maskShift : []
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = flags
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                events.append(event)
            }
        }
        return events
    }

    // Physical key codes provide a fallback for apps that inspect key events as well as Unicode.
    private static let ansiKeys: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50
    ]

    private static let shiftedKeys: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "+": "=", "_": "-", "}": "]", "{": "[", "\"": "'", ":": ";", "|": "\\", "<": ",", "?": "/", ">": ".", "~": "`"
    ]

    private func post(key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let events = keyboardPair(key: key, flags: flags) else { return false }
        for event in events { event.postToPid(process) }
        return true
    }

    private func keyboardPair(key: CGKeyCode, flags: CGEventFlags) -> [CGEvent]? {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
        down.flags = flags
        up.flags = flags
        return [down, up]
    }
}
