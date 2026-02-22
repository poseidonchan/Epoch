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
}
