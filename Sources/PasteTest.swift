import AppKit

enum PasteTest {
    private static var pasteInProgress = false

    // Snapshot every item and flavor before replacing the clipboard. If another application
    // changes it during the test, leave the newer clipboard in place.
    static func run(on pasteboard: NSPasteboard, text: String, paste: () -> Bool) -> Bool {
        guard !pasteInProgress else { return false }
        let startingChange = pasteboard.changeCount
        var saved: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else { return false }
            }
            saved.append(copy)
        }
        guard pasteboard.changeCount == startingChange else { return false }

        pasteInProgress = true
        let test = NSPasteboardItem()
        test.setString(text, forType: .string)
        pasteboard.clearContents()
        let written = pasteboard.writeObjects([test])
        let testChange = pasteboard.changeCount
        let sent = written && paste()
        let restore = {
            defer { pasteInProgress = false }
            guard pasteboard.changeCount == testChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        if sent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: restore)
        } else {
            restore()
        }
        return sent
    }
}
