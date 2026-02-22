#if os(iOS)
import Foundation

enum MarkdownMathPreprocessor {
    static func likelyContainsMath(_ text: String) -> Bool {
        if text.contains("\\[")
            || text.contains("\\]")
            || text.contains("\\(")
            || text.contains("\\)")
            || text.contains("$$")
            || text.contains("\\begin{")
        {
            return true
        }

        if containsLatexCommandOutsideFences(text) {
            return true
        }

        if containsBracketedMathExpression(text) {
            return true
        }

        if text.contains("$"), containsDollarMathPair(text) {
            return true
        }

        return false
    }

    static func prepareForRendering(_ text: String) -> String {
        let normalized = wrapBracketedMathExpressions(text)
        let escaped = escapeLatexDelimitersForMarkdown(normalized)
        let delimiterNormalized = normalizeEscapedDelimiterBackslashes(escaped)
        return stripNestedDelimitersInsideMathSegments(delimiterNormalized)
    }

    /// Markdown treats `\[` / `\]` / `\(` / `\)` as escapes and removes the backslash, which breaks
    /// LaTeX-style math delimiters. This makes those delimiters survive Markdown parsing by doubling
    /// *single* leading backslashes (leaving already-doubled delimiters untouched).
    static func escapeLatexDelimitersForMarkdown(_ text: String) -> String {
        guard text.contains("\\") else { return text }

        var out = String()
        out.reserveCapacity(text.count)

        var prevWasBackslash = false
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "\\" {
                let next = text.index(after: idx)
                if next < text.endIndex {
                    let nextCh = text[next]
                    if (nextCh == "[" || nextCh == "]" || nextCh == "(" || nextCh == ")") && !prevWasBackslash {
                        out.append("\\")
                        out.append("\\")
                        out.append(nextCh)
                        idx = text.index(after: next)
                        prevWasBackslash = false
                        continue
                    }
                }
                out.append(ch)
                prevWasBackslash = true
                idx = text.index(after: idx)
                continue
            }

            out.append(ch)
            prevWasBackslash = false
            idx = text.index(after: idx)
        }

        return out
    }

    /// Some responses contain too many backslashes around math delimiters (e.g. `\\\\(`), which makes
    /// Markdown-it emit `\\(` and prevents KaTeX auto-render from recognizing the delimiter. Normalize
    /// any run of one-or-more backslashes right before `(` `)` `[` `]` to exactly two backslashes.
    private static func normalizeEscapedDelimiterBackslashes(_ text: String) -> String {
        guard text.contains("\\") else { return text }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)

        var inFence: String? = nil
        for raw in lines {
            let line = String(raw)
            let trimmedLeading = line.trimmingCharacters(in: .whitespaces)

            if let fence = inFence {
                outLines.append(line)
                if trimmedLeading.hasPrefix(fence) {
                    inFence = nil
                }
                continue
            }

            if trimmedLeading.hasPrefix("```") {
                inFence = "```"
                outLines.append(line)
                continue
            }
            if trimmedLeading.hasPrefix("~~~") {
                inFence = "~~~"
                outLines.append(line)
                continue
            }

            var out = String()
            out.reserveCapacity(line.count)

            var inInlineCode = false
            var prevWasBackslash = false
            var idx = line.startIndex
            while idx < line.endIndex {
                let ch = line[idx]

                if ch == "`", !prevWasBackslash {
                    inInlineCode.toggle()
                    out.append(ch)
                    prevWasBackslash = false
                    idx = line.index(after: idx)
                    continue
                }

                if inInlineCode {
                    out.append(ch)
                    prevWasBackslash = ch == "\\"
                    idx = line.index(after: idx)
                    continue
                }

                if ch == "\\" {
                    var runEnd = idx
                    var runCount = 0
                    while runEnd < line.endIndex, line[runEnd] == "\\" {
                        runCount += 1
                        runEnd = line.index(after: runEnd)
                    }

                    if runEnd < line.endIndex {
                        let nextCh = line[runEnd]
                        if nextCh == "(" || nextCh == ")" || nextCh == "[" || nextCh == "]" {
                            out.append("\\")
                            out.append("\\")
                            out.append(nextCh)
                            idx = line.index(after: runEnd)
                            prevWasBackslash = false
                            continue
                        }
                    }

                    // Not a delimiter sequence; preserve the original run.
                    if runCount > 0 {
                        out.append(contentsOf: String(repeating: "\\", count: runCount))
                        idx = runEnd
                        prevWasBackslash = true
                        continue
                    }
                }

                out.append(ch)
                prevWasBackslash = ch == "\\"
                idx = line.index(after: idx)
            }

            outLines.append(out)
        }

        return outLines.joined(separator: "\n")
    }

    /// Some model outputs incorrectly nest math delimiters (e.g. `\\( ... \\((x)\\) ... \\)`), which KaTeX
    /// can't parse. This strips *nested* `\\(` / `\\)` / `\\[` / `\\]` tokens that appear inside already
    /// delimited math segments, while preserving the outer delimiters.
    private static func stripNestedDelimitersInsideMathSegments(_ text: String) -> String {
        guard text.contains("\\\\(") || text.contains("\\\\[") else { return text }

        var out = String()
        out.reserveCapacity(text.count)

        var inFence: String? = nil
        var inInlineCode = false
        var prevWasBackslash = false

        var idx = text.startIndex
        while idx < text.endIndex {
            if idx == text.startIndex || text[text.index(before: idx)] == "\n" {
                let lineEnd = text[idx...].firstIndex(of: "\n") ?? text.endIndex
                let line = text[idx..<lineEnd]
                let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })

                if trimmedLeading.hasPrefix("```") {
                    out.append(contentsOf: line)
                    if lineEnd < text.endIndex { out.append("\n") }
                    idx = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                    prevWasBackslash = false
                    inInlineCode = false
                    if inFence == "```" {
                        inFence = nil
                    } else if inFence == nil {
                        inFence = "```"
                    }
                    continue
                }

                if trimmedLeading.hasPrefix("~~~") {
                    out.append(contentsOf: line)
                    if lineEnd < text.endIndex { out.append("\n") }
                    idx = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                    prevWasBackslash = false
                    inInlineCode = false
                    if inFence == "~~~" {
                        inFence = nil
                    } else if inFence == nil {
                        inFence = "~~~"
                    }
                    continue
                }
            }

            if inFence != nil {
                let ch = text[idx]
                out.append(ch)
                prevWasBackslash = ch == "\\"
                inInlineCode = false
                idx = text.index(after: idx)
                continue
            }

            let ch = text[idx]
            if ch == "`", !prevWasBackslash {
                inInlineCode.toggle()
                out.append(ch)
                prevWasBackslash = false
                idx = text.index(after: idx)
                continue
            }

            if !inInlineCode, let openType = mathDelimiterOpeningType(at: idx, in: text) {
                if let segment = parseMathSegment(in: text, startingAt: idx, openType: openType) {
                    out.append(contentsOf: openType.open)
                    out.append(contentsOf: segment.content)
                    out.append(contentsOf: openType.close)
                    idx = segment.endIndex
                    prevWasBackslash = false
                    continue
                }
            }

            out.append(ch)
            prevWasBackslash = ch == "\\"
            idx = text.index(after: idx)
        }

        return out
    }

    private struct MathDelimiterType: Equatable, Sendable {
        var open: String
        var close: String
    }

    private static let inlineDelimiter = MathDelimiterType(open: "\\\\(", close: "\\\\)")
    private static let displayDelimiter = MathDelimiterType(open: "\\\\[", close: "\\\\]")

    private static func mathDelimiterOpeningType(at idx: String.Index, in text: String) -> MathDelimiterType? {
        let slice = text[idx...]
        if slice.hasPrefix(inlineDelimiter.open) { return inlineDelimiter }
        if slice.hasPrefix(displayDelimiter.open) { return displayDelimiter }
        return nil
    }

    private static func mathDelimiterClosingType(at idx: String.Index, in text: String) -> MathDelimiterType? {
        let slice = text[idx...]
        if slice.hasPrefix(inlineDelimiter.close) { return inlineDelimiter }
        if slice.hasPrefix(displayDelimiter.close) { return displayDelimiter }
        return nil
    }

    private static func parseMathSegment(
        in text: String,
        startingAt openIndex: String.Index,
        openType: MathDelimiterType
    ) -> (content: String, endIndex: String.Index)? {
        var stack: [MathDelimiterType] = [openType]

        var cursor = text.index(openIndex, offsetBy: openType.open.count)
        var contentStart = cursor

        var content = String()
        content.reserveCapacity(min(4096, text.distance(from: cursor, to: text.endIndex)))

        while cursor < text.endIndex {
            if let nextOpen = mathDelimiterOpeningType(at: cursor, in: text) {
                content.append(contentsOf: text[contentStart..<cursor])
                stack.append(nextOpen)
                cursor = text.index(cursor, offsetBy: nextOpen.open.count)
                contentStart = cursor
                continue
            }

            if let nextClose = mathDelimiterClosingType(at: cursor, in: text),
               let expected = stack.last,
               nextClose == expected
            {
                content.append(contentsOf: text[contentStart..<cursor])
                stack.removeLast()
                cursor = text.index(cursor, offsetBy: nextClose.close.count)
                contentStart = cursor

                if stack.isEmpty {
                    return (content: content, endIndex: cursor)
                }
                continue
            }

            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func containsLatexCommand(_ text: String) -> Bool {
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx] == "\\" {
                let next = text.index(after: idx)
                if next < text.endIndex, isASCIILetter(text[next]) {
                    return true
                }
            }
            idx = text.index(after: idx)
        }
        return false
    }

    private static func containsLatexCommandOutsideFences(_ text: String) -> Bool {
        var inFence = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw)
            let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
            if trimmedLeading.hasPrefix("```") || trimmedLeading.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if containsLatexCommand(line) { return true }
        }
        return false
    }

    private static func containsBracketedMathExpression(_ text: String) -> Bool {
        var inFence = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw)
            let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
            if trimmedLeading.hasPrefix("```") || trimmedLeading.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            if lineContainsBracketedMath(line) { return true }
        }
        return false
    }

    private static func containsDollarMathPair(_ text: String) -> Bool {
        var inFence = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw)
            let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
            if trimmedLeading.hasPrefix("```") || trimmedLeading.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            var dollarCount = 0
            var prevWasBackslash = false
            for ch in line {
                if ch == "\\" {
                    prevWasBackslash = true
                    continue
                }
                if ch == "$", !prevWasBackslash {
                    dollarCount += 1
                    if dollarCount >= 2 { return true }
                }
                prevWasBackslash = false
            }
        }
        return false
    }

    private static func wrapBracketedMathExpressions(_ text: String) -> String {
        guard text.contains("[") else { return text }

        var out = String()
        out.reserveCapacity(text.count)

        var inFence: String? = nil
        var inInlineCode = false
        var prevWasBackslash = false

        var idx = text.startIndex
        while idx < text.endIndex {
            if idx == text.startIndex || text[text.index(before: idx)] == "\n" {
                let lineEnd = text[idx...].firstIndex(of: "\n") ?? text.endIndex
                let line = text[idx..<lineEnd]
                let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })

                if trimmedLeading.hasPrefix("```") {
                    out.append(contentsOf: line)
                    if lineEnd < text.endIndex { out.append("\n") }
                    idx = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                    prevWasBackslash = false
                    inInlineCode = false
                    if inFence == "```" {
                        inFence = nil
                    } else if inFence == nil {
                        inFence = "```"
                    }
                    continue
                }

                if trimmedLeading.hasPrefix("~~~") {
                    out.append(contentsOf: line)
                    if lineEnd < text.endIndex { out.append("\n") }
                    idx = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                    prevWasBackslash = false
                    inInlineCode = false
                    if inFence == "~~~" {
                        inFence = nil
                    } else if inFence == nil {
                        inFence = "~~~"
                    }
                    continue
                }
            }

            if inFence != nil {
                let ch = text[idx]
                out.append(ch)
                prevWasBackslash = ch == "\\"
                inInlineCode = false
                idx = text.index(after: idx)
                continue
            }

            let ch = text[idx]
            if ch == "`", !prevWasBackslash {
                inInlineCode.toggle()
                out.append(ch)
                prevWasBackslash = false
                idx = text.index(after: idx)
                continue
            }

            if !inInlineCode, ch == "[" {
                let prev = idx > text.startIndex ? text[text.index(before: idx)] : nil
                if let prev, isASCIILetter(prev) || prev == "\\" {
                    out.append(ch)
                    prevWasBackslash = false
                    idx = text.index(after: idx)
                    continue
                }

                var depth = 1
                var cursor = text.index(after: idx)
                while cursor < text.endIndex, depth > 0 {
                    let c = text[cursor]
                    if c == "[" { depth += 1 }
                    if c == "]" { depth -= 1 }
                    cursor = text.index(after: cursor)
                }

                guard depth == 0 else {
                    out.append(ch)
                    prevWasBackslash = false
                    idx = text.index(after: idx)
                    continue
                }

                let closingBracket = text.index(before: cursor)
                let inside = text[text.index(after: idx)..<closingBracket]

                // Ignore markdown links `[text](url)` and similar.
                var isLinkLike = false
                var remainderCursor = cursor
                while remainderCursor < text.endIndex {
                    let r = text[remainderCursor]
                    if r == " " || r == "\t" {
                        remainderCursor = text.index(after: remainderCursor)
                        continue
                    }
                    if r == "(" || r == ":" {
                        isLinkLike = true
                    }
                    break
                }
                if isLinkLike {
                    out.append(ch)
                    prevWasBackslash = false
                    idx = text.index(after: idx)
                    continue
                }

                if looksLikeMathExpression(String(inside)) {
                    let inner = inside.trimmingCharacters(in: .whitespacesAndNewlines)
                    let insideTrimmed = stripNestedMathDelimiters(inner)
                    let multiline = insideTrimmed.contains("\n")
                    let standalone = isStandaloneBracketBlock(text: text, open: idx, closeEnd: cursor)
                    if multiline || standalone {
                        out.append("\\\\[")
                        if multiline { out.append("\n") }
                        out.append(contentsOf: insideTrimmed)
                        if multiline { out.append("\n") }
                        out.append("\\\\]")
                    } else {
                        out.append("\\\\(")
                        out.append(contentsOf: insideTrimmed)
                        out.append("\\\\)")
                    }
                    idx = cursor
                    prevWasBackslash = false
                    continue
                }
            }

            out.append(ch)
            prevWasBackslash = ch == "\\"
            idx = text.index(after: idx)
        }

        return out
    }

    private static func isStandaloneBracketBlock(text: String, open: String.Index, closeEnd: String.Index) -> Bool {
        let lineStart = text[..<open].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[closeEnd...].firstIndex(of: "\n") ?? text.endIndex

        let before = text[lineStart..<open]
        let after = text[closeEnd..<lineEnd]

        let hasNonWhitespaceBefore = before.contains(where: { !$0.isWhitespace })
        let hasNonWhitespaceAfter = after.contains(where: { !$0.isWhitespace })
        return !hasNonWhitespaceBefore && !hasNonWhitespaceAfter
    }

    private static func wrapInlineBracketMath(in line: String) -> String {
        var out = String()
        out.reserveCapacity(line.count)

        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            guard ch == "[" else {
                out.append(ch)
                idx = line.index(after: idx)
                continue
            }

            let prev = idx > line.startIndex ? line[line.index(before: idx)] : nil
            if let prev, isASCIILetter(prev) || prev == "\\" {
                out.append(ch)
                idx = line.index(after: idx)
                continue
            }

            var depth = 1
            var cursor = line.index(after: idx)
            while cursor < line.endIndex, depth > 0 {
                let c = line[cursor]
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1 }
                cursor = line.index(after: cursor)
            }

            guard depth == 0 else {
                out.append(ch)
                idx = line.index(after: idx)
                continue
            }

            let closingBracket = line.index(before: cursor)
            let afterClosing = line.index(after: closingBracket)
            let remainder = afterClosing < line.endIndex ? line[afterClosing...] : Substring()
            let remainderTrimmed = remainder.drop(while: { $0 == " " || $0 == "\t" })
            if remainderTrimmed.first == "(" || remainderTrimmed.first == ":" {
                out.append(ch)
                idx = line.index(after: idx)
                continue
            }

            let inside = line[line.index(after: idx)..<closingBracket]
            if looksLikeMathExpression(inside) {
                let insideTrimmed = stripNestedMathDelimiters(inside.trimmingCharacters(in: .whitespacesAndNewlines))
                let before = line[..<idx]
                let after = line[cursor...]
                let hasNonWhitespaceBefore = before.contains(where: { !$0.isWhitespace })
                let hasNonWhitespaceAfter = after.contains(where: { !$0.isWhitespace })

                if !hasNonWhitespaceBefore && !hasNonWhitespaceAfter {
                    out.append("\\\\[")
                    out.append(contentsOf: insideTrimmed)
                    out.append("\\\\]")
                } else {
                    out.append("\\\\(")
                    out.append(contentsOf: insideTrimmed)
                    out.append("\\\\)")
                }
                idx = cursor
                continue
            }

            out.append(ch)
            idx = line.index(after: idx)
        }

        return out
    }

    private static func wrapMultilineBracketMathBlock(
        startingAt startIndex: Int,
        lines: [Substring]
    ) -> (replacement: String, endIndex: Int)? {
        let startLine = String(lines[startIndex])
        let indent = String(startLine.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmedLeading = startLine.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmedLeading.first == "[" else { return nil }

        let openIdx = startLine.index(startLine.startIndex, offsetBy: indent.count)
        guard openIdx < startLine.endIndex, startLine[openIdx] == "[" else { return nil }

        // If the opening line closes the bracket block, treat it as a single-line case and let the inline wrapper handle it.
        var depth = 1
        var cursor = startLine.index(after: openIdx)
        var prev: Character? = nil
        while cursor < startLine.endIndex {
            let ch = startLine[cursor]
            if ch == "[", prev != "\\" { depth += 1 }
            if ch == "]", prev != "\\" {
                depth -= 1
                if depth == 0 { return nil }
            }
            prev = ch
            cursor = startLine.index(after: cursor)
        }

        depth = 1
        var capture = ""
        var closingRemainder = ""
        var endIndex: Int? = nil

        for j in startIndex..<lines.count {
            let line = String(lines[j])
            var idx = line.startIndex
            if j == startIndex {
                idx = line.index(after: openIdx)
            } else {
                capture.append("\n")
            }

            prev = nil
            while idx < line.endIndex {
                let ch = line[idx]
                if ch == "[", prev != "\\" {
                    depth += 1
                    capture.append(ch)
                } else if ch == "]", prev != "\\" {
                    depth -= 1
                    if depth == 0 {
                        let after = line.index(after: idx)
                        closingRemainder = after < line.endIndex ? String(line[after...]) : ""
                        endIndex = j
                        break
                    }
                    capture.append(ch)
                } else {
                    capture.append(ch)
                }
                prev = ch
                idx = line.index(after: idx)
            }

            if endIndex != nil { break }
        }

        guard let endIndex else { return nil }

        let remainderTrimmed = closingRemainder.drop(while: { $0 == " " || $0 == "\t" })
        if remainderTrimmed.first == "(" || remainderTrimmed.first == ":" {
            return nil
        }

        let inner = capture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeMathExpression(inner) else { return nil }

        let replacement = indent + "\\\\[\n" + stripNestedMathDelimiters(inner) + "\n\\\\]" + closingRemainder
        return (replacement: replacement, endIndex: endIndex)
    }

    private static func lineContainsBracketedMath(_ line: String) -> Bool {
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            guard ch == "[" else {
                idx = line.index(after: idx)
                continue
            }

            let prev = idx > line.startIndex ? line[line.index(before: idx)] : nil
            if let prev, isASCIILetter(prev) || prev == "\\" {
                idx = line.index(after: idx)
                continue
            }

            var depth = 1
            var cursor = line.index(after: idx)
            while cursor < line.endIndex, depth > 0 {
                let c = line[cursor]
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1 }
                cursor = line.index(after: cursor)
            }

            if depth != 0 {
                idx = line.index(after: idx)
                continue
            }

            let closingBracket = line.index(before: cursor)
            let afterClosing = line.index(after: closingBracket)
            let remainder = afterClosing < line.endIndex ? line[afterClosing...] : Substring()
            let remainderTrimmed = remainder.drop(while: { $0 == " " || $0 == "\t" })
            if remainderTrimmed.first == "(" || remainderTrimmed.first == ":" {
                idx = line.index(after: idx)
                continue
            }

            let inside = line[line.index(after: idx)..<closingBracket]
            if looksLikeMathExpression(inside) {
                return true
            }

            idx = line.index(after: idx)
        }

        return false
    }

    private static func looksLikeMathExpression(_ inside: Substring) -> Bool {
        let trimmed = inside.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return looksLikeMathExpression(String(trimmed))
    }

    private static func looksLikeMathExpression(_ inside: String) -> Bool {
        let s = inside.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }

        if s.contains("http:") || s.contains("https:") || s.contains("://") { return false }
        if s.contains(":\\") { return false }

        if containsLatexCommand(s) { return true }

        if s.contains("^") || s.contains("_") { return true }
        if s.contains("=") { return true }

        let hasDigits = s.rangeOfCharacter(from: .decimalDigits) != nil
        let hasMathSymbols = s.contains("+")
            || s.contains("-")
            || s.contains("*")
            || s.contains("/")
            || s.contains("<")
            || s.contains(">")
            || s.contains("≤")
            || s.contains("≥")
            || s.contains("∈")
            || s.contains("≈")
            || s.contains("≠")

        if hasDigits && hasMathSymbols { return true }

        if s.contains("->") || s.contains("=>") { return true }

        return false
    }

    private static func wrapParenthesizedMathExpressions(_ text: String) -> String {
        var inFence: String? = nil
        var inMathBlock = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)

        for raw in lines {
            let line = String(raw)
            let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
            let trimmed = trimmedLeading.trimmingCharacters(in: .whitespacesAndNewlines)

            if let fence = inFence {
                outLines.append(line)
                if trimmedLeading.hasPrefix(fence) {
                    inFence = nil
                }
                continue
            }

            if trimmedLeading.hasPrefix("```") {
                inFence = "```"
                outLines.append(line)
                continue
            }
            if trimmedLeading.hasPrefix("~~~") {
                inFence = "~~~"
                outLines.append(line)
                continue
            }

            // Don't try to wrap parenthesized math inside already-delimited math blocks.
            if inMathBlock {
                outLines.append(line)
                if trimmed.hasPrefix("\\]") { inMathBlock = false }
                continue
            }

            if trimmed == "\\[" {
                inMathBlock = true
                outLines.append(line)
                continue
            }

            // If a line already contains display-math delimiters, skip it to avoid nesting.
            if line.contains("\\[") || line.contains("\\]") || line.contains("$$") {
                outLines.append(line)
                continue
            }

            outLines.append(wrapInlineParenthesisMath(in: line))
        }

        return outLines.joined(separator: "\n")
    }

    private static func wrapInlineParenthesisMath(in line: String) -> String {
        guard line.contains("("), line.contains(")") else { return line }

        var out = String()
        out.reserveCapacity(line.count)

        var idx = line.startIndex
        var inInlineCode = false
        var prevWasBackslash = false

        while idx < line.endIndex {
            let ch = line[idx]

            if ch == "`", !prevWasBackslash {
                inInlineCode.toggle()
                out.append(ch)
                idx = line.index(after: idx)
                continue
            }

            if inInlineCode {
                out.append(ch)
                prevWasBackslash = ch == "\\"
                idx = line.index(after: idx)
                continue
            }

            guard ch == "(" else {
                out.append(ch)
                prevWasBackslash = ch == "\\"
                idx = line.index(after: idx)
                continue
            }

            let prev = idx > line.startIndex ? line[line.index(before: idx)] : nil
            if prev == "\\" || prev == "]" {
                out.append(ch)
                prevWasBackslash = false
                idx = line.index(after: idx)
                continue
            }

            if isImmediatelyAfterLatexCommand(in: line, at: idx) {
                out.append(ch)
                prevWasBackslash = false
                idx = line.index(after: idx)
                continue
            }

            var depth = 1
            var cursor = line.index(after: idx)
            while cursor < line.endIndex, depth > 0 {
                let c = line[cursor]
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1 }
                cursor = line.index(after: cursor)
            }

            guard depth == 0 else {
                out.append(ch)
                prevWasBackslash = false
                idx = line.index(after: idx)
                continue
            }

            let closingParen = line.index(before: cursor)
            let inside = line[line.index(after: idx)..<closingParen]
            if looksLikeInlineParenthesizedMathExpression(inside) {
                let insideTrimmed = stripNestedMathDelimiters(inside.trimmingCharacters(in: .whitespacesAndNewlines))
                out.append("\\\\(")
                out.append("(")
                out.append(contentsOf: insideTrimmed)
                out.append(")")
                out.append("\\\\)")
                idx = cursor
                prevWasBackslash = false
                continue
            }

            out.append(ch)
            prevWasBackslash = false
            idx = line.index(after: idx)
        }

        return out
    }

    /// Parentheses occur in normal prose constantly; wrapping the wrong thing into math makes the
    /// whole parenthetical render in KaTeX italics (and collapses spaces). Be conservative here:
    /// only wrap when we see strong math signals.
    private static func looksLikeInlineParenthesizedMathExpression(_ inside: Substring) -> Bool {
        let trimmed = inside.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return looksLikeInlineParenthesizedMathExpression(String(trimmed))
    }

    private static func looksLikeInlineParenthesizedMathExpression(_ inside: String) -> Bool {
        let s = inside.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }

        if s.contains("http:") || s.contains("https:") || s.contains("://") { return false }
        if s.contains(":\\") { return false }

        if containsLatexCommand(s) { return true }
        if s.contains("^") || s.contains("_") || s.contains("=") { return true }

        // Common math relations/symbols.
        if s.contains("<") || s.contains(">") || s.contains("≤") || s.contains("≥") || s.contains("∈") || s.contains("≈") || s.contains("≠") {
            return true
        }

        // Arrow-ish notation is usually math.
        if s.contains("->") || s.contains("=>") { return true }

        return false
    }

    private static func stripNestedMathDelimiters(_ text: String) -> String {
        guard text.contains("\\") else { return text }

        var out = String()
        out.reserveCapacity(text.count)

        var prevWasBackslash = false
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "\\" {
                let next = text.index(after: idx)
                if next < text.endIndex {
                    let nextCh = text[next]
                    if (nextCh == "(" || nextCh == ")" || nextCh == "[" || nextCh == "]") && !prevWasBackslash {
                        idx = text.index(after: next)
                        prevWasBackslash = false
                        continue
                    }
                }
                out.append(ch)
                prevWasBackslash = true
                idx = text.index(after: idx)
                continue
            }

            out.append(ch)
            prevWasBackslash = false
            idx = text.index(after: idx)
        }

        return out
    }

    private static func isImmediatelyAfterLatexCommand(in line: String, at parenIndex: String.Index) -> Bool {
        guard parenIndex > line.startIndex else { return false }
        var idx = line.index(before: parenIndex)
        guard isASCIILetter(line[idx]) else { return false }

        while idx > line.startIndex {
            let prev = line.index(before: idx)
            if isASCIILetter(line[prev]) {
                idx = prev
            } else {
                break
            }
        }

        let beforeLetters = idx > line.startIndex ? line.index(before: idx) : nil
        if let beforeLetters, line[beforeLetters] == "\\" { return true }
        return false
    }

    private static func isASCIILetter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, scalar.isASCII else { return false }
        return (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }
}
#endif
