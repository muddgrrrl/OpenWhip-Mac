import AppKit

enum CrackSensitivity: String, CaseIterable, Codable {
    case easy = "Easy"
    case standard = "Standard"
    case hard = "Hard"

    var pointerTravel: CGFloat {
        switch self {
        case .easy: 12
        case .standard: 20
        case .hard: 30
        }
    }

    var tipTravel: CGFloat {
        switch self {
        case .easy: 11
        case .standard: 22
        case .hard: 37
        }
    }
}

enum WhipStyle: String, CaseIterable, Codable {
    case classic = "Classic"
    case rainbow = "Rainbow"
    case wilderness = "Wilderness Hive"

    var gripColor: NSColor {
        switch self {
        case .classic: NSColor(srgbRed: 0.34, green: 0.12, blue: 0.08, alpha: 1)
        case .rainbow: NSColor(srgbRed: 0.27, green: 0.13, blue: 0.54, alpha: 1)
        case .wilderness: NSColor(srgbRed: 0.15, green: 0.24, blue: 0.16, alpha: 1)
        }
    }

    var outlineColor: NSColor {
        self == .wilderness ? NSColor(srgbRed: 1, green: 0.92, blue: 0.69, alpha: 1) : .white
    }

    func ropeColor(progress: CGFloat, time: TimeInterval) -> NSColor {
        switch self {
        case .classic:
            NSColor(calibratedWhite: 0.07, alpha: 1)
        case .rainbow:
            NSColor(calibratedHue: (progress + time * 0.45).truncatingRemainder(dividingBy: 1),
                    saturation: 0.88, brightness: 0.94, alpha: 1)
        case .wilderness:
            Int(progress * 14).isMultiple(of: 2)
                ? NSColor(srgbRed: 0.86, green: 0.53, blue: 0.11, alpha: 1)
                : NSColor(srgbRed: 0.17, green: 0.22, blue: 0.12, alpha: 1)
        }
    }
}

enum NudgePhrase: String, CaseIterable, Codable {
    case classic = "Classic"
    case buzzBuzz = "Buzz Buzz"
    case wilderness = "The Wilderness"
    case custom = "Custom"

    var preset: String? {
        switch self {
        case .classic: "Go faster. Keep working on the current task."
        case .buzzBuzz: "Buzz buzz. Keep the hive moving and finish the current task."
        case .wilderness: "The wilderness can wait. Focus on finishing the current task."
        case .custom: nil
        }
    }
}

struct WhipPreferences: Codable, Equatable {
    var sensitivity = CrackSensitivity.standard
    var style = WhipStyle.classic
    var phrase = NudgePhrase.classic
    var soundEnabled = true
    var nudgesEnabled = true
}
