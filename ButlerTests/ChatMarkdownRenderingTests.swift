import SwiftUI
import UIKit
import XCTest
@testable import Butler

/// These exercise the actual reply renderer, not a second Markdown implementation.
/// Run on an iOS simulator; the portable chat script cannot render SwiftUI.
@MainActor
final class ChatMarkdownRenderingTests: XCTestCase {
    func testGlassAccentFillDoesNotInheritBubbleForeground() throws {
        for scheme in [ColorScheme.light, .dark] {
            func snapshot(_ foreground: Color) throws -> Data {
                let view = Rectangle().fill(AccentChoice.glass.accent.fill)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(foreground)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                return try XCTUnwrap(renderer.uiImage?.pngData())
            }
            XCTAssertEqual(try snapshot(.white), try snapshot(.red),
                           "The bubble/button background must not resolve through inherited foreground style")
        }
    }

    func testStrongAndEmphasisRenderFormattingInsteadOfDelimiters() throws {
        let bold = try render("**牛奶🥛**")
        XCTAssertEqual(bold.pngData(), try render("__牛奶🥛__").pngData())
        XCTAssertNotEqual(bold.pngData(), try render("牛奶🥛").pngData())
        XCTAssertNotEqual(bold.pngData(), try render(#"\*\*牛奶🥛\*\*"#).pngData())
        // System CJK fallback glyphs need not have an italic face. Include Latin
        // glyphs to verify emphasis visually while retaining Chinese in the fixture.
        XCTAssertEqual(try render("*明天检查 tomorrow*").pngData(), try render("_明天检查 tomorrow_").pngData())
        XCTAssertNotEqual(try render("*明天检查 tomorrow*").pngData(), try render("明天检查 tomorrow").pngData())
    }

    func testBlockHeadingsAndListsRenderInsteadOfRawMarkers() throws {
        XCTAssertEqual(try render("# 今日安排").pngData(), try render("今日安排\n====").pngData())
        XCTAssertNotEqual(try render("# 今日安排").pngData(), try render("今日安排").pngData())
        XCTAssertEqual(try render("- 牛奶\n- 青菜").pngData(), try render("* 牛奶\n* 青菜").pngData())
        XCTAssertNotEqual(try render("- 牛奶\n- 青菜").pngData(), try render("牛奶\n青菜").pngData())
    }

    func testUnclosedStreamingFenceMatchesCompletedCodeBlock() throws {
        let code = "```swift\nlet count = 3"
        XCTAssertEqual(try render(code).pngData(), try render(code + "\n```").pngData())
        XCTAssertNotEqual(try render(code).pngData(), try render("let count = 3").pngData())
    }

    func testWideTableAndCodeStayInsideNarrowReplyInBothThemes() throws {
        let text = """
        ## 今日建议
        **先用牛奶**，再补充 *青菜*，~~旧计划~~不再使用。

        1. 查看冰箱
           - [x] 核对数量
           - [ ] 检查日期

        > 这是建议，不代表已经执行。

        [参考说明](https://example.com/guide)

        | 物品 | 说明 | 处理时间 |
        | :--- | :--- | ---: |
        | 牛奶🥛 | 这是一段用于检查窄屏表格横向滚动的很长说明 | 明早 |

        ```swift
        let message = "这是一行用于检查代码块横向滚动而不是撑宽整个聊天气泡的长文字"
        ```
        """
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(text, scheme: scheme, width: 240)
            XCTAssertEqual(image.size.width, 240, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 100)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Markdown 窄气泡 · \(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func render(_ text: String, scheme: ColorScheme = .light, width: CGFloat = 300) throws -> UIImage {
        let renderer = ImageRenderer(content:
            ChatMarkdownText(text: text)
                .padding(14)
                .frame(width: width)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, .medium)
                .background(scheme == .dark ? Color.black : Color.white)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }
}
