import Foundation
@testable import Pinfold
import Testing

/// `DescriptionBlocks` is a pure reducer from untrusted description HTML to display blocks.
struct DescriptionBlocksTests {
    private typealias Run = DescriptionBlocks.Run

    private func plain(_ blocks: [DescriptionBlocks.Block]) -> String {
        blocks.compactMap { block -> String? in
            if case let .paragraph(runs) = block {
                return DescriptionBlocks.text(of: runs)
            }
            return nil
        }.joined(separator: "\n\n")
    }

    @Test func boldAndItalicRuns() {
        let blocks = DescriptionBlocks.parse("Plain <b>bold</b> and <em>slanted <strong>both</strong></em>.")
        guard case let .paragraph(runs)? = blocks.first, blocks.count == 1 else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(runs.map(\.text) == ["Plain ", "bold", " and ", "slanted ", "both", "."])
        #expect(runs.map(\.isBold) == [false, true, false, false, true, false])
        #expect(runs.map(\.isItalic) == [false, false, false, true, true, false])
    }

    @Test func unorderedAndOrderedLists() {
        let blocks = DescriptionBlocks.parse("<ul><li>One</li><li>Two</li></ul><ol><li>First</li><li>Second</li></ol>")
        #expect(blocks == [
            .list(ordered: false, items: [[Run(text: "One")], [Run(text: "Two")]]),
            .list(ordered: true, items: [[Run(text: "First")], [Run(text: "Second")]]),
        ])
    }

    @Test func keyValueTableBecomesRows() {
        let html = """
        <table>
          <tr><td>Type</td><td>Cafe</td></tr>
          <tr><td>Rating</td><td><b>4.5</b></td></tr>
        </table>
        """
        let blocks = DescriptionBlocks.parse(html)
        #expect(blocks == [
            .table(rows: [
                [[Run(text: "Type")], [Run(text: "Cafe")]],
                [[Run(text: "Rating")], [Run(text: "4.5", isBold: true)]],
            ]),
        ])
    }

    @Test func imageBlockCarriesSource() {
        let blocks = DescriptionBlocks.parse("Before<img src=\"https://example.com/a.jpg\" alt=\"A\">After")
        #expect(blocks == [
            .paragraph([Run(text: "Before")]),
            .image(src: "https://example.com/a.jpg", alt: "A"),
            .paragraph([Run(text: "After")]),
        ])
    }

    @Test func imageSourcesAreHttpOrRelativeDedupedAndOrdered() {
        let html = """
        <img src="b.png"><img src='https://x.test/a.jpg'><img src="data:image/png;base64,AAAA">
        <img src="javascript:alert(1)"><img src="b.png"><img src="http://y.test/c.gif">
        """
        #expect(DescriptionBlocks.imageSources(in: html) == ["b.png", "https://x.test/a.jpg", "http://y.test/c.gif"])
    }

    @Test func javascriptLinkIsInert() {
        let html = "<a href=\"javascript:alert(1)\">tap</a> <a href=\"https://ok.test\">ok</a>"
        let blocks = DescriptionBlocks.parse(html)
        guard case let .paragraph(runs)? = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(DescriptionBlocks.text(of: runs) == "tap ok")
        #expect(runs.first { $0.text == "tap" }?.link == nil)
        #expect(runs.first { $0.text == "ok" }?.link == URL(string: "https://ok.test"))
    }

    @Test func unclosedTagsDegradeToText() {
        let html = "Hello <b>bold <i>x <a href=\"https://x.test\" and < 3 > 2 <unknown>kept</unknown>"
        let blocks = DescriptionBlocks.parse(html)
        let text = plain(blocks)
        #expect(text.contains("Hello bold x"))
        #expect(text.contains("kept"))
        #expect(!text.contains("<unknown>"))
    }

    @Test func scriptAndStyleBodiesAreDropped() {
        let text = plain(DescriptionBlocks.parse("A<script>alert(1)</script>B<style>p{}</style>C"))
        #expect(text == "ABC")
    }

    @Test func linkFreeInputMatchesReadableText() {
        let inputs = [
            "<p>One</p><p>Two</p>",
            "Line one<br>Line two",
            "  Indented\n   text\n\n\n\nafter gap",
            "<div>Alpha</div><div>Beta &amp; gamma</div>",
        ]
        for html in inputs {
            #expect(plain(DescriptionBlocks.parse(html)) == AttributedHTML.readableText(html), "\(html)")
        }
    }

    @Test func hugeInputIsCapped() {
        let html = String(repeating: "<a href=\"https://x.test\">x</a> ", count: 100_000)
        let started = Date()
        let blocks = DescriptionBlocks.parse(html)
        #expect(Date().timeIntervalSince(started) < 5)
        let length = blocks.reduce(0) { total, block in
            if case let .paragraph(runs) = block {
                return total + DescriptionBlocks.text(of: runs).count
            }
            return total
        }
        #expect(length <= AttributedHTML.maxDescriptionLength)
    }

    @Test func pathologicalMarkupStaysLinear() {
        let started = Date()
        for html in [
            String(repeating: "<", count: 200_000),
            String(repeating: "<a href=\"x", count: 20000),
            String(repeating: "<!", count: 100_000),
            String(repeating: "<!--", count: 50000),
            String(repeating: "<b>", count: 80000) + "x",
        ] {
            _ = DescriptionBlocks.parse(html)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func imagesInsideTablesAreEmittedAfterTheTable() {
        let blocks = DescriptionBlocks.parse("<table><tr><td>k</td><td><img src=\"p.png\"></td></tr></table>")
        #expect(blocks.last == .image(src: "p.png", alt: nil))
        #expect(blocks.count == 2)
    }
}
