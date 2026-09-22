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
                       ["⌥1", "⌥2", "⌥7", "⌥0", "⌥Z", "⌥X", "⌥3", "⌥4", "⇧⌥4", "⌥6", "⌥5",
                        "⌃⌘V", "⌥⇧V", "⌥9", "⌥/"])
        XCTAssertEqual(Shortcuts.Global.burst.keyCode, Shortcuts.Global.region.keyCode)
        XCTAssertEqual(Shortcuts.Global.pasteAll.modifiers, Shortcuts.Mods.option | Shortcuts.Mods.shift)
        XCTAssertEqual(Shortcuts.Global.region.label, "⌥4")
        XCTAssertEqual(Shortcuts.Global.record.label, "⌥5")
        XCTAssertEqual(Shortcuts.hint("Region capture", .region), "Region capture  ⌥4")
        XCTAssertEqual(Shortcuts.hint("Undo"), "Undo", "no global key: just the name")
        XCTAssertTrue(Shortcuts.globalRows.contains { $0.0 == "⌃⌘V" })
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

    // MARK: Every feature has a unique global key

    func testEveryGlobalComboIsUnique() {
        let combos = Shortcuts.Global.allCases.map { "\($0.keyCode)/\($0.modifiers)" }
        XCTAssertEqual(Set(combos).count, combos.count, "two globals share a key combo")
        let labels = Shortcuts.Global.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    /// Table-driven: every toolbar / pill / menu feature must have a global key, and no two
    /// features may share one. Adding a Feature without wiring a Global fails to compile
    /// (exhaustive switch); reusing one fails here.
    func testEveryFeatureHasItsOwnGlobalKey() {
        let expected: [Shortcuts.Feature: String] = [
            .laser: "⌥1", .pen: "⌥2", .highlighter: "⌥7", .off: "⌥0",
            .undo: "⌥Z", .clear: "⌥X",
            .snapshot: "⌥3", .region: "⌥4", .burst: "⇧⌥4", .captureDrawing: "⌥6", .record: "⌥5",
            .clipboard: "⌃⌘V", .pasteAll: "⌥⇧V",
            .toggleDock: "⌥9", .shortcuts: "⌥/",
        ]
        for feature in Shortcuts.Feature.allCases {
            XCTAssertEqual(feature.global.label, expected[feature], "\(feature) has no (or the wrong) global key")
        }
        XCTAssertEqual(expected.count, Shortcuts.Feature.allCases.count, "a feature is missing from this table")
        let globals = Shortcuts.Feature.allCases.map(\.global)
        XCTAssertEqual(Set(globals.map(\.label)).count, globals.count, "two features share a global key")
        XCTAssertEqual(Set(Shortcuts.Global.allCases.map(\.label)), Set(globals.map(\.label)),
                       "every global key belongs to a feature")
    }

    func testCheatSheetSectionsCoverEveryGlobalOnce() {
        let listed = Shortcuts.globalSections.flatMap(\.keys).map(\.label)
        XCTAssertEqual(listed.count, Shortcuts.Global.allCases.count)
        XCTAssertEqual(Set(listed), Set(Shortcuts.Global.allCases.map(\.label)))
        XCTAssertEqual(Shortcuts.globalSections.map(\.title), ["Draw", "Edit", "Capture", "Clipboard", "Pencil"])
    }
}
