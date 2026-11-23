import AppKit
import ApplicationServices
import UniformTypeIdentifiers

final class SettingsController: NSViewController {
    private final class AppListDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private let settings: Settings
    private let entries = NSStackView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private var permissionTimer: Timer?

    init(settings: Settings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 555, height: 337))
        let title = NSTextField(labelWithString: "Allowed Apps")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let intro = NSTextField(wrappingLabelWithString:
            "A crack can send a nudge to the focused input in an allowed app. Focus the AI composer before picking up the whip.")
        intro.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let document = AppListDocument()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        entries.orientation = .vertical
        entries.alignment = .leading
        entries.spacing = 8
        entries.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(entries)

        let add = NSButton(title: "Add Application…", target: self, action: #selector(chooseApplication))
        add.bezelStyle = .rounded
        let terminal = NSTextField(wrappingLabelWithString:
            "Terminal modes send to the active pane. Choose Terminal + Ctrl-C for an AI session you want the whip to interrupt.")
        terminal.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        terminal.textColor = .secondaryLabelColor
        let separator = NSBox()
        separator.boxType = .separator
        let accessibility = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibility))
        accessibility.bezelStyle = .rounded
        let footer = NSStackView(views: [permissionLabel, NSView(), accessibility])
        footer.orientation = .horizontal

        let column = NSStackView(views: [title, intro, scroll, add, terminal, separator, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .fill
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            intro.widthAnchor.constraint(equalTo: column.widthAnchor),
            terminal.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 116),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            entries.topAnchor.constraint(equalTo: document.topAnchor, constant: 9),
            entries.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -9),
            entries.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            entries.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10)
        ])
        view = content
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.refreshPermission() }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func viewDidDisappear() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        super.viewDidDisappear()
    }

    func refresh() {
        entries.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if settings.apps.isEmpty {
            let label = NSTextField(labelWithString: "No apps allowed yet. The whip still animates and plays sound.")
            label.textColor = .secondaryLabelColor
            entries.addArrangedSubview(label)
        }
        for (index, item) in settings.apps.enumerated() {
            let name = NSTextField(labelWithString: item.name)
            name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            name.toolTip = item.id
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let mode = NSPopUpButton()
            mode.addItems(withTitles: AppMode.allCases.map(\.rawValue))
            mode.selectItem(withTitle: item.mode.rawValue)
            mode.tag = index
            mode.target = self
            mode.action = #selector(changeInputMode)
            mode.setAccessibilityLabel("Input mode for \(item.name)")
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeApplication))
            remove.tag = index
            remove.setAccessibilityLabel("Remove \(item.name)")
            let row = NSStackView(views: [name, NSView(), mode, remove])
            row.orientation = .horizontal
            entries.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: entries.widthAnchor).isActive = true
        }
        refreshPermission()
    }

    private func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        permissionLabel.stringValue = trusted ? "Accessibility granted" : "Accessibility required for nudges"
        permissionLabel.textColor = trusted ? .systemGreen : .secondaryLabelColor
    }

    @objc private func chooseApplication() {
        guard let window = view.window else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.prompt = "Allow"
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK else { return }
            guard let url = picker.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
                let alert = NSAlert()
                alert.messageText = "Choose another macOS application"
                alert.beginSheetModal(for: window)
                return
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            self.settings.allow(id: id, name: name)
            self.refresh()
        }
    }

    @objc private func changeInputMode(_ sender: NSPopUpButton) {
        guard settings.apps.indices.contains(sender.tag), let title = sender.titleOfSelectedItem,
              let mode = AppMode(rawValue: title) else { return }
        settings.apps[sender.tag].mode = mode
    }

    @objc private func removeApplication(_ sender: NSButton) {
        guard settings.apps.indices.contains(sender.tag) else { return }
        settings.apps.remove(at: sender.tag)
        refresh()
    }

    @objc private func openAccessibility() {
        if !AXIsProcessTrusted() {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
