import Foundation

/// Parses Apple Music TTML lyric payloads into a `LyricsDocument`.
///
/// Apple's TTML carries line timing in `<p begin end>` and (when
/// `itunes:timing="Word"`) syllable timing in nested `<span begin end>` tags.
/// We capture both — line timings drive the existing sync engine; syllables
/// are stored for a future per-word overlay without forcing a re-fetch.
///
/// Time values come in any of: `HH:MM:SS.mmm`, `MM:SS.mmm`, `SS.mmm`, `Ns`.
nonisolated enum TTMLParser {
    static func parse(ttml: String, source: LyricsSource = .appleMusicWeb) -> LyricsDocument? {
        AppTelemetry.measure("TTMLParser.parse") {
            parseImpl(ttml: ttml, source: source)
        }
    }

    private static func parseImpl(ttml: String, source: LyricsSource) -> LyricsDocument? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        unsafe parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), !delegate.lines.isEmpty else {
            return nil
        }
        let isTimed = delegate.lines.contains { $0.startTime != nil }
        return LyricsDocument(
            source: source,
            lines: delegate.lines,
            isTimed: isTimed,
            sourceLanguageIdentifier: delegate.language
        )
    }

    static func parseTimecode(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("s") {
            return Double(trimmed.dropLast())
        }
        let parts = trimmed.split(separator: ":")
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }

    static func languageTag(in ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = LanguageDelegate()
        let parser = XMLParser(data: data)
        unsafe parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return delegate.language
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var lines: [LyricLine] = []
        var language: String?

        private var inP = false
        private var pBegin: TimeInterval?
        private var pEnd: TimeInterval?
        private var pSpans: [LyricSyllable] = []
        private var pText: String = ""
        private struct SpanContext {
            let begin: TimeInterval?
            let end: TimeInterval?
            var text = ""
            var syllables: [LyricSyllable] = []
        }
        private var spans: [SpanContext] = []
        private var nextID = 0
        private var timingMode: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = localName(elementName)
            switch name {
            case "tt":
                language = attributeDict["xml:lang"] ?? attributeDict["lang"]
                timingMode = attributeDict["itunes:timing"] ?? attributeDict["timing"]
            case "p":
                inP = true
                pBegin = TTMLParser.parseTimecode(attributeDict["begin"])
                pEnd = TTMLParser.parseTimecode(attributeDict["end"])
                pSpans.removeAll()
                pText = ""
                spans.removeAll()
            case "span":
                guard inP else { return }
                spans.append(SpanContext(
                    begin: TTMLParser.parseTimecode(attributeDict["begin"]),
                    end: TTMLParser.parseTimecode(attributeDict["end"])
                ))
            case "br":
                // Apple uses <br/> for in-line breaks within a paragraph.
                // Preserve as a space so words don't run together.
                if !spans.isEmpty { spans[spans.count - 1].text += " " } else if inP { pText += " " }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !spans.isEmpty {
                spans[spans.count - 1].text += string
            } else if inP {
                pText += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = localName(elementName)
            switch name {
            case "span":
                guard let span = spans.popLast() else { return }
                if var parent = spans.popLast() {
                    appendSpan(span, to: &parent.text, syllables: &parent.syllables)
                    spans.append(parent)
                } else {
                    appendSpan(span, to: &pText, syllables: &pSpans)
                }
            case "p":
                let cleaned = normalizeInlineWhitespace(pText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    lines.append(LyricLine(
                        id: nextID,
                        text: cleaned,
                        startTime: pBegin,
                        endTime: pEnd,
                        syllables: pSpans
                    ))
                    nextID += 1
                }
                inP = false
                pBegin = nil
                pEnd = nil
                pSpans.removeAll()
                pText = ""
                spans.removeAll()
            default:
                break
            }
        }

        private func appendSpan(_ span: SpanContext, to text: inout String, syllables: inout [LyricSyllable]) {
            let normalizedText = normalizeInlineWhitespace(span.text)
            let trimmedText = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                if span.text.contains(where: \.isWhitespace) {
                    appendSpaceToPreviousSyllable(in: &syllables)
                    text = appendSpaceIfNeeded(to: text)
                }
                return
            }

            let startsWithSpace = normalizedText.first?.isWhitespace == true
            let endsWithSpace = normalizedText.last?.isWhitespace == true

            if startsWithSpace || shouldInferSpace(before: trimmedText, previous: syllables.last?.text) {
                appendSpaceToPreviousSyllable(in: &syllables)
                text = appendSpaceIfNeeded(to: text)
            }

            let visibleText = endsWithSpace ? "\(trimmedText) " : trimmedText
            if !span.syllables.isEmpty {
                // Prefer explicit child timings over an overlapping wrapper.
                syllables.append(contentsOf: span.syllables)
            } else if let begin = span.begin, let end = span.end {
                syllables.append(LyricSyllable(text: visibleText, startTime: begin, endTime: end))
            }
            text += visibleText
        }

        private func shouldInferSpace(before text: String, previous previousText: String?) -> Bool {
            guard timingMode?.localizedCaseInsensitiveCompare("Word") == .orderedSame,
                  let previousText,
                  previousText.last?.isWhitespace != true,
                  let previous = previousText.last,
                  let current = text.first else {
                return false
            }

            return previous.shouldSpaceBeforeNextWord && current.canStartInferredWordLikeSpan
        }

        private func appendSpaceToPreviousSyllable(in syllables: inout [LyricSyllable]) {
            guard let last = syllables.last, last.text.last?.isWhitespace != true else {
                return
            }

            syllables[syllables.count - 1] = LyricSyllable(
                text: "\(last.text) ",
                startTime: last.startTime,
                endTime: last.endTime
            )
        }

        private func appendSpaceIfNeeded(to text: String) -> String {
            guard !text.isEmpty, text.last?.isWhitespace != true else {
                return text
            }
            return "\(text) "
        }

        private func normalizeInlineWhitespace(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .withPreservedEdgeWhitespace(from: text)
        }

        private func localName(_ qualified: String) -> String {
            if let colon = qualified.firstIndex(of: ":") {
                return String(qualified[qualified.index(after: colon)...])
            }
            return qualified
        }
    }

    private final class LanguageDelegate: NSObject, XMLParserDelegate {
        var language: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard localName(elementName) == "tt" else { return }
            language = attributeDict["xml:lang"] ?? attributeDict["lang"]
            parser.abortParsing()
        }

        private func localName(_ qualified: String) -> String {
            if let colon = qualified.firstIndex(of: ":") {
                return String(qualified[qualified.index(after: colon)...])
            }
            return qualified
        }
    }
}

nonisolated private extension Character {
    var canStartInferredWordLikeSpan: Bool {
        isWordOrNumber || isOpeningLyricPunctuation
    }

    var shouldSpaceBeforeNextWord: Bool {
        isWordOrNumber || isClosingLyricPunctuation || isSentencePunctuation
    }

    var isWordOrNumber: Bool {
        (isLetter || isNumber) && !isUsuallyUnspacedLyricScript
    }

    var isOpeningLyricPunctuation: Bool {
        self == "(" || self == "[" || self == "{" || self == "“" || self == "‘" || self == "\"" || self == "'"
    }

    var isClosingLyricPunctuation: Bool {
        self == ")" || self == "]" || self == "}" || self == "”" || self == "’" || self == "\"" || self == "'"
    }

    var isSentencePunctuation: Bool {
        self == "," || self == "." || self == "!" || self == "?" || self == ";" || self == ":" || self == "…" || self == "،" || self == "؛" || self == "؟"
    }

    var isUsuallyUnspacedLyricScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana + Katakana
                 0x31F0...0x31FF, // Katakana phonetic extensions
                 0x3400...0x4DBF, // CJK extension A
                 0x4E00...0x9FFF, // CJK unified ideographs
                 0xAC00...0xD7AF, // Hangul syllables
                 0x1100...0x11FF, // Hangul Jamo
                 0x0E00...0x0E7F, // Thai
                 0x0E80...0x0EFF, // Lao
                 0x1780...0x17FF, // Khmer
                 0x1000...0x109F: // Myanmar
                return true
            default:
                return false
            }
        }
    }
}

nonisolated private extension String {
    func withPreservedEdgeWhitespace(from source: String) -> String {
        guard !isEmpty else { return self }
        var result = self
        if source.first?.isWhitespace == true {
            result = " \(result)"
        }
        if source.last?.isWhitespace == true {
            result += " "
        }
        return result
    }
}
