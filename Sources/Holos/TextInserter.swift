import AppKit

/// Вставляє текст в активне поле через буфер обміну й ⌘V, а потім повертає попередній вміст буфера.
enum TextInserter {
    // Менеджери буфера обміну (Raycast, Maccy, Paste…) не зберігають елементи з цим типом в історії
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        let ourChange = pasteboard.changeCount

        pressCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Якщо користувач за цей час щось скопіював сам — не чіпаємо
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9 // фізична клавіша V; ⌘-комбінації працюють і в українській розкладці
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
