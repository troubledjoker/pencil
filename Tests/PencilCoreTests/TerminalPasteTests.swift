import XCTest
@testable import PencilCore

final class TerminalPasteTests: XCTestCase {
    func testTerminalBundleIDs() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                   "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper"] {
            XCTAssertTrue(TerminalPaste.isTerminal(id), id)
        }
        XCTAssertFalse(TerminalPaste.isTerminal("com.openai.chat"))
        XCTAssertFalse(TerminalPaste.isTerminal("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(TerminalPaste.isTerminal(nil))
    }

    func testEscapingLikeTerminalDragAndDrop() {
        XCTAssertEqual(TerminalPaste.escaped("/Users/me/Pictures/Pencil/pencil-1.png"), "/Users/me/Pictures/Pencil/pencil-1.png")
        XCTAssertEqual(TerminalPaste.escaped("/Users/me/My Shots/a (1).png"), #"/Users/me/My\ Shots/a\ \(1\).png"#)
        XCTAssertEqual(TerminalPaste.escaped("/tmp/it's & $x.png"), #"/tmp/it\'s\ \&\ \$x.png"#)
        XCTAssertEqual(TerminalPaste.escaped(#"/tmp/back\slash"#), #"/tmp/back\\slash"#)
    }

    func testBurstPathsAreSpaceSeparated() {
        XCTAssertEqual(TerminalPaste.pasteText(for: ["/a b.png", "/c.png"]), #"/a\ b.png /c.png"#)
    }

    private func decide(terminal: Bool, enabled: Bool = true, text: Bool = false, image: Bool = true,
                        bridged: Int? = nil, count: Int = 7) -> TerminalPaste.Action {
        TerminalPaste.decide(frontIsTerminal: terminal, enabled: enabled, hasPlainText: text, hasImageOrMedia: image,
                             bridgedChangeCount: bridged, changeCount: count)
    }

    func testAddsPathForImagesInTerminals() {
        XCTAssertEqual(decide(terminal: true), .addPath)
        XCTAssertEqual(decide(terminal: true, text: true), .none, "already has text")
        XCTAssertEqual(decide(terminal: true, image: false), .none, "not an image or media file")
        XCTAssertEqual(decide(terminal: true, enabled: false), .none, "setting off")
        XCTAssertEqual(decide(terminal: false), .none, "chat apps get the image only")
    }

    func testRemovesOurPathOutsideTerminals() {
        XCTAssertEqual(decide(terminal: false, text: true, bridged: 7, count: 7), .removePath)
        XCTAssertEqual(decide(terminal: true, enabled: false, text: true, bridged: 7, count: 7), .removePath)
        XCTAssertEqual(decide(terminal: true, text: true, bridged: 7, count: 7), .none, "still in a terminal")
    }

    func testNeverClobbersANewerCopy() {
        XCTAssertEqual(decide(terminal: false, text: true, bridged: 7, count: 9), .forget)
        XCTAssertEqual(decide(terminal: true, text: false, bridged: 7, count: 9), .forget)
    }
}
