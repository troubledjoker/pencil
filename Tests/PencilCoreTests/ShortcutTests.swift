import XCTest
@testable import PencilCore

final class ShortcutTests: XCTestCase {
    private func cmd(_ ch: String, keyCode: UInt16 = 0, command: Bool = false, control: Bool = false,
                     option: Bool = false, typed: String? = nil) -> Shortcuts.LocalCommand? {
        Shortcuts.localCommand(keyCode: keyCode, characters: typed ?? ch, bareCharacters: ch,
                               command: command, control: control, option: option)
    }

    func testToggles() {
        XCTAssertEqual(Shortcuts.toggled(.off, tool: .laser), .draw(.laser))
        XCTAssertEqual(Shortcuts.toggled(.draw(.laser), tool: .laser), .off)
        XCTAssertEqual(Shortcuts.toggled(.draw(.pen), tool: .laser), .draw(.laser), "switches tools rather than turning off")
        XCTAssertEqual(Shortcuts.toggled(.passThrough, tool: .pen), .draw(.pen))
        XCTAssertEqual(Shortcuts.toggled(.draw(.pen), tool: .pen), .off)
    }

    func testGlobalDigits() {
        XCTAssertEqual(Shortcuts.Global.allCases.map(\.label),
                       ["⌥1", "⌥2", "⌥3", "⌥4", "⌥5", "⇧⌥4", "⌥⇧V", "⌃⌘V"])
        XCTAssertEqual(Shortcuts.Global.burst.keyCode, Shortcuts.Global.region.keyCode)
        XCTAssertEqual(Shortcuts.Global.pasteAll.modifiers, Shortcuts.Mods.option | Shortcuts.Mods.shift)
        XCTAssertEqual(Shortcuts.Global.region.label, "⌥4")
        XCTAssertEqual(Shortcuts.Global.record.label, "⌥5")
        XCTAssertEqual(Shortcuts.hint("Region capture", .region), "Region capture  ⌥4")
        XCTAssertEqual(Shortcuts.hint("Undo"), "Undo", "no global key: just the name")
        XCTAssertEqual(Shortcuts.globalRows.last?.0, "⌃⌘V")
    }

    func testSingleKeys() {
        XCTAssertEqual(cmd("p"), .tool(.pen))
        XCTAssertEqual(cmd("h"), .tool(.highlighter))
        XCTAssertEqual(cmd("L"), .tool(.laser), "caps lock / shift still works")
        XCTAssertEqual(cmd("3"), .color(index: 2))
        XCTAssertNil(cmd("6"))
        XCTAssertEqual(cmd("z"), .undo)
        XCTAssertEqual(cmd("z", command: true), .undo)
        XCTAssertEqual(cmd("x"), .clear)
        XCTAssertEqual(cmd("s"), .snapshot)
        XCTAssertEqual(cmd("a"), .region)
        XCTAssertEqual(cmd("/", typed: "?"), .help)
        XCTAssertEqual(cmd("", keyCode: Shortcuts.escapeKeyCode), .passThrough)
        XCTAssertEqual(cmd("\r", keyCode: 36), .captureDrawing)
        XCTAssertEqual(cmd("\u{3}", keyCode: 76), .captureDrawing, "keypad Enter")
    }

    func testModifiedKeysAreIgnored() {
        XCTAssertNil(cmd("p", command: true), "⌘P isn't Pen")
        XCTAssertNil(cmd("x", control: true))
        XCTAssertNil(cmd("s", option: true))
        XCTAssertNil(cmd("q"))
    }

    func testSystemConflictDetection() {
        // The user's real setting: "Copy picture of selected area" remapped to ⌥4.
        let hotkeys: [String: Any] = [
            "31": ["enabled": NSNumber(value: 1), "value": ["parameters": [NSNumber(value: 52), NSNumber(value: 21),
                                                                            NSNumber(value: 524288)], "type": "standard"]],
            "30": ["enabled": NSNumber(value: 0), "value": ["parameters": [NSNumber(value: 52), NSNumber(value: 21),
                                                                            NSNumber(value: 1179648)]]],
            "28": ["enabled": NSNumber(value: 1), "value": ["parameters": [NSNumber(value: 51), NSNumber(value: 20),
                                                                            NSNumber(value: 1179648)]]],
        ]
        let conflicts = Shortcuts.systemConflicts(hotkeys)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.0, .region)
        XCTAssertEqual(conflicts.first?.id, 31)
        XCTAssertTrue(Shortcuts.systemConflicts(nil).isEmpty)
        // ⇧⌥4 is a different combo: no conflict with ⌥4.
        let burstOnly: [String: Any] = ["31": ["enabled": true, "value": ["parameters": [52, 21, 524288 | 131072]]]]
        XCTAssertEqual(Shortcuts.systemConflicts(burstOnly).first?.0, .burst)
    }
}
