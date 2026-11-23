import AppKit

final class MiscSettingsController: NSViewController, NSTextFieldDelegate {
    private let settings: Settings
    private let sensitivity = NSSegmentedControl(labels: CrackSensitivity.allCases.map(\.rawValue),
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let style = NSPopUpButton()
    private let phrase = NSPopUpButton()
    private let sound = NSButton(checkboxWithTitle: "Play crack sound", target: nil, action: nil)
    private let nudges = NSButton(checkboxWithTitle: "Send chat nudges", target: nil, action: nil)
    private let phrasePreview = NSTextField(wrappingLabelWithString: "")
    private let customPrompt = NSTextField()
    private let palettePreview = WhipPalettePreview()

    init(settings: Settings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 555, height: 356))
        style.addItems(withTitles: WhipStyle.allCases.map(\.rawValue))
        phrase.addItems(withTitles: NudgePhrase.allCases.map(\.rawValue))
        for control in [sensitivity, style, phrase, sound, nudges] as [NSControl] {
            control.target = self
            control.action = #selector(update)
        }
        sensitivity.setAccessibilityLabel("Crack sensitivity")
        style.setAccessibilityLabel("Whip appearance")
        phrase.setAccessibilityLabel("Nudge phrase")
        customPrompt.placeholderString = "Type your custom nudge"
        customPrompt.setAccessibilityLabel("Custom nudge prompt")
        customPrompt.usesSingleLineMode = true
        customPrompt.delegate = self
        phrasePreview.textColor = .secondaryLabelColor

        let messageDetail = NSStackView(views: [phrasePreview, customPrompt])
        messageDetail.orientation = .vertical
        messageDetail.alignment = .leading
        messageDetail.detachesHiddenViews = true
        customPrompt.widthAnchor.constraint(equalToConstant: 375).isActive = true
        phrasePreview.widthAnchor.constraint(equalToConstant: 375).isActive = true

        let styleRow = NSStackView(views: [style, palettePreview])
        styleRow.spacing = 12
        palettePreview.widthAnchor.constraint(equalToConstant: 116).isActive = true
        palettePreview.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let grid = NSGridView(views: [
            [label("Crack sensitivity"), sensitivity],
            [NSGridCell.emptyContentView, caption("Easy cracks with a smaller flick. Hard needs a sharper swing.")],
            [label("Appearance"), styleRow],
            [NSGridCell.emptyContentView, sound],
            [label("Nudges"), nudges],
            [label("Message"), phrase],
            [NSGridCell.emptyContentView, messageDetail]
        ])
        grid.columnSpacing = 18
        grid.rowSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).rowAlignment = .firstBaseline
        }

        let title = NSTextField(labelWithString: "Whip & Chat")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let hint = caption("Switch off chat nudges to keep the whip effects on their own.")
        let stack = NSStackView(views: [title, grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22)
        ])

        view = content
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        let effects = settings.effects
        sensitivity.selectedSegment = CrackSensitivity.allCases.firstIndex(of: effects.sensitivity) ?? 1
        style.selectItem(withTitle: effects.style.rawValue)
        phrase.selectItem(withTitle: effects.phrase.rawValue)
        sound.state = effects.soundEnabled ? .on : .off
        nudges.state = effects.nudgesEnabled ? .on : .off
        phrase.isEnabled = effects.nudgesEnabled
        phrasePreview.isHidden = effects.phrase == .custom
        phrasePreview.stringValue = effects.phrase.preset ?? ""
        customPrompt.isHidden = effects.phrase != .custom
        customPrompt.isEnabled = effects.nudgesEnabled
        if customPrompt.stringValue != settings.customPrompt {
            customPrompt.stringValue = settings.customPrompt
        }
        palettePreview.style = effects.style
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    func controlTextDidChange(_ notification: Notification) {
        settings.customPrompt = customPrompt.stringValue
    }

    @objc private func update(_ sender: NSControl) {
        guard CrackSensitivity.allCases.indices.contains(sensitivity.selectedSegment),
              let styleTitle = style.titleOfSelectedItem, let selectedStyle = WhipStyle(rawValue: styleTitle),
              let phraseTitle = phrase.titleOfSelectedItem, let selectedPhrase = NudgePhrase(rawValue: phraseTitle) else { return }
        settings.effects = WhipPreferences(sensitivity: CrackSensitivity.allCases[sensitivity.selectedSegment],
                                          style: selectedStyle, phrase: selectedPhrase,
                                          soundEnabled: sound.state == .on, nudgesEnabled: nudges.state == .on)
        refresh()
        if sender === phrase && selectedPhrase == .custom {
            view.window?.makeFirstResponder(customPrompt)
        }
    }
}

private final class WhipPalettePreview: NSView {
    var style = WhipStyle.classic {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let chip = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: 7, cornerHeight: 7, transform: nil)
        context.addPath(chip)
        context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1).cgColor)
        context.fillPath()
        context.setLineCap(.round)
        let segmentWidth = (bounds.width - 20) / 24
        let y = bounds.midY
        context.setStrokeColor(style.outlineColor.cgColor)
        context.setLineWidth(8)
        context.move(to: CGPoint(x: 10, y: y))
        context.addLine(to: CGPoint(x: bounds.maxX - 10, y: y))
        context.strokePath()
        context.setLineWidth(4)
        for index in 0..<24 {
            let color = style.ropeColor(progress: CGFloat(index) / 24, time: 0)
            let x = 10 + CGFloat(index) * segmentWidth
            context.setStrokeColor(color.cgColor)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + segmentWidth, y: y))
            context.strokePath()
        }
    }
}
