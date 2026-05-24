import Foundation

public struct StandardPrinter {
    private let options: RipgrepOptions
    private let pathFormatter: OutputPathFormatter
    private let colors: ANSIColorPalette
    private let hyperlinks: HyperlinkFormatter

    public init(
        options: RipgrepOptions,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.options = options
        self.pathFormatter = OutputPathFormatter(options: options, currentDirectory: currentDirectory)
        let colorPalette = ANSIColorPalette(options: options)
        self.colors = colorPalette
        self.hyperlinks = HyperlinkFormatter(options: options, colorsEnabled: colorPalette.isEnabled)
    }

    public func lines(for results: SearchResults) -> [String] {
        if options.quiet && options.stats {
            return statsLines(for: results, bytesPrinted: 0)
        }
        if options.quiet {
            return []
        }

        let body = bodyLines(for: results)
        if options.stats {
            let printedBytes = options.printMode == .matchingLines ? bytesPrinted(body) : 0
            return body + statsLines(for: results, bytesPrinted: printedBytes)
        }
        return body
    }

    private func bodyLines(for results: SearchResults) -> [String] {
        switch options.printMode {
        case .matchingLines:
            if options.vimgrep {
                return vimgrepLines(for: results, showPath: options.withFilename != false)
            }
            if options.heading == true {
                return headingLines(for: results)
            }
            if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
                return contextLines(for: results, showPath: showPath(for: results))
            }
            if options.onlyMatching {
                return results.files.flatMap { result in
                    if let binaryLine = formatBinaryMatch(result, showPath: showPath(for: results)) {
                        return [binaryLine]
                    }
                    return result.matches.flatMap { formatOnlyMatching($0, showPath: showPath(for: results)) }
                }
            }
            if options.multiline, options.replacement == nil {
                return results.files.flatMap { result in
                    let matchLines = multilineMatchLines(for: result, showPath: showPath(for: results))
                    if let binaryLine = formatBinaryMatch(result, showPath: showPath(for: results)) {
                        if let offset = result.binaryByteOffset, offset < 64 * 1024 {
                            return [binaryLine]
                        }
                        return matchLines + [binaryLine]
                    }
                    return matchLines
                }
            }
            return results.files.flatMap { result in
                let matchLines = result.matches.flatMap { formatSearchMatch($0, showPath: showPath(for: results)) }
                if let binaryLine = formatBinaryMatch(result, showPath: showPath(for: results)) {
                    if result.stoppedBinaryAfterMatch && !matchLines.isEmpty {
                        return matchLines + [binaryLine]
                    }
                    if let offset = result.binaryByteOffset, offset < 64 * 1024 {
                        return [binaryLine]
                    }
                    return matchLines + [binaryLine]
                }
                return matchLines
            }
        case .count:
            return countResults(for: results).map { result in
                let count = options.onlyMatching
                    ? onlyMatchingCount(for: result)
                    : options.multiline && options.effectivePatterns.contains(where: containsLineEndAnchor)
                        ? countMatchesCount(for: result)
                    : result.matches.isEmpty && result.hasBinaryMatch ? 1 : result.matches.count + result.supplementalMatchedLines
                return countLine(count, fileURL: result.fileURL, showPath: showPath(for: results))
            }
        case .countMatches:
            return countResults(for: results).map { result in
                let count = result.matches.isEmpty && result.hasBinaryMatch
                    ? 1
                    : countMatchesCount(for: result)
                return countLine(count, fileURL: result.fileURL, showPath: showPath(for: results))
            }
        case .filesWithMatches:
            return results.files
                .filter(\.hasMatch)
                .map { "\(renderPath(for: $0.fileURL))\(searchPathTerminator())" }
        case .filesWithoutMatch:
            return results.files
                .filter { $0.searched && !$0.hasMatch && !$0.stoppedBinaryAfterMatch }
                .map { "\(renderPath(for: $0.fileURL))\(searchPathTerminator())" }
        }
    }

    private func countable(_ result: SearchFileResult) -> Bool {
        if result.stoppedBinaryAfterMatch {
            return false
        }
        return options.includeZero ? result.searched : result.hasMatch
    }

    private func countResults(for results: SearchResults) -> [SearchFileResult] {
        results.files.filter { countable($0) }
    }

    private func countLine(_ count: Int, fileURL: URL, showPath: Bool) -> String {
        let suffix = options.crlf && !options.nullData ? "\r" : outputTerminator("")
        if showPath {
            return "\(renderPath(for: fileURL))\(pathFieldSeparator())\(count)\(suffix)"
        }
        return "\(count)\(suffix)"
    }

    private func onlyMatchingCount(for result: SearchFileResult) -> Int {
        if hasAnyAbsoluteStartAnchorPattern {
            return result.matches.count + result.supplementalMatches
        }
        if options.multiline && options.effectivePatterns.allSatisfy(isBareMultilineLineEndPattern) {
            return result.matches.reduce(0) { total, match in
                total + (match.matchCount == 0 && match.line.contains("\0") ? 1 : match.matchCount)
            } + result.supplementalMatches
        }
        if options.nullData && options.effectivePatterns.contains(where: containsLineAnchor) {
            return result.matches.reduce(0) { $0 + max(1, $1.matchCount) } + result.supplementalMatches
        }
        return result.matches.reduce(0) { $0 + $1.matchCount } + result.supplementalMatches
    }

    private func countMatchesCount(for result: SearchFileResult) -> Int {
        if hasAnyAbsoluteStartAnchorPattern {
            return result.matches.count + result.supplementalMatches
        }
        if options.multiline && options.effectivePatterns.allSatisfy(isBareMultilineLineEndPattern) {
            return result.matches.reduce(0) { total, match in
                total + (match.matchCount == 0 && match.line.contains("\0") ? 1 : match.matchCount)
            } + result.supplementalMatches
        }
        if options.nullData && options.effectivePatterns.contains(where: containsLineAnchor) {
            return result.matches.reduce(0) { $0 + max(1, $1.matchCount) } + result.supplementalMatches
        }
        return result.matches.reduce(0) { $0 + $1.matchCount } + result.supplementalMatches
    }

    private var hasAnyAbsoluteStartAnchorPattern: Bool {
        !options.multiline && options.effectivePatterns.contains(where: containsAbsoluteStartAnchor)
    }

    private func containsAbsoluteStartAnchor(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                if !inClass && character == "A" {
                    return true
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                continue
            }
            if character == "]" {
                inClass = false
            }
        }
        return false
    }

    public func paths(_ urls: [URL]) -> [String] {
        urls.map { "\(renderPath(for: $0))\(pathTerminator())" }
    }

    private func format(_ match: SearchMatch, showPath: Bool) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber, column: match.column) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(match.lineNumber)", colorTarget: .line))
        }
        if options.column, let column = match.column {
            fields.append(OutputField("\(column)", colorTarget: .column))
        }
        if options.byteOffset {
            fields.append(OutputField("\(match.absoluteOffset)", colorTarget: nil))
        }

        let prefixText = prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator)
        let line = renderedLine(for: match)
        if shouldEmitRawLineBytes(for: match) {
            return rawByteLine(prefix: prefixText, text: line)
        }
        return "\(prefixText)\(line)"
    }

    private func formatSearchMatch(_ match: SearchMatch, showPath: Bool) -> [String] {
        if shouldEmitRawLineBytes(for: match) {
            return [format(match, showPath: showPath)]
        }
        guard options.multiline, containsRenderedLineTerminator(match.line) else {
            return [format(match, showPath: showPath)]
        }

        let text = options.replacement == nil ? match.lineWithTerminator : renderedText(for: match)
        let lines = splitRenderedLines(text)
        var lineStartByte = 0
        return lines.enumerated().map { offset, line in
            var fields: [OutputField] = []
            let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber + offset) : nil
            if options.wantsLineNumber {
                fields.append(OutputField("\(match.lineNumber + offset)", colorTarget: .line))
            }
            let rendered = limitedMatchedLine(line, match: match, lineStartByte: lineStartByte) ?? renderedLine(line)
            lineStartByte += line.utf8.count + renderedLineTerminatorByteCount()
            return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(rendered)"
        }
    }

    private func formatVimgrep(_ result: SearchFileResult, showPath: Bool) -> [String] {
        result.matches.flatMap { match in
            formatVimgrep(match, showPath: showPath)
        }
    }

    private func formatVimgrep(_ match: SearchMatch, showPath: Bool) -> [String] {
        if match.spans.isEmpty {
            return [formatVimgrepPreservedLine(match, showPath: showPath)]
        }
        let replacementLine = options.replacement == nil ? nil : firstRenderedLine(renderedText(for: match))
        let replacementOffsets = replacementStartOffsetsByIndex(for: match)
        return match.spans.enumerated().compactMap { index, span in
            if shouldSuppressMultilineVimgrepSpan(span, in: match) {
                return nil
            }
            let replacementStartByte = replacementOffsets[index]
            let projection = vimgrepSpanProjection(for: span, in: match)
            let lineText = replacementLine.map { vimgrepReplacementLineText($0, match: match) }
                ?? projection?.renderedLine
                ?? vimgrepLineText(for: match)
            let rawText = options.onlyMatching
                ? (span.replacement ?? span.text)
                : lineText
            let text = coloredVimgrepText(
                rawText,
                span: span,
                match: match,
                projection: projection,
                replacementLine: replacementLine,
                replacementStartByte: replacementStartByte
            )
            let column = span.replacement == nil
                ? projection?.column ?? span.startColumn
                : column(in: replacementLine ?? match.line, byteOffset: replacementStartByte)
            let lineNumber = projection?.lineNumber ?? match.lineNumber
            let byteOffset = options.byteOffset
                ? vimgrepByteOffset(
                    match: match,
                    span: span,
                    replacementStartByte: replacementStartByte,
                    projection: projection
                )
                : nil
            let fields = vimgrepFields(
                lineNumber: lineNumber,
                column: column,
                byteOffset: byteOffset,
                text: text
            )
            let terminator = outputTerminator(
                match.lineTerminator,
                line: options.onlyMatching ? span.text : (replacementLine ?? projection?.line ?? match.line),
                crlfMatchTerminator: options.onlyMatching,
                forceCRLF: isColumnLimitedVimgrepLine(match: match, replacementLine: replacementLine, projectedLine: projection?.line)
            )
            guard showPath else {
                return "\(fields.joined(separator: options.fieldMatchSeparator))\(terminator)"
            }
            let path = renderPath(for: match.fileURL, line: lineNumber, column: column)
            return "\(path)\(matchPathFieldSeparator())\(fields.joined(separator: options.fieldMatchSeparator))\(terminator)"
        }
    }

    private func formatVimgrepPreservedLine(_ match: SearchMatch, showPath: Bool) -> String {
        var fields: [String] = []
        if !options.noLineNumber {
            fields.append(colors.apply(.line, to: "\(match.lineNumber)"))
        }
        fields.append(vimgrepLineText(for: match))
        let terminator = outputTerminator(
            match.lineTerminator,
            line: match.line,
            forceCRLF: isColumnLimitedVimgrepLine(match: match, replacementLine: nil)
        )
        guard showPath else {
            return "\(fields.joined(separator: options.fieldMatchSeparator))\(terminator)"
        }
        let path = renderPath(for: match.fileURL, line: match.lineNumber)
        return "\(path)\(matchPathFieldSeparator())\(fields.joined(separator: options.fieldMatchSeparator))\(terminator)"
    }

    private struct VimgrepSpanProjection {
        let lineNumber: Int
        let column: Int
        let lineStartByte: Int
        let line: String
        let renderedLine: String
    }

    private func vimgrepSpanProjection(for span: MatchSpan, in match: SearchMatch) -> VimgrepSpanProjection? {
        guard options.multiline,
              options.replacement == nil,
              !options.nullData,
              containsRenderedLineTerminator(match.line) else {
            return nil
        }
        var lineStartByte = 0
        var lineNumber = match.lineNumber
        var current = String.UnicodeScalarView()

        for scalar in match.line.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            if scalar == "\n" {
                let line = String(current)
                if span.startByte < lineStartByte + line.utf8.count + scalarBytes {
                    return VimgrepSpanProjection(
                        lineNumber: lineNumber,
                        column: column(in: line, byteOffset: max(0, span.startByte - lineStartByte)),
                        lineStartByte: lineStartByte,
                        line: line,
                        renderedLine: renderedLine(line)
                    )
                }
                lineStartByte += line.utf8.count + scalarBytes
                lineNumber += 1
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
        }

        let line = String(current)
        return VimgrepSpanProjection(
            lineNumber: lineNumber,
            column: column(in: line, byteOffset: max(0, span.startByte - lineStartByte)),
            lineStartByte: lineStartByte,
            line: line,
            renderedLine: renderedLine(line)
        )
    }

    private func vimgrepFields(lineNumber: Int, column: Int, byteOffset: Int?, text: String) -> [String] {
        var fields: [String] = []
        if !options.noLineNumber {
            fields.append(colors.apply(.line, to: "\(lineNumber)"))
        }
        if !options.noColumn {
            fields.append(colors.apply(.column, to: "\(column)"))
        }
        if let byteOffset {
            fields.append(colors.apply(.column, to: "\(byteOffset)"))
        }
        fields.append(text)
        return fields
    }

    private func vimgrepByteOffset(
        match: SearchMatch,
        span: MatchSpan,
        replacementStartByte: Int,
        projection: VimgrepSpanProjection?
    ) -> Int {
        if let projection {
            return match.absoluteOffset + projection.lineStartByte
        }
        if options.multiline,
           options.replacement == nil,
           span.replacement == nil,
           options.effectivePatterns.contains(where: containsLineEndAnchor) {
            return match.absoluteOffset
        }
        return match.absoluteOffset + replacementStartByte
    }

    private func coloredVimgrepText(
        _ text: String,
        span: MatchSpan,
        match: SearchMatch,
        projection: VimgrepSpanProjection?,
        replacementLine: String?,
        replacementStartByte: Int
    ) -> String {
        guard colors.isEnabled else {
            return text
        }
        if options.onlyMatching {
            return colors.apply(.match, to: text)
        }
        if let replacement = span.replacement {
            let replacementSpan = MatchSpan(
                startColumn: span.startColumn,
                endColumn: span.endColumn,
                startByte: replacementStartByte,
                endByte: replacementStartByte + replacement.utf8.count,
                text: replacement
            )
            return colors.colorMatches(in: text, spans: [replacementSpan])
        }
        if let projection,
           let maxColumns = options.maxColumns,
           options.maxColumnsPreview {
            let rendered = options.trim ? projection.line.trimmingASCIIWhitespacePrefix() : projection.line
            if rendered.utf8.count >= maxColumns {
                let trimOffset = projection.line.utf8.count - rendered.utf8.count
                let previewStartByte = projection.lineStartByte + trimOffset + maxColumns
                let lineEndByte = projection.lineStartByte + projection.line.utf8.count
                let remainingMatches = match.spans.filter {
                    $0.startByte >= previewStartByte && $0.startByte <= lineEndByte
                }.count
                return previewMatchedLineSuffix(
                    rendered,
                    maxColumns: maxColumns,
                    remainingMatches: remainingMatches,
                    spans: [span],
                    lineStartByte: projection.lineStartByte,
                    trimOffset: trimOffset
                )
            }
        }
        let sourceLine = options.nullData ? match.line : firstRenderedLine(match.line)
        if let maxColumns = options.maxColumns,
           options.maxColumnsPreview {
            let rendered = options.trim ? sourceLine.trimmingASCIIWhitespacePrefix() : sourceLine
            if rendered.utf8.count >= maxColumns {
                let trimOffset = sourceLine.utf8.count - rendered.utf8.count
                let previewStartByte = trimOffset + maxColumns
                let remainingMatches = match.spans.filter {
                    $0.startByte >= previewStartByte && $0.startByte <= sourceLine.utf8.count
                }.count
                return previewMatchedLineSuffix(
                    rendered,
                    maxColumns: maxColumns,
                    remainingMatches: remainingMatches,
                    spans: [span],
                    lineStartByte: 0,
                    trimOffset: trimOffset
                )
            }
        }
        let textOffset = match.line.utf8.count - sourceLine.utf8.count
        let coloredSpan = MatchSpan(
            startColumn: span.startColumn,
            endColumn: span.endColumn,
            startByte: max(0, span.startByte - textOffset),
            endByte: max(0, span.endByte - textOffset),
            text: span.text
        )
        return colors.colorMatches(in: text, spans: [coloredSpan])
    }

    private func vimgrepLineText(for match: SearchMatch) -> String {
        if options.nullData {
            return renderedLine(match.line)
        }
        let line = firstRenderedLine(match.line)
        guard let maxColumns = options.maxColumns, line.utf8.count >= maxColumns else {
            return renderedLine(line)
        }
        let rendered = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        guard options.maxColumnsPreview else {
            return "[Omitted long line with \(match.matchCount) matches]"
        }
        let trimOffset = line.utf8.count - rendered.utf8.count
        let remainingMatches = match.spans.filter { $0.startByte >= trimOffset + maxColumns }.count
        return previewLineSuffix(rendered, maxColumns: maxColumns, remainingMatches: remainingMatches)
    }

    private func vimgrepReplacementLineText(_ line: String, match: SearchMatch) -> String {
        guard let maxColumns = options.maxColumns, line.utf8.count >= maxColumns else {
            return renderedLine(line)
        }
        guard options.maxColumnsPreview else {
            return "[Omitted long line with \(match.matchCount) matches]"
        }
        let rendered = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        let trimOffset = line.utf8.count - rendered.utf8.count
        let remainingMatches = replacementStartOffsets(for: match).filter { $0 >= trimOffset + maxColumns }.count
        return previewLineSuffix(rendered, maxColumns: maxColumns, remainingMatches: remainingMatches)
    }

    private func formatBinaryMatch(_ result: SearchFileResult, showPath: Bool) -> String? {
        guard result.hasBinaryMatch, let offset = result.binaryByteOffset else {
            return nil
        }
        let message = result.stoppedBinaryAfterMatch
            ? #"WARNING: stopped searching binary file after match (found "\0" byte around offset \#(offset))"#
            : #"binary file matches (found "\0" byte around offset \#(offset))"#
        if showPath {
            return "\(renderPath(for: result.fileURL))\(matchPathFieldSeparator()) \(message)"
        }
        return message
    }

    private func formatOnlyMatching(
        _ match: SearchMatch,
        showPath: Bool,
        fieldSeparator: String? = nil,
        forcePositiveSpans: Bool = false
    ) -> [String] {
        let separator = fieldSeparator ?? options.fieldMatchSeparator
        if options.invertMatch && !forcePositiveSpans {
            return [formatOnlyMatchingInverted(match, showPath: showPath)]
        }
        if match.spans.isEmpty {
            return [formatOnlyMatchingEmptySubmatches(match, showPath: showPath, fieldSeparator: separator)]
        }

        let replacementOffsets = replacementStartOffsetsByIndex(for: match)
        return match.spans.enumerated().flatMap { index, span in
            if shouldSuppressNullDataOnlyMatchingSpan(span, in: match) {
                return [String]()
            }
            if shouldSuppressMultilineEmptyOnlyMatch(span) {
                return [String]()
            }
            if options.multiline, span.replacement != nil, containsRenderedLineTerminator(span.text) {
                return formatOnlyMatchingReplacementMultiline(span, in: match, showPath: showPath)
            }
            if options.multiline,
               span.replacement == nil,
               containsRenderedLineTerminator(span.text) || containsRenderedLineTerminator(match.line) {
                return formatOnlyMatchingMultiline(span, in: match, showPath: showPath)
            }
            let replacementStartByte = replacementOffsets[index]
            let column = span.replacement == nil
                ? onlyMatchingColumn(for: span, in: match, replacementStartByte: replacementStartByte)
                : column(in: renderedText(for: match), byteOffset: replacementStartByte)
            var fields: [OutputField] = []
            let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber, column: column) : nil
            if options.wantsLineNumber {
                fields.append(OutputField("\(match.lineNumber)", colorTarget: .line))
            }
            if options.column {
                fields.append(OutputField("\(column)", colorTarget: .column))
            }
            if options.byteOffset {
                fields.append(OutputField("\(match.absoluteOffset + replacementStartByte)", colorTarget: nil))
            }
            let prefixText = prefix(path: path, fields: fields, fieldSeparator: separator)
            let text = onlyMatchingOutputText(span, in: match)
            if shouldEmitRawOnlyMatchingBytes(span, in: match) {
                return [rawByteLine(prefix: prefixText, text: text)]
            }
            return ["\(prefixText)\(text)"]
        }
    }

    private func shouldSuppressNullDataOnlyMatchingSpan(_ span: MatchSpan, in match: SearchMatch) -> Bool {
        options.nullData
            && span.text.isEmpty
            && span.replacement == nil
            && span.startByte == 0
            && span.endByte == 0
            && match.absoluteOffset > 0
            && options.effectivePatterns.contains(where: containsLineStartAnchor)
            && options.effectivePatterns.contains(where: containsLineStartEndAlternation)
    }

    private func onlyMatchingOutputText(_ span: MatchSpan, in match: SearchMatch) -> String {
        if let text = nullDataLineStartOnlyMatchingText(span, in: match) {
            return text
        }
        let text = onlyMatchingText(span, in: match)
        if span.replacement != nil,
           !options.nullData,
           text.unicodeScalars.last == "\n" {
            return String(String.UnicodeScalarView(text.unicodeScalars.dropLast()))
        }
        return "\(text)\(outputTerminator(match.lineTerminator, line: span.text, crlfMatchTerminator: true))"
    }

    private func shouldEmitRawLineBytes(for match: SearchMatch) -> Bool {
        match.rawLine != nil && options.replacement == nil && !colors.isEnabled
    }

    private func shouldEmitRawLineBytes(for line: SearchLine) -> Bool {
        line.rawLine != nil && !colors.isEnabled
    }

    private func shouldEmitRawOnlyMatchingBytes(_ span: MatchSpan, in match: SearchMatch) -> Bool {
        match.rawLine != nil && span.replacement == nil && !colors.isEnabled
    }

    private func rawByteLine(prefix: String, text: String) -> String {
        var bytes = Array(prefix.utf8)
        bytes.append(contentsOf: text.rawByteData())
        return .rawByteMarked(bytes)
    }

    private func nullDataLineStartOnlyMatchingText(_ span: MatchSpan, in match: SearchMatch) -> String? {
        guard options.nullData,
              span.text.isEmpty,
              span.replacement == nil,
              span.startByte == 0,
              span.endByte == 0,
              match.absoluteOffset > 0,
              !match.line.contains("\n"),
              options.effectivePatterns.contains(where: containsLineStartAnchor),
              !options.effectivePatterns.contains(where: containsLineEndAnchor) else {
            return nil
        }
        let text = options.trim ? match.line.trimmingASCIIWhitespacePrefix() : match.line
        return "\(colors.apply(.match, to: text))\(outputTerminator(match.lineTerminator, line: match.line, crlfMatchTerminator: true))"
    }

    private func formatOnlyMatchingEmptySubmatches(
        _ match: SearchMatch,
        showPath: Bool,
        fieldSeparator: String
    ) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber, column: match.column) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(match.lineNumber)", colorTarget: .line))
        }
        if options.column, let column = match.column {
            fields.append(OutputField("\(column)", colorTarget: .column))
        }
        if options.byteOffset {
            fields.append(OutputField("\(match.absoluteOffset)", colorTarget: nil))
        }
        let text = "\(renderedText(for: match))\(outputTerminator(match.lineTerminator, line: match.line, crlfMatchTerminator: true))"
        return "\(prefix(path: path, fields: fields, fieldSeparator: fieldSeparator))\(text)"
    }

    private func shouldSuppressMultilineEmptyOnlyMatch(_ span: MatchSpan) -> Bool {
        options.multiline
            && span.text.isEmpty
            && span.replacement == nil
            && !options.fixedStrings
            && !options.effectivePatterns.isEmpty
            && options.effectivePatterns.contains(where: containsLineAnchor)
    }

    private func shouldSuppressMultilineVimgrepSpan(_ span: MatchSpan, in match: SearchMatch) -> Bool {
        guard options.multiline,
              span.text.isEmpty,
              span.replacement == nil,
              !options.fixedStrings else {
            return false
        }
        if options.effectivePatterns.contains(where: containsLineStartAnchor),
           (!options.effectivePatterns.contains(where: containsLineEndAnchor)
            || isMultilineLineStartSpan(span, in: match)) {
            return true
        }
        return match.line.isEmpty && options.effectivePatterns.contains(where: containsLineEndAnchor)
    }

    private func isMultilineLineStartSpan(_ span: MatchSpan, in match: SearchMatch) -> Bool {
        guard span.startByte == span.endByte else {
            return false
        }
        if span.startByte == 0 {
            return true
        }
        let bytes = Array(match.lineWithTerminator.utf8)
        guard span.startByte <= bytes.count else {
            return false
        }
        return bytes[span.startByte - 1] == UInt8(ascii: "\n")
    }

    private func containsLineAnchor(_ pattern: String) -> Bool {
        containsLineStartAnchor(pattern) || containsLineEndAnchor(pattern)
    }

    private func containsLineStartEndAlternation(_ pattern: String) -> Bool {
        let alternatives = topLevelAlternatives(in: pattern)
        guard alternatives.count > 1 else {
            return false
        }
        return alternatives.contains(where: containsLineStartAnchor)
            && alternatives.contains(where: containsLineEndAnchor)
    }

    private func containsLineStartAnchor(_ pattern: String) -> Bool {
        containsAnchor("^", in: pattern)
    }

    private func containsLineEndAnchor(_ pattern: String) -> Bool {
        containsAnchor("$", in: pattern)
    }

    private func topLevelAlternatives(in pattern: String) -> [String] {
        var alternatives: [String] = []
        var escaped = false
        var inClass = false
        var depth = 0
        var start = pattern.startIndex
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "[":
                inClass = true
            case "]":
                inClass = false
            case "(" where !inClass:
                depth += 1
            case ")" where !inClass:
                depth = max(0, depth - 1)
            case "|" where !inClass && depth == 0:
                alternatives.append(String(pattern[start..<index]))
                start = pattern.index(after: index)
            default:
                break
            }
            index = pattern.index(after: index)
        }
        guard !alternatives.isEmpty else {
            return [pattern]
        }
        alternatives.append(String(pattern[start..<pattern.endIndex]))
        return alternatives
    }

    private func containsAnchor(_ anchor: Character, in pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                continue
            }
            if character == "]" {
                inClass = false
                continue
            }
            if !inClass && character == anchor {
                return true
            }
        }
        return false
    }

    private func formatOnlyMatchingInverted(_ match: SearchMatch, showPath: Bool) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(match.lineNumber)", colorTarget: .line))
        }
        if options.byteOffset {
            fields.append(OutputField("\(match.absoluteOffset)", colorTarget: nil))
        }
        let text = "\(renderedLine(match.line))\(outputTerminator(match.lineTerminator, line: match.line))"
        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(text)"
    }

    private func formatOnlyMatchingMultiline(_ span: MatchSpan, in match: SearchMatch, showPath: Bool) -> [String] {
        multilineOnlyMatchingChunks(for: span).map { chunk in
            let chunkStartByte = span.startByte + chunk.startByte
            let lineNumber = match.lineNumber
                + lineOffset(in: match.lineWithTerminator, beforeByteOffset: chunkStartByte)
            var fields: [OutputField] = []
            let column: Int
            if multilineOnlyMatchingUsesSourceAbsoluteColumns {
                column = match.absoluteOffset + span.startByte + 1
            } else if multilineOnlyMatchingUsesMatchRelativeColumns {
                column = span.startByte + chunk.startByte + 1
            } else {
                column = chunk.startByte == 0 ? span.startColumn : 1
            }
            let path = showPath ? renderPath(for: match.fileURL, line: lineNumber, column: column) : nil
            if options.wantsLineNumber {
                fields.append(OutputField("\(lineNumber)", colorTarget: .line))
            }
            if options.column {
                fields.append(OutputField("\(column)", colorTarget: .column))
            }
            if options.byteOffset {
                fields.append(OutputField("\(match.absoluteOffset + span.startByte)", colorTarget: nil))
            }
            return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(colors.apply(.match, to: chunk.text))\(outputTerminator(match.lineTerminator, line: chunk.text, crlfMatchTerminator: true))"
        }
    }

    private func formatOnlyMatchingReplacementMultiline(_ span: MatchSpan, in match: SearchMatch, showPath: Bool) -> [String] {
        let text = span.replacement ?? span.text
        let chunks = splitRenderedLines(text)
        let startLineOffset = lineOffset(in: match.lineWithTerminator, beforeByteOffset: span.startByte)
        var runningByteOffset = match.absoluteOffset + span.startByte

        return chunks.enumerated().map { offset, chunk in
            let lineNumber = match.lineNumber + startLineOffset + offset
            var fields: [OutputField] = []
            let column = offset == 0 ? span.startColumn : 1
            let path = showPath ? renderPath(for: match.fileURL, line: lineNumber, column: column) : nil
            if options.wantsLineNumber {
                fields.append(OutputField("\(lineNumber)", colorTarget: .line))
            }
            if options.column {
                fields.append(OutputField("\(column)", colorTarget: .column))
            }
            if options.byteOffset {
                fields.append(OutputField("\(runningByteOffset)", colorTarget: nil))
            }
            runningByteOffset += chunk.utf8.count + 1
            return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(colors.apply(.match, to: chunk))\(outputTerminator(match.lineTerminator, line: chunk, crlfMatchTerminator: true))"
        }
    }

    private struct MultilineOnlyMatchingChunk {
        let text: String
        let startByte: Int
    }

    private func multilineOnlyMatchingChunks(for span: MatchSpan) -> [MultilineOnlyMatchingChunk] {
        let text = span.replacement ?? span.text
        let terminator: UnicodeScalar = text.contains("\0") ? "\0" : "\n"
        var chunks: [MultilineOnlyMatchingChunk] = []
        var current = String.UnicodeScalarView()
        var currentStartByte = 0
        var nextByte = 0

        for scalar in text.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            if scalar == terminator {
                if !current.isEmpty {
                    chunks.append(MultilineOnlyMatchingChunk(
                        text: String(current),
                        startByte: currentStartByte
                    ))
                }
                nextByte += scalarByteCount
                currentStartByte = nextByte
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
                nextByte += scalarByteCount
            }
        }

        if !current.isEmpty || text.unicodeScalars.last != terminator {
            chunks.append(MultilineOnlyMatchingChunk(
                text: String(current),
                startByte: currentStartByte
            ))
        }
        return chunks
    }

    private func onlyMatchingColumn(
        for span: MatchSpan,
        in match: SearchMatch,
        replacementStartByte: Int
    ) -> Int {
        if multilineOnlyMatchingUsesSourceAbsoluteColumns {
            return match.absoluteOffset + replacementStartByte + 1
        }
        if multilineOnlyMatchingUsesMatchRelativeColumns {
            return replacementStartByte + 1
        }
        return span.startColumn
    }

    private var multilineOnlyMatchingUsesSourceAbsoluteColumns: Bool {
        options.multiline
            && !options.fixedStrings
            && (options.multilineDotall
                || options.effectivePatterns.contains(where: containsInlineDotAllOption))
    }

    private var multilineOnlyMatchingUsesMatchRelativeColumns: Bool {
        options.multiline
            && !options.fixedStrings
            && options.effectivePatterns.contains(where: containsLineAnchor)
    }

    private func containsInlineDotAllOption(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass, pattern[index...].hasPrefix("(?") {
                var optionIndex = pattern.index(index, offsetBy: 2)
                var enablesDotAll = false
                var disabling = false
                while optionIndex < pattern.endIndex {
                    let option = pattern[optionIndex]
                    if option == ")" || option == ":" {
                        return enablesDotAll
                    }
                    if option == "-" {
                        disabling = true
                    } else if option == "s" {
                        enablesDotAll = !disabling
                    }
                    optionIndex = pattern.index(after: optionIndex)
                }
                return false
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private func headingLines(for results: SearchResults) -> [String] {
        var output: [String] = []
        let showPath = showPath(for: results)
        for result in results.files {
            if result.matches.isEmpty,
               let binaryLine = formatBinaryMatch(result, showPath: showPath) {
                output.append(binaryLine)
                continue
            }
            let lines: [String]
            if let binaryLine = formatBinaryMatch(result, showPath: false) {
                lines = [binaryLine]
            } else if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
                lines = contextLines(for: result, showPath: false)
            } else if options.onlyMatching {
                lines = result.matches.flatMap { formatOnlyMatching($0, showPath: false) }
            } else if options.multiline, options.replacement == nil {
                lines = multilineMatchLines(for: result, showPath: false)
            } else {
                lines = result.matches.flatMap { formatSearchMatch($0, showPath: false) }
            }
            guard !lines.isEmpty else {
                continue
            }
            if !output.isEmpty {
                output.append(options.nullData ? "\0" : "")
            }
            if showPath {
                output.append("\(renderPath(for: result.fileURL))\(searchPathTerminator())")
            }
            output.append(contentsOf: lines)
        }
        return output
    }

    private func contextLines(for result: SearchFileResult, showPath: Bool) -> [String] {
        if let binaryLine = formatBinaryMatch(result, showPath: showPath) {
            return [binaryLine]
        }
        let matchedLineNumbers = multilineMatchedLineNumbers(for: result)
        let startMatchesByLine = firstMatchesByLine(for: result)
        let matchesByLine = matchesGroupedByLine(for: result)
        let selectedLineNumbers: [Int]
        if options.passthru {
            selectedLineNumbers = result.lines.map(\.lineNumber)
        } else {
            let lineCount = result.lines.count
            guard lineCount > 0 else {
                return []
            }
            let selected = result.matches.reduce(into: Set<Int>()) { lineNumbers, match in
                let matchLineNumbers = multilineLineNumbers(for: match)
                let lower = max(1, (matchLineNumbers.first ?? match.lineNumber) - options.beforeContext)
                let upper = min(lineCount, (matchLineNumbers.last ?? match.lineNumber) + options.afterContext)
                guard lower <= upper else {
                    return
                }
                for lineNumber in lower...upper {
                    lineNumbers.insert(lineNumber)
                }
            }
            selectedLineNumbers = selected.sorted()
        }

        var output: [String] = []
        var previous: Int?
        for lineNumber in selectedLineNumbers {
            if let previous, lineNumber > previous + 1, !options.passthru {
                if let contextSeparator = options.contextSeparator {
                    output.append(contextSeparator)
                }
            }
            guard let line = result.lines.first(where: { $0.lineNumber == lineNumber }) else {
                continue
            }
            if options.onlyMatching, let matches = matchesByLine[lineNumber] {
                output.append(contentsOf: matches.flatMap { formatOnlyMatching($0, showPath: showPath) })
            } else if options.onlyMatching,
                      !options.passthru,
                      !options.invertMatch,
                      !options.multiline,
                      let positiveMatch = positiveMatch(for: line, fileURL: result.fileURL) {
                output.append(contentsOf: formatOnlyMatching(positiveMatch, showPath: showPath))
            } else if options.onlyMatching,
                      options.invertMatch,
                      !options.multiline,
                      let positiveMatch = positiveMatch(for: line, fileURL: result.fileURL) {
                output.append(contentsOf: formatOnlyMatching(
                    positiveMatch,
                    showPath: showPath,
                    fieldSeparator: options.fieldContextSeparator,
                    forcePositiveSpans: true
                ))
            } else if options.onlyMatching, matchedLineNumbers.contains(lineNumber) {
                previous = lineNumber
                continue
            } else if let match = startMatchesByLine[lineNumber], shouldUseWholeMatchFormatter(match) {
                output.append(format(match, showPath: showPath))
            } else if matchedLineNumbers.contains(lineNumber)
                        || (!options.passthru && !options.invertMatch && !line.positiveSpans.isEmpty) {
                output.append(formatMatchedLine(
                    line,
                    fileURL: result.fileURL,
                    showPath: showPath,
                    match: startMatchesByLine[lineNumber] ?? positiveMatch(for: line, fileURL: result.fileURL)
                ))
            } else {
                output.append(formatContextLine(line, fileURL: result.fileURL, showPath: showPath))
            }
            previous = lineNumber
        }
        return output
    }

    private func vimgrepContextLines(for result: SearchFileResult, showPath: Bool) -> [String] {
        let matchesByLine = result.matches.reduce(into: [Int: [SearchMatch]]()) { grouped, match in
            grouped[match.lineNumber, default: []].append(match)
        }
        let selectedLineNumbers: [Int]
        if options.passthru {
            selectedLineNumbers = result.lines.map(\.lineNumber)
        } else {
            selectedLineNumbers = vimgrepSelectedContextLineNumbers(for: result)
        }

        var output: [String] = []
        var previous: Int?
        for lineNumber in selectedLineNumbers {
            if let previous, lineNumber > previous + 1, !options.passthru {
                if let contextSeparator = options.contextSeparator {
                    output.append(contextSeparator)
                }
            }
            guard let line = result.lines.first(where: { $0.lineNumber == lineNumber }) else {
                continue
            }
            if let matches = matchesByLine[lineNumber] {
                output.append(contentsOf: matches.flatMap { formatVimgrep($0, showPath: showPath) })
            } else if !options.passthru, !options.invertMatch, !line.positiveSpans.isEmpty {
                let positiveMatch = SearchMatch(
                    fileURL: result.fileURL,
                    lineNumber: line.lineNumber,
                    column: options.column ? line.positiveSpans.first?.startColumn : nil,
                    line: line.line,
                    rawLine: line.rawLine,
                    lineTerminator: line.lineTerminator,
                    absoluteOffset: line.absoluteOffset,
                    matchCount: line.positiveSpans.count,
                    spans: line.positiveSpans
                )
                output.append(contentsOf: formatVimgrep(positiveMatch, showPath: showPath))
            } else {
                output.append(formatVimgrepContextLine(line, fileURL: result.fileURL, showPath: showPath))
            }
            if let matches = matchesByLine[lineNumber] {
                previous = max(lineNumber, matches.flatMap { multilineLineNumbers(for: $0) }.max() ?? lineNumber)
            } else {
                previous = lineNumber
            }
        }
        return output
    }

    private func vimgrepLines(for results: SearchResults, showPath: Bool) -> [String] {
        let shouldSeparateFiles = !options.passthru
            && (options.beforeContext > 0 || options.afterContext > 0)
        var output: [String] = []
        for result in results.files {
            let lines = vimgrepLines(for: result, showPath: showPath)
            guard !lines.isEmpty else {
                continue
            }
            if shouldSeparateFiles,
               !output.isEmpty,
               !isBinaryOnlyContextResult(result),
               let contextSeparator = options.contextSeparator {
                output.append(contextSeparator)
            }
            output.append(contentsOf: lines)
        }
        return output
    }

    private func vimgrepLines(for result: SearchFileResult, showPath: Bool) -> [String] {
        if let binaryLine = formatBinaryMatch(result, showPath: showPath) {
            return [binaryLine]
        }
        if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
            return vimgrepContextLines(for: result, showPath: showPath)
        }
        return formatVimgrep(result, showPath: showPath)
    }

    private func vimgrepSelectedContextLineNumbers(for result: SearchFileResult) -> [Int] {
        let lineCount = result.lines.count
        let selected = result.matches.reduce(into: Set<Int>()) { lineNumbers, match in
            let matchLineNumbers = multilineLineNumbers(for: match)
            let firstLine = matchLineNumbers.first ?? match.lineNumber
            let lastLine = matchLineNumbers.last ?? match.lineNumber
            let lower = max(1, firstLine - options.beforeContext)
            let upper = min(lineCount, lastLine + options.afterContext)

            if lower < firstLine {
                for lineNumber in lower..<firstLine {
                    lineNumbers.insert(lineNumber)
                }
            }
            lineNumbers.insert(firstLine)
            if lastLine < upper {
                for lineNumber in (lastLine + 1)...upper {
                    lineNumbers.insert(lineNumber)
                }
            }
        }
        return selected.sorted()
    }

    private func contextLines(for results: SearchResults, showPath: Bool) -> [String] {
        let shouldSeparateFiles = !options.passthru
            && (options.beforeContext > 0 || options.afterContext > 0)
        var output: [String] = []
        for result in results.files {
            let lines = contextLines(for: result, showPath: showPath)
            guard !lines.isEmpty else {
                continue
            }
            if shouldSeparateFiles,
               !output.isEmpty,
               !isBinaryOnlyContextResult(result),
               let contextSeparator = options.contextSeparator {
                output.append(contextSeparator)
            }
            output.append(contentsOf: lines)
        }
        return output
    }

    private func isBinaryOnlyContextResult(_ result: SearchFileResult) -> Bool {
        result.hasBinaryMatch && result.binaryByteOffset != nil
    }

    private func shouldUseWholeMatchFormatter(_ match: SearchMatch) -> Bool {
        !options.multiline || (options.replacement != nil && multilineLineNumbers(for: match).count == 1)
    }

    private func multilineMatchLines(for result: SearchFileResult, showPath: Bool) -> [String] {
        let matchedLineNumbers = multilineMatchedLineNumbers(for: result)
        let startMatchesByLine = firstMatchesByLine(for: result)
        return result.lines.compactMap { line in
            guard matchedLineNumbers.contains(line.lineNumber) else {
                return nil
            }
            return formatMatchedLine(
                line,
                fileURL: result.fileURL,
                showPath: showPath,
                match: startMatchesByLine[line.lineNumber] ?? multilineContinuationMatch(for: line, fileURL: result.fileURL)
            )
        }
    }

    private func multilineContinuationMatch(for line: SearchLine, fileURL: URL) -> SearchMatch? {
        guard options.multiline else {
            return nil
        }
        return SearchMatch(
            fileURL: fileURL,
            lineNumber: line.lineNumber,
            column: options.column ? 1 : nil,
            line: line.line,
            rawLine: line.rawLine,
            lineTerminator: line.lineTerminator,
            absoluteOffset: line.absoluteOffset,
            matchCount: 1,
            spans: []
        )
    }

    private func multilineMatchedLineNumbers(for result: SearchFileResult) -> Set<Int> {
        guard options.multiline else {
            return Set(result.matches.map(\.lineNumber))
        }
        var lineNumbers = result.matches.reduce(into: Set<Int>()) { lineNumbers, match in
            for lineNumber in multilineLineNumbers(for: match) {
                lineNumbers.insert(lineNumber)
            }
        }
        if shouldIncludeTrailingMultilineEndAnchorLine(result, matchedLineNumbers: lineNumbers),
           let lastLineNumber = result.lines.last?.lineNumber {
            lineNumbers.insert(lastLineNumber)
        }
        return lineNumbers
    }

    private func shouldIncludeTrailingMultilineEndAnchorLine(
        _ result: SearchFileResult,
        matchedLineNumbers: Set<Int>
    ) -> Bool {
        guard options.multiline,
              options.replacement == nil,
              options.effectivePatterns.contains(where: isBareMultilineLineEndPattern),
              let lastLine = result.lines.last,
              lastLine.lineTerminator.isEmpty,
              !matchedLineNumbers.contains(lastLine.lineNumber) else {
            return false
        }
        return lastLine.lineNumber == 1 || matchedLineNumbers.contains(lastLine.lineNumber - 1)
    }

    private func isBareMultilineLineEndPattern(_ pattern: String) -> Bool {
        if pattern == "$" {
            return true
        }
        guard pattern.hasPrefix("(?"),
              pattern.hasSuffix(")"),
              let colon = pattern.firstIndex(of: ":") else {
            return false
        }
        let flagStart = pattern.index(pattern.startIndex, offsetBy: 2)
        let flags = pattern[flagStart..<colon]
        let bodyStart = pattern.index(after: colon)
        let body = pattern[bodyStart..<pattern.index(before: pattern.endIndex)]
        return flags.contains("m") && body == "$"
    }

    private func firstMatchesByLine(for result: SearchFileResult) -> [Int: SearchMatch] {
        result.matches.reduce(into: [:]) { matchesByLine, match in
            matchesByLine[match.lineNumber] = matchesByLine[match.lineNumber] ?? match
        }
    }

    private func matchesGroupedByLine(for result: SearchFileResult) -> [Int: [SearchMatch]] {
        result.matches.reduce(into: [:]) { matchesByLine, match in
            matchesByLine[match.lineNumber, default: []].append(match)
        }
    }

    private func multilineLineNumbers(for match: SearchMatch) -> [Int] {
        guard options.multiline else {
            return [match.lineNumber]
        }
        let lineCount = splitRenderedLines(match.lineWithTerminator).count
        return Array(match.lineNumber..<(match.lineNumber + max(1, lineCount)))
    }

    private func formatContextLine(_ line: SearchLine, fileURL: URL, showPath: Bool) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: fileURL, line: line.lineNumber) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(line.lineNumber)", colorTarget: .line))
        }
        if options.byteOffset {
            fields.append(OutputField("\(line.absoluteOffset)", colorTarget: nil))
        }

        let text = displayLine(for: line)
        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldContextSeparator))\(renderedLine(text, omittedKind: .context))\(outputTerminator(line.lineTerminator, line: text, forceCRLF: isColumnLimitedLine(text)))"
    }

    private func positiveMatch(for line: SearchLine, fileURL: URL) -> SearchMatch? {
        guard !line.positiveSpans.isEmpty else {
            return nil
        }
        return SearchMatch(
            fileURL: fileURL,
            lineNumber: line.lineNumber,
            column: options.column ? line.positiveSpans.first?.startColumn : nil,
            line: line.line,
            rawLine: line.rawLine,
            lineTerminator: line.lineTerminator,
            absoluteOffset: line.absoluteOffset,
            matchCount: line.positiveSpans.count,
            spans: line.positiveSpans
        )
    }

    private func formatVimgrepContextLine(_ line: SearchLine, fileURL: URL, showPath: Bool) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: fileURL, line: line.lineNumber) : nil
        if !options.noLineNumber {
            fields.append(OutputField("\(line.lineNumber)", colorTarget: .line))
        }
        if options.byteOffset {
            fields.append(OutputField("\(line.absoluteOffset)", colorTarget: nil))
        }

        let text = displayLine(for: line)
        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldContextSeparator))\(renderedLine(text, omittedKind: .context))\(outputTerminator(line.lineTerminator, line: text, forceCRLF: isColumnLimitedLine(text)))"
    }

    private func formatMatchedLine(_ line: SearchLine, fileURL: URL, showPath: Bool, match: SearchMatch?) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: fileURL, line: line.lineNumber, column: match?.column) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(line.lineNumber)", colorTarget: .line))
        }
        if options.column, let column = match?.column {
            fields.append(OutputField("\(column)", colorTarget: .column))
        }
        if options.byteOffset, let match {
            fields.append(OutputField("\(match.absoluteOffset)", colorTarget: nil))
        }

        let text = displayLine(for: line)
        let lineStartByte = match.map { max(0, line.absoluteOffset - $0.absoluteOffset) } ?? 0
        let rendered = match.flatMap {
            limitedMatchedLine(text, match: $0, lineStartByte: lineStartByte)
        } ?? renderedLine(text)
        let prefixText = prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator)
        let output = "\(rendered)\(outputTerminator(line.lineTerminator, line: text, forceCRLF: isColumnLimitedLine(text)))"
        if shouldEmitRawLineBytes(for: line) {
            return rawByteLine(prefix: prefixText, text: output)
        }
        return "\(prefixText)\(output)"
    }

    private func renderedLine(for match: SearchMatch) -> String {
        guard options.replacement != nil, !match.spans.isEmpty else {
            let line = displayLine(for: match)
            if let rendered = limitedMatchedLine(line, match: match) {
                return "\(rendered)\(outputTerminator(match.lineTerminator, line: line, forceCRLF: true))"
            }
            if let rendered = limitedColumnMatchedLine(line, match: match) {
                return "\(rendered)\(outputTerminator(match.lineTerminator, line: line, forceCRLF: true))"
            }
            return "\(renderedLine(line, spans: match.rawLine == nil ? match.spans : []))\(outputTerminator(match.lineTerminator, line: line, forceCRLF: isColumnLimitedLine(line)))"
        }
        let originalLine = match.line
        let line = renderedText(for: match)
        if let rendered = limitedReplacementLine(line, originalLine: originalLine, match: match) {
            return "\(rendered)\(outputTerminator(match.lineTerminator, line: match.line, forceCRLF: true))"
        }
        return "\(renderedLine(line))\(outputTerminator(match.lineTerminator, line: line))"
    }

    private func limitedMatchedLine(_ line: String, match: SearchMatch) -> String? {
        limitedMatchedLine(line, match: match, lineStartByte: 0)
    }

    private func limitedMatchedLine(_ line: String, match: SearchMatch, lineStartByte: Int) -> String? {
        guard let maxColumns = options.maxColumns,
              line.utf8.count >= maxColumns else {
            return nil
        }
        let rendered = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        let trimOffset = line.utf8.count - rendered.utf8.count
        if options.stats || colors.isEnabled {
            guard options.maxColumnsPreview else {
                return "[Omitted long line with \(match.matchCount) matches]"
            }
            let lineEndByte = lineStartByte + line.utf8.count
            let previewStartByte = lineStartByte + trimOffset + maxColumns
            let remainingMatches = match.spans.filter {
                $0.startByte >= previewStartByte && $0.startByte <= lineEndByte
            }.count
            return previewMatchedLineSuffix(
                rendered,
                maxColumns: maxColumns,
                remainingMatches: remainingMatches,
                spans: match.spans,
                lineStartByte: lineStartByte,
                trimOffset: trimOffset
            )
        }
        return nil
    }

    private func limitedColumnMatchedLine(_ line: String, match: SearchMatch) -> String? {
        let rendered = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        guard options.column,
              let maxColumns = options.maxColumns,
              rendered.utf8.count >= maxColumns,
              !options.maxColumnsPreview else {
            return nil
        }
        return "[Omitted long line with \(match.matchCount) matches]"
    }

    private func renderedText(for match: SearchMatch) -> String {
        if let byteRendered = byteRenderedReplacementText(for: match) {
            return byteRendered
        }
        var line = match.line
        for span in match.spans.sorted(by: { $0.startByte > $1.startByte }) {
            guard let replacement = span.replacement,
                  let range = indexRange(startByte: span.startByte, endByte: span.endByte, in: line) else {
                continue
            }
            line.replaceSubrange(range, with: replacement)
        }
        return line
    }

    private func byteRenderedReplacementText(for match: SearchMatch) -> String? {
        guard options.replacement != nil,
              match.spans.contains(where: { $0.replacement != nil }),
              match.spans.contains(where: { !hasStringBoundary(atByteOffset: $0.startByte, in: match.line) || !hasStringBoundary(atByteOffset: $0.endByte, in: match.line) }) else {
            return nil
        }
        var bytes = Array(match.line.utf8)
        for span in match.spans.sorted(by: { lhs, rhs in
            if lhs.startByte == rhs.startByte {
                return lhs.endByte > rhs.endByte
            }
            return lhs.startByte > rhs.startByte
        }) {
            guard let replacement = span.replacement,
                  span.startByte >= 0,
                  span.endByte >= span.startByte,
                  span.endByte <= bytes.count else {
                continue
            }
            bytes.replaceSubrange(span.startByte..<span.endByte, with: replacement.utf8)
        }
        return String.rawByteMarked(bytes)
    }

    private func displayLine(for match: SearchMatch) -> String {
        guard match.rawLine != nil, options.replacement == nil, !colors.isEnabled else {
            return match.line
        }
        return match.rawLine ?? match.line
    }

    private func displayLine(for line: SearchLine) -> String {
        guard line.rawLine != nil, !colors.isEnabled else {
            return line.line
        }
        return line.rawLine ?? line.line
    }

    private func renderedLine(_ line: String, omittedKind: OmittedLineKind = .matching) -> String {
        let trimmed = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        return limitedLine(trimmed, omittedKind: omittedKind)
    }

    private func renderedLine(_ line: String, spans: [MatchSpan]) -> String {
        guard colors.isEnabled, !spans.isEmpty else {
            return renderedLine(line)
        }
        guard options.trim else {
            if let maxColumns = options.maxColumns, line.utf8.count >= maxColumns {
                return renderedLine(line)
            }
            return colors.colorMatches(in: line, spans: spans)
        }
        let trimmed = line.trimmingASCIIWhitespacePrefix()
        if let maxColumns = options.maxColumns, trimmed.utf8.count >= maxColumns {
            return renderedLine(line)
        }
        let trimOffset = line.utf8.count - trimmed.utf8.count
        let trimmedSpans = spans.compactMap { span -> MatchSpan? in
            guard span.endByte > trimOffset else {
                return nil
            }
            let startByte = max(0, span.startByte - trimOffset)
            let endByte = max(startByte, span.endByte - trimOffset)
            return MatchSpan(
                startColumn: span.startColumn,
                endColumn: span.endColumn,
                startByte: startByte,
                endByte: endByte,
                text: span.text,
                replacement: span.replacement
            )
        }
        return colors.colorMatches(in: trimmed, spans: trimmedSpans)
    }

    private func outputTerminator(
        _ terminator: String,
        line: String? = nil,
        crlfMatchTerminator: Bool = false,
        forceCRLF: Bool = false
    ) -> String {
        if options.nullData {
            return "\0"
        }
        if options.crlf,
           (forceCRLF || terminator.isEmpty || colors.isEnabled || crlfMatchTerminator),
           line?.hasSuffix("\r") != true {
            return "\r"
        }
        return ""
    }

    private func isColumnLimitedVimgrepLine(match: SearchMatch, replacementLine: String?, projectedLine: String? = nil) -> Bool {
        if let replacementLine {
            return isColumnLimitedLine(replacementLine, originalLine: match.line)
        }
        if let projectedLine {
            return isColumnLimitedLine(projectedLine)
        }
        return isColumnLimitedLine(options.nullData ? match.line : firstRenderedLine(match.line))
    }

    private func isColumnLimitedLine(_ line: String, originalLine: String? = nil) -> Bool {
        guard let maxColumns = options.maxColumns else {
            return false
        }
        if let originalLine, originalLine.utf8.count >= maxColumns {
            return true
        }
        let rendered = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        return rendered.utf8.count >= maxColumns
    }

    private func pathTerminator() -> String {
        options.nullPathTerminator ? "\0" : ""
    }

    private func searchPathTerminator() -> String {
        options.nullPathTerminator || options.nullData ? "\0" : ""
    }

    private func pathFieldSeparator() -> String {
        options.nullPathTerminator ? "\0" : ":"
    }

    private func matchPathFieldSeparator() -> String {
        options.nullPathTerminator ? "\0" : options.fieldMatchSeparator
    }

    private func prefix(path: String?, fields: [OutputField], fieldSeparator: String) -> String {
        var prefix = ""
        if let path {
            prefix += path
            prefix += options.nullPathTerminator ? "\0" : fieldSeparator
        }
        if !fields.isEmpty {
            prefix += fields.map { field in
                guard let colorTarget = field.colorTarget else {
                    return field.text
                }
                return colors.apply(colorTarget, to: field.text)
            }.joined(separator: fieldSeparator)
            prefix += fieldSeparator
        }
        return prefix
    }

    private func renderPath(for url: URL, line: Int? = nil, column: Int? = nil) -> String {
        let text = colors.apply(.path, to: displayPath(for: url))
        return hyperlinks.label(text, for: url, line: line, column: column)
    }

    private func limitedLine(_ line: String, omittedKind: OmittedLineKind) -> String {
        guard let maxColumns = options.maxColumns, line.utf8.count >= maxColumns else {
            return line
        }
        guard options.maxColumnsPreview else {
            return omittedKind.message
        }
        return "\(line.prefixColumns(maxColumns)) [... omitted end of long line]"
    }

    private func limitedReplacementLine(_ line: String, originalLine: String, match: SearchMatch) -> String? {
        guard let maxColumns = options.maxColumns, originalLine.utf8.count >= maxColumns else {
            return nil
        }
        guard options.maxColumnsPreview else {
            return "[Omitted long line with \(match.matchCount) \(match.matchCount == 1 ? "match" : "matches")]"
        }
        guard line.utf8.count >= maxColumns else {
            return nil
        }
        let remainingMatches = replacementStartOffsets(for: match).filter { $0 >= maxColumns }.count
        return previewLineSuffix(line, maxColumns: maxColumns, remainingMatches: remainingMatches)
    }

    private func onlyMatchingText(_ span: MatchSpan, in match: SearchMatch) -> String {
        let rawText = rawOnlyMatchingText(span, in: match) ?? span.replacement ?? span.text
        let text = options.trim ? rawText.trimmingASCIIWhitespacePrefix() : rawText
        guard let maxColumns = options.maxColumns,
              text.utf8.count > maxColumns else {
            return colors.apply(.match, to: text)
        }
        guard options.maxColumnsPreview else {
            return OmittedLineKind.matching.message
        }
        let remainingMatches = span.replacement == nil && span.startByte == maxColumns ? 1 : 0
        return previewLineSuffix(text, maxColumns: maxColumns, remainingMatches: remainingMatches)
    }

    private func rawOnlyMatchingText(_ span: MatchSpan, in match: SearchMatch) -> String? {
        guard (options.emitsRawBytes || match.rawLine != nil),
              span.replacement == nil,
              let rawLine = match.rawLine,
              span.startByte <= span.endByte else {
            return nil
        }
        let scalars = rawLine.unicodeScalars
        guard span.startByte >= 0,
              span.endByte <= scalars.count,
              let start = scalars.index(scalars.startIndex, offsetBy: span.startByte, limitedBy: scalars.endIndex),
              let end = scalars.index(scalars.startIndex, offsetBy: span.endByte, limitedBy: scalars.endIndex) else {
            return nil
        }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private func previewLineSuffix(_ line: String, maxColumns: Int, remainingMatches: Int?) -> String {
        guard let remainingMatches else {
            return "\(line.prefixColumns(maxColumns)) [... omitted end of long line]"
        }
        return "\(line.prefixColumns(maxColumns)) [... \(remainingMatches) more \(remainingMatches == 1 ? "match" : "matches")]"
    }

    private func previewMatchedLineSuffix(
        _ line: String,
        maxColumns: Int,
        remainingMatches: Int,
        spans: [MatchSpan],
        lineStartByte: Int,
        trimOffset: Int
    ) -> String {
        let prefix = line.prefixColumns(maxColumns)
        guard colors.isEnabled, !prefix.isEmpty else {
            return previewLineSuffix(line, maxColumns: maxColumns, remainingMatches: remainingMatches)
        }
        let prefixByteCount = prefix.utf8.count
        let clippedSpans = spans.compactMap { span -> MatchSpan? in
            let startByte = span.startByte - lineStartByte - trimOffset
            let endByte = span.endByte - lineStartByte - trimOffset
            let clippedStart = max(0, startByte)
            let clippedEnd = min(prefixByteCount, endByte)
            guard clippedEnd > clippedStart else {
                return nil
            }
            return MatchSpan(
                startColumn: span.startColumn,
                endColumn: span.endColumn,
                startByte: clippedStart,
                endByte: clippedEnd,
                text: span.text,
                replacement: span.replacement
            )
        }
        let coloredPrefix = colors.colorMatches(in: prefix, spans: clippedSpans)
        return "\(coloredPrefix) [... \(remainingMatches) more \(remainingMatches == 1 ? "match" : "matches")]"
    }

    private func replacementStartOffsets(for match: SearchMatch) -> [Int] {
        replacementStartOffsetsByIndex(for: match).sorted()
    }

    private func replacementStartOffsetsByIndex(for match: SearchMatch) -> [Int] {
        guard options.replacement != nil else {
            return match.spans.map(\.startByte)
        }
        var delta = 0
        var offsets = Array(repeating: 0, count: match.spans.count)
        let indexedSpans = match.spans.enumerated().sorted { lhs, rhs in
            if lhs.element.startByte == rhs.element.startByte {
                return lhs.offset < rhs.offset
            }
            return lhs.element.startByte < rhs.element.startByte
        }
        for (index, span) in indexedSpans {
            let replacementLength = (span.replacement ?? span.text).utf8.count
            offsets[index] = span.startByte + delta
            delta += replacementLength - (span.endByte - span.startByte)
        }
        return offsets
    }

    private func column(in line: String, byteOffset: Int) -> Int {
        var bytes = 0
        var column = 1
        for character in line {
            guard bytes < byteOffset else {
                break
            }
            bytes += String(character).utf8.count
            column += 1
        }
        return column
    }

    private func splitRenderedLines(_ text: String) -> [String] {
        let terminator = renderedLineTerminator()
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == terminator {
                lines.append(String(current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty || text.unicodeScalars.last != terminator {
            lines.append(String(current))
        }
        return lines
    }

    private func containsRenderedLineTerminator(_ text: String) -> Bool {
        text.unicodeScalars.contains(renderedLineTerminator())
    }

    private func firstRenderedLine(_ text: String) -> String {
        splitRenderedLines(text).first ?? ""
    }

    private func lineOffset(in text: String, beforeByteOffset byteOffset: Int) -> Int {
        var bytes = 0
        var lines = 0
        let terminator = renderedLineTerminator()
        for scalar in text.unicodeScalars {
            guard bytes < byteOffset else {
                break
            }
            bytes += String(scalar).utf8.count
            if scalar == terminator {
                lines += 1
            }
        }
        return lines
    }

    private func renderedLineTerminator() -> UnicodeScalar {
        options.nullData ? "\0" : "\n"
    }

    private func renderedLineTerminatorByteCount() -> Int {
        String(renderedLineTerminator()).utf8.count
    }

    private func indexRange(startColumn: Int, endColumn: Int, in line: String) -> Range<String.Index>? {
        let lowerOffset = startColumn - 1
        let upperOffset = endColumn - 1
        guard lowerOffset >= 0, upperOffset >= lowerOffset, upperOffset <= line.count else {
            return nil
        }
        return line.index(line.startIndex, offsetBy: lowerOffset)..<line.index(line.startIndex, offsetBy: upperOffset)
    }

    private func indexRange(startByte: Int, endByte: Int, in line: String) -> Range<String.Index>? {
        guard startByte >= 0, endByte >= startByte,
              let lower = stringIndex(in: line, atByteOffset: startByte),
              let upper = stringIndex(in: line, atByteOffset: endByte) else {
            return nil
        }
        return lower..<upper
    }

    private func hasStringBoundary(atByteOffset byteOffset: Int, in line: String) -> Bool {
        stringIndex(in: line, atByteOffset: byteOffset) != nil
    }

    private func stringIndex(in line: String, atByteOffset byteOffset: Int) -> String.Index? {
        guard byteOffset >= 0 else {
            return nil
        }
        if byteOffset == 0 {
            return line.startIndex
        }
        var bytes = 0
        for index in line.indices {
            if bytes == byteOffset {
                return index
            }
            bytes += String(line[index]).utf8.count
        }
        return bytes == byteOffset ? line.endIndex : nil
    }

    private func showPath(for results: SearchResults) -> Bool {
        if let withFilename = options.withFilename {
            return withFilename
        }
        if options.useStdin {
            return options.rootPathArguments.contains { $0 != "-" }
        }
        return results.files.count > 1 || options.effectiveRoots.count > 1 || options.effectiveRoots.contains { isSearchDirectory($0) }
    }

    private func isSearchDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        if values.isDirectory == true {
            return true
        }
        guard values.isSymbolicLink == true else {
            return false
        }
        return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func displayPath(for url: URL) -> String {
        pathFormatter.displayPath(for: url)
    }

    private func statsLines(for results: SearchResults, bytesPrinted: Int) -> [String] {
        [
            "",
            "\(results.summary.totalMatches) matches",
            "\(results.summary.matchedLines) matched lines",
            "\(results.summary.filesWithMatches) files contained matches",
            "\(results.summary.filesSearched) files searched",
            "\(bytesPrinted) bytes printed",
            "\(results.files.reduce(0) { $0 + $1.bytesSearched }) bytes searched",
            "0.000000 seconds spent searching",
            "0.000000 seconds total",
        ]
    }

    private func bytesPrinted(_ lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            total + line.rawOutputByteCount + 1
        }
    }
}

private extension String {
    static let rawByteMarkerScalar = UnicodeScalar(0xFDD0)!
    static let rawByteMarker = String(rawByteMarkerScalar)

    static func rawByteMarked(_ bytes: [UInt8]) -> String {
        rawByteMarker + String(String.UnicodeScalarView(bytes.map { UnicodeScalar(Int($0))! }))
    }

    var rawBytePayload: String? {
        hasPrefix(Self.rawByteMarker) ? String(dropFirst()) : nil
    }

    var rawOutputByteCount: Int {
        rawBytePayload?.unicodeScalars.count ?? utf8.count
    }

    func rawByteData() -> Data {
        var data = Data()
        for scalar in unicodeScalars {
            if scalar.value <= UInt8.max {
                data.append(UInt8(scalar.value))
            } else {
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        return data
    }

    func trimmingASCIIWhitespacePrefix() -> String {
        let firstNonWhitespace = firstIndex { character in
            character != " " && character != "\t" && character != "\r" && character != "\n"
        }
        guard let firstNonWhitespace else {
            return ""
        }
        return String(self[firstNonWhitespace...])
    }

    func prefixColumns(_ columnCount: Int) -> String {
        guard columnCount > 0 else {
            return ""
        }
        var output = ""
        var columns = 0
        for character in self {
            guard columns < columnCount else {
                break
            }
            output.append(character)
            columns += 1
        }
        return output
    }

    func trimmingTrailingSlashes() -> String {
        var output = self
        while output.count > 1, output.last == "/" {
            output.removeLast()
        }
        return output
    }
}

private struct OutputField {
    let text: String
    let colorTarget: ColorTarget?

    init(_ text: String, colorTarget: ColorTarget?) {
        self.text = text
        self.colorTarget = colorTarget
    }
}

private enum OmittedLineKind {
    case matching
    case context

    var message: String {
        switch self {
        case .matching:
            return "[Omitted long matching line]"
        case .context:
            return "[Omitted long context line]"
        }
    }
}

private struct ANSIColorPalette {
    struct Style {
        var foreground: String?
        var background: String?
        var bold = false
        var underline = false
        var italic = false

        var isEmpty: Bool {
            foreground == nil && background == nil && !bold && !underline && !italic
        }

        var escape: String? {
            var escapes: [String] = []
            if bold {
                escapes.append("\u{1B}[1m")
            }
            if underline {
                escapes.append("\u{1B}[4m")
            }
            if italic {
                escapes.append("\u{1B}[3m")
            }
            if let foreground, let code = ANSIColorPalette.colorCode(foreground, foreground: true) {
                escapes.append("\u{1B}[\(code)m")
            }
            if let background, let code = ANSIColorPalette.colorCode(background, foreground: false) {
                escapes.append("\u{1B}[\(code)m")
            }
            guard !escapes.isEmpty else {
                return nil
            }
            return escapes.joined()
        }
    }

    static let reset = "\u{1B}[0m"
    private static let foregroundCodes = [
        "black": "30",
        "red": "31",
        "green": "32",
        "yellow": "33",
        "blue": "34",
        "magenta": "35",
        "cyan": "36",
        "white": "37",
    ]
    private static let backgroundCodes = [
        "black": "40",
        "red": "41",
        "green": "42",
        "yellow": "43",
        "blue": "44",
        "magenta": "45",
        "cyan": "46",
        "white": "47",
    ]

    let isEnabled: Bool
    private var styles: [ColorTarget: Style]

    init(options: RipgrepOptions) {
        self.isEnabled = options.colorMode == .always || options.colorMode == .ansi
        var styles: [ColorTarget: Style] = [
            .path: Style(foreground: "magenta"),
            .line: Style(foreground: "green"),
            .column: Style(),
            .match: Style(foreground: "red", bold: true),
            .highlight: Style(),
        ]
        for change in options.colorChanges {
            var style = styles[change.target] ?? Style()
            switch change.attribute {
            case .none:
                style = Style()
            case .foreground(let color):
                style.foreground = color
            case .background(let color):
                style.background = color
            case .style(let name):
                Self.applyStyle(name, to: &style)
            }
            styles[change.target] = style
        }
        self.styles = styles
    }

    func apply(_ target: ColorTarget, to text: String) -> String {
        guard isEnabled, !text.isEmpty, let style = styles[target] else {
            return text
        }
        guard let escape = style.escape else {
            return shouldResetPlainText(target) ? "\(Self.reset)\(text)\(Self.reset)" : text
        }
        return "\(Self.reset)\(escape)\(text)\(Self.reset)"
    }

    func colorMatches(in line: String, spans: [MatchSpan]) -> String {
        guard isEnabled else {
            return line
        }
        let orderedRanges = mergedByteRanges(for: spans)
        var output = ""
        var cursor = line.startIndex
        for byteRange in orderedRanges {
            guard let range = indexRange(startByte: byteRange.lowerBound, endByte: byteRange.upperBound, in: line),
                  range.lowerBound >= cursor else {
                continue
            }
            output.append(contentsOf: line[cursor..<range.lowerBound])
            output.append(apply(.match, to: String(line[range])))
            cursor = range.upperBound
        }
        output.append(contentsOf: line[cursor..<line.endIndex])
        return output
    }

    private func mergedByteRanges(for spans: [MatchSpan]) -> [Range<Int>] {
        let ordered = spans
            .filter { $0.endByte > $0.startByte }
            .map { $0.startByte..<$0.endByte }
            .sorted {
                if $0.lowerBound == $1.lowerBound {
                    return $0.upperBound < $1.upperBound
                }
                return $0.lowerBound < $1.lowerBound
            }

        var merged: [Range<Int>] = []
        for range in ordered {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func shouldResetPlainText(_ target: ColorTarget) -> Bool {
        switch target {
        case .path, .line, .column:
            return true
        case .match, .highlight:
            return false
        }
    }

    private func indexRange(startByte: Int, endByte: Int, in line: String) -> Range<String.Index>? {
        guard startByte >= 0, endByte >= startByte,
              let lower = stringIndex(in: line, atByteOffset: startByte),
              let upper = stringIndex(in: line, atByteOffset: endByte) else {
            return nil
        }
        return lower..<upper
    }

    private func stringIndex(in line: String, atByteOffset byteOffset: Int) -> String.Index? {
        guard byteOffset >= 0 else {
            return nil
        }
        if byteOffset == 0 {
            return line.startIndex
        }
        var bytes = 0
        for index in line.indices {
            if bytes == byteOffset {
                return index
            }
            bytes += String(line[index]).utf8.count
        }
        return bytes == byteOffset ? line.endIndex : nil
    }

    private static func applyStyle(_ name: String, to style: inout Style) {
        switch name {
        case "bold", "intense":
            style.bold = true
        case "nobold", "nointense":
            style.bold = false
        case "underline":
            style.underline = true
        case "nounderline":
            style.underline = false
        case "italic":
            style.italic = true
        case "noitalic":
            style.italic = false
        default:
            break
        }
    }

    private static func colorCode(_ color: String, foreground: Bool) -> String? {
        if foreground, let code = foregroundCodes[color] {
            return code
        }
        if !foreground, let code = backgroundCodes[color] {
            return code
        }
        if let byte = parseColorByte(color) {
            return "\(foreground ? 38 : 48);5;\(byte)"
        }
        let components = color.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              let red = parseColorByte(components[0]),
              let green = parseColorByte(components[1]),
              let blue = parseColorByte(components[2]) else {
            return nil
        }
        return "\(foreground ? 38 : 48);2;\(red);\(green);\(blue)"
    }

    private static func parseColorByte(_ raw: String) -> UInt8? {
        let value: UInt64?
        if raw.hasPrefix("0x") {
            value = UInt64(raw.dropFirst(2), radix: 16)
        } else {
            value = UInt64(raw)
        }
        guard let value, value <= UInt8.max else {
            return nil
        }
        return UInt8(value)
    }
}
