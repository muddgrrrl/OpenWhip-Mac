import AppKit
import AVFoundation

final class WhipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
}

final class WhipView: NSView {
    private let effects: WhipPreferences
    private let count = 28
    private var points: [CGPoint] = []
    private var previous: [CGPoint] = []
    private var lastMouse = CGPoint.zero
    private var started: TimeInterval = 0
    private var swung: TimeInterval = -.infinity
    private var cracked: TimeInterval = -.infinity
    private var dropped: TimeInterval?
    private var flashPoint = CGPoint.zero
    private var timer: Timer?
    private var sound: AVAudioPlayer?
    var onCrack: (() -> Void)?
    var onDrop: (() -> Void)?
    var onFinish: (() -> Void)?

    init(frame: NSRect, effects: WhipPreferences) {
        self.effects = effects
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { drop() }
    override func rightMouseDown(with event: NSEvent) { drop() }

    func start() {
        let mouse = pointer()
        lastMouse = mouse
        started = ProcessInfo.processInfo.systemUptime
        let direction: CGFloat = mouse.x < bounds.midX ? 1 : -1
        points = (0..<count).map { index in
            let t = CGFloat(index) / CGFloat(count - 1)
            return CGPoint(x: mouse.x + direction * 375 * t, y: mouse.y - 145 * sin(t * .pi) + 140 * t * t)
        }
        previous = points
        if effects.soundEnabled, let url = Bundle.main.url(forResource: "Crack", withExtension: "wav") {
            sound = try? AVAudioPlayer(contentsOf: url)
            sound?.prepareToPlay()
        }
        let tickTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        timer = tickTimer
        RunLoop.main.add(tickTimer, forMode: .common)
    }

    func drop() {
        guard dropped == nil else { return }
        dropped = ProcessInfo.processInfo.systemUptime
        onDrop?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func pointer() -> CGPoint {
        guard let window else { return .zero }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    static func qualifies(age: TimeInterval, sinceSwing: TimeInterval, sinceCrack: TimeInterval,
                          tipTravel: CGFloat, sensitivity: CrackSensitivity = .standard) -> Bool {
        age > 0.38 && sinceSwing < 0.32 && sinceCrack > 0.45 && tipTravel > sensitivity.tipTravel
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let mouse = pointer()
        let dx = mouse.x - lastMouse.x
        let dy = mouse.y - lastMouse.y
        if hypot(dx, dy) > effects.sensitivity.pointerTravel { swung = now }
        lastMouse = mouse
        let holding = dropped == nil
        let oldTip = points[count - 1]
        for i in points.indices {
            let current = points[i]
            points[i].x += (current.x - previous[i].x) * 0.965
            points[i].y += (current.y - previous[i].y) * 0.965 + 0.95
            previous[i] = current
        }
        let aim = -1.12 + min(0.95, max(-1.35, dx * 0.025)) + min(0.3, max(-0.3, dy * 0.01))
        let grip = CGPoint(x: mouse.x + cos(aim) * 24, y: mouse.y + sin(aim) * 24)
        for _ in 0..<14 {
            if holding {
                points[0] = mouse
                points[1] = grip
            }
            for i in (holding ? 1 : 0)..<(count - 1) {
                let vx = points[i + 1].x - points[i].x
                let vy = points[i + 1].y - points[i].y
                let distance = max(0.01, hypot(vx, vy))
                let linkLength = 24 - 10 * CGFloat(i) / CGFloat(count - 1)
                let correction = (distance - linkLength) / distance
                let share: CGFloat = holding && i == 1 ? 0 : 0.5
                points[i].x += vx * correction * share
                points[i].y += vy * correction * share
                points[i + 1].x -= vx * correction * (1 - share)
                points[i + 1].y -= vy * correction * (1 - share)
            }
        }
        let tip = points[count - 1]
        if holding && Self.qualifies(age: now - started, sinceSwing: now - swung,
                                     sinceCrack: now - cracked, tipTravel: hypot(tip.x - oldTip.x, tip.y - oldTip.y),
                                     sensitivity: effects.sensitivity) {
            cracked = now
            flashPoint = tip
            sound?.currentTime = 0
            sound?.play()
            onCrack?()
        }
        needsDisplay = true
        if let dropped, now - dropped > 1.15 {
            stop()
            onFinish?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The faint fill lets the nonactivating panel receive the click that drops the whip.
        context.setFillColor(NSColor.black.withAlphaComponent(0.012).cgColor)
        context.fill(dirtyRect)
        guard points.count == count else { return }
        context.setLineJoin(.round)
        context.setLineCap(.round)
        let rope = CGMutablePath()
        var segments: [CGPath] = []
        rope.move(to: points[0])
        for i in 0..<(count - 1) {
            let before = points[max(0, i - 1)]
            let a = points[i]
            let b = points[i + 1]
            let after = points[min(count - 1, i + 2)]
            let first = CGPoint(x: a.x + (b.x - before.x) / 6, y: a.y + (b.y - before.y) / 6)
            let second = CGPoint(x: b.x - (after.x - a.x) / 6, y: b.y - (after.y - a.y) / 6)
            rope.addCurve(to: b, control1: first, control2: second)
            if effects.style != .classic {
                let segment = CGMutablePath()
                segment.move(to: a)
                segment.addCurve(to: b, control1: first, control2: second)
                segments.append(segment)
            }
        }

        let time = ProcessInfo.processInfo.systemUptime - started
        stroke(rope, width: 11, color: effects.style.outlineColor, in: context)
        if effects.style == .classic {
            stroke(rope, width: 5.5, color: effects.style.ropeColor(progress: 0, time: time), in: context)
        } else {
            for (index, segment) in segments.enumerated() {
                let progress = CGFloat(index) / CGFloat(segments.count)
                stroke(segment, width: 5.5, color: effects.style.ropeColor(progress: progress, time: time), in: context)
            }
        }

        let grip = CGMutablePath()
        grip.move(to: points[0])
        grip.addQuadCurve(to: points[2], control: points[1])
        stroke(grip, width: 16, color: effects.style.outlineColor, in: context)
        stroke(grip, width: 10, color: effects.style.gripColor, in: context)
        let age = ProcessInfo.processInfo.systemUptime - cracked
        if age < 0.17 {
            let rays = CGMutablePath()
            for i in 0..<5 {
                let angle = Double(i) * 2 * .pi / 5
                let radius = 10 + 60 * age
                rays.move(to: CGPoint(x: flashPoint.x + cos(angle) * 4, y: flashPoint.y + sin(angle) * 4))
                rays.addLine(to: CGPoint(x: flashPoint.x + cos(angle) * radius, y: flashPoint.y + sin(angle) * radius))
            }
            let sparkColor = effects.style == .classic
                ? NSColor.systemOrange : effects.style.ropeColor(progress: 0.92, time: time)
            stroke(rays, width: 2, color: sparkColor.withAlphaComponent(1 - age / 0.17), in: context)
        }
    }

    private func stroke(_ path: CGPath, width: CGFloat, color: NSColor, in context: CGContext) {
        context.addPath(path)
        context.setLineWidth(width)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
    }
}
