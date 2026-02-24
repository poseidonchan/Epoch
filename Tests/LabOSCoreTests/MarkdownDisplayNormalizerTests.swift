import XCTest
@testable import LabOSCore

final class MarkdownDisplayNormalizerTests: XCTestCase {
    func testNormalizeUnescapesEscapedCodeFencesAtLineStart() {
        let input = """
        Here is code:
        \\`\\`\\`python
        print("hi")
        \\`\\`\\`
        """

        let output = MarkdownDisplayNormalizer.normalize(input)
        XCTAssertTrue(output.contains("```python"))
        XCTAssertTrue(output.contains("\n```"))
        XCTAssertFalse(output.contains("\\`\\`\\`python"))
    }

    func testLikelyContainsCodeBlockDetectsFencedCode() {
        let markdown = """
        Example:

        ```c
        int main() {
            return 0;
        }
        ```
        """

        XCTAssertTrue(MarkdownDisplayNormalizer.likelyContainsCodeBlock(markdown))
    }

    func testLikelyContainsCodeBlockDetectsEscapedFencedCode() {
        let markdown = """
        Example:

        \\`\\`\\`python
        print("hello")
        \\`\\`\\`
        """

        XCTAssertTrue(MarkdownDisplayNormalizer.likelyContainsCodeBlock(markdown))
    }

    func testLikelyContainsCodeBlockFalseForPlainMarkdown() {
        let markdown = """
        1. Point one
        2. Point two
        """

        XCTAssertFalse(MarkdownDisplayNormalizer.likelyContainsCodeBlock(markdown))
    }

    func testNormalizeChatMessageStripsWholeMessageBlockquote() {
        let input = """
        > I can view uploaded photos here, but I don’t see any images attached in this chat right now.
        >
        > Please re-upload the two photos and tell me what you want me to check.
        """

        let output = MarkdownDisplayNormalizer.normalizeChatMessage(input)
        XCTAssertFalse(output.contains("\n> "))
        XCTAssertTrue(output.hasPrefix("I can view uploaded photos here"))
        XCTAssertTrue(output.contains("\n\nPlease re-upload the two photos"))
    }

    func testNormalizeChatMessageKeepsMixedQuoteContent() {
        let input = """
        > quoted line

        normal line
        """

        let output = MarkdownDisplayNormalizer.normalizeChatMessage(input)
        XCTAssertEqual(output, input)
    }

    func testNormalizeChatMessageStripsIndentedWholeMessageBlockquoteWithoutCreatingCodeBlock() {
        let input = """
            > I’m your **LabOS research assistant**—a concise helper.
            >
            > I can help with experiments and debugging.
        """

        let output = MarkdownDisplayNormalizer.normalizeChatMessage(input)
        XCTAssertFalse(output.contains(">"))
        XCTAssertFalse(MarkdownDisplayNormalizer.likelyContainsCodeBlock(output))
        XCTAssertEqual(
            output,
            """
            I’m your **LabOS research assistant**—a concise helper.

            I can help with experiments and debugging.
            """
        )
    }
}
