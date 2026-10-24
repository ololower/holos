import AppKit
import ApplicationServices

/// Вставляє текст в активне поле через буфер обміну й ⌘V, а потім повертає попередній вміст буфера.
enum TextInserter {
    // Менеджери буфера обміну (Raycast, Maccy, Paste…) не зберігають елементи з цим типом в історії
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Символи перед і після курсора в активному полі; nil — край поля
    struct Surroundings {
        let before: Character?
        let after: Character?
    }

    /// Після цих символів пробіл перед текстом не потрібен
    private static let openers: Set<Character> = ["(", "[", "{", "«", "„", "/"]

    static func insert(_ text: String) {
        paste(spaced(text, around: surroundings()))
    }

    /// Пробіли навколо тексту за сусідніми символами: перед текстом — якщо курсор стоїть одразу після
    /// слова чи розділового знака, після — якщо далі впритул іде слово. Якщо поле не розповідає,
    /// що навколо курсора, — як раніше: пробіл після тексту.
    static func spaced(_ text: String, around: Surroundings?) -> String {
        guard let around else { return text + " " }
        let leading = around.before.map { !$0.isWhitespace && !openers.contains($0) } ?? false
        let trailing = around.after.map { $0.isLetter || $0.isNumber || openers.contains($0) } ?? false
        return (leading ? " " : "") + text + (trailing ? " " : "")
    }

    /// Читає з активного поля через Accessibility лише два символи — до і після курсора (виділення)
    private static func surroundings() -> Surroundings? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let field: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(field, 0.2)
        guard let rangeValue: AXValue = attribute(field, kAXSelectedTextRangeAttribute),
              let count: Int = attribute(field, kAXNumberOfCharactersAttribute)
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selection) else { return nil }

        let start = selection.location, end = selection.location + selection.length
        guard start >= 0, end <= count else { return nil }
        var before: Character?
        var after: Character?
        if start > 0 {
            guard let character = character(in: field, at: start - 1) else { return nil }
            before = character
        }
        if end < count {
            guard let character = character(in: field, at: end) else { return nil }
            after = character
        }
        return Surroundings(before: before, after: after)
    }

    private static func character(in field: AXUIElement, at index: Int) -> Character? {
        var range = CFRange(location: index, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success
        else { return nil }
        return (value as? String)?.last
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // AXUIElement і AXValue — CF-типи: `as?` для них не перевіряє тип, тож звіряємо CFTypeID
        if T.self == AXUIElement.self { return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil }
        if T.self == AXValue.self { return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil }
        return value as? T
    }

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        // Лише для цього Mac: без цього Universal Clipboard передав би текст на iPhone чи інший Mac поруч
        pasteboard.prepareForNewContents(with: .currentHostOnly)
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
