import XCTest
@testable import EpochCore

final class NotebookDocumentTests: XCTestCase {
    func testDecodesSourceAsStringAndArray() throws {
        let json = """
        {
          "cells": [
            { "cell_type": "markdown", "source": "# Title\\n" },
            { "cell_type": "markdown", "source": ["Line 1\\n", "Line 2\\n"] }
          ]
        }
        """

        let doc = try NotebookDocument.decode(from: json)
        XCTAssertEqual(doc.language, "python")
        XCTAssertEqual(doc.cells.count, 2)
        XCTAssertEqual(doc.cells[0].source, "# Title\n")
        XCTAssertEqual(doc.cells[1].source, "Line 1\nLine 2\n")
    }

    func testParsesCommonOutputs() throws {
        let json = """
        {
          "cells": [
            {
              "cell_type": "code",
              "execution_count": 2,
              "source": ["print(\\"hi\\")\\n"],
              "outputs": [
                { "output_type": "stream", "name": "stdout", "text": ["hi\\n"] },
                {
                  "output_type": "execute_result",
                  "data": {
                    "text/plain": ["42"],
                    "text/html": "<b>42</b>",
                    "image/png": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5GZfQAAAAASUVORK5CYII="
                  }
                },
                {
                  "output_type": "error",
                  "ename": "ValueError",
                  "evalue": "bad",
                  "traceback": ["Trace line 1", "Trace line 2"]
                }
              ]
            }
          ],
          "metadata": { "language_info": { "name": "Python" } }
        }
        """

        let doc = try NotebookDocument.decode(from: json)
        XCTAssertEqual(doc.language, "python")
        XCTAssertEqual(doc.cells.count, 1)
        XCTAssertEqual(doc.cells[0].executionCount, 2)
        XCTAssertEqual(doc.cells[0].outputs.count, 3)

        if case let .stream(name, text) = doc.cells[0].outputs[0] {
            XCTAssertEqual(name, "stdout")
            XCTAssertEqual(text, "hi\n")
        } else {
            XCTFail("Expected stream output")
        }

        if case let .rich(rich) = doc.cells[0].outputs[1] {
            XCTAssertEqual(rich.textPlain, "42")
            XCTAssertEqual(rich.html, "<b>42</b>")
            XCTAssertNotNil(rich.imagePNGBase64)
        } else {
            XCTFail("Expected rich output")
        }

        if case let .error(ename, evalue, traceback) = doc.cells[0].outputs[2] {
            XCTAssertEqual(ename, "ValueError")
            XCTAssertEqual(evalue, "bad")
            XCTAssertTrue(traceback.contains("Trace line 1"))
        } else {
            XCTFail("Expected error output")
        }
    }
}

