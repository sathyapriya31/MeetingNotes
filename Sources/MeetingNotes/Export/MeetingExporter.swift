import AppKit
import UniformTypeIdentifiers

/// Exports a meeting's summary, notes, action items and transcript as a PDF or
/// Word document. Both formats are rendered from the same attributed string, so
/// they always contain the same content.
enum MeetingExporter {
    enum Format: CaseIterable {
        case pdf, docx

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .docx: return "docx"
            }
        }

        var contentType: UTType {
            switch self {
            case .pdf: return .pdf
            case .docx: return UTType(filenameExtension: "docx") ?? .data
            }
        }

        var menuTitle: String {
            switch self {
            case .pdf: return "Export as PDF…"
            case .docx: return "Export as Word (.docx)…"
            }
        }
    }

    // MARK: - Save panel

    /// Asks where to save, then writes the file. Returns the saved URL, or nil
    /// when the user cancelled or writing failed (an alert is shown on failure).
    @MainActor
    @discardableResult
    static func export(_ meeting: Meeting, as format: Format) -> URL? {
        let panel = NSSavePanel()
        panel.title = format.menuTitle.replacingOccurrences(of: "…", with: "")
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName(for: meeting) + "." + format.fileExtension

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try data(for: meeting, as: format).write(to: url, options: .atomic)
            return url
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't export the meeting"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
    }

    static func data(for meeting: Meeting, as format: Format) throws -> Data {
        let document = attributedDocument(for: meeting)
        switch format {
        case .pdf:
            return pdfData(from: document)
        case .docx:
            return try document.data(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.officeOpenXML,
                    .title: meeting.displayTitle
                ]
            )
        }
    }

    /// "2026-10-30 Weekly Sync" — title with characters Finder dislikes removed.
    static func suggestedFileName(for meeting: Meeting) -> String {
        let day = meeting.date.formatted(.iso8601.year().month().day())
        let title = meeting.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String("\(day) \(title)".prefix(80))
    }

    // MARK: - Document content

    // Named fonts (not the system UI font) so Word on other machines can map them.
    private static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let name = bold ? "Helvetica-Bold" : "Helvetica"
        return NSFont(name: name, size: size) ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    private static let textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
    private static let mutedColor = NSColor(calibratedWhite: 0.42, alpha: 1)
    private static let accentColor = NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.96, alpha: 1)

    static func attributedDocument(for meeting: Meeting) -> NSAttributedString {
        let doc = NSMutableAttributedString()

        func paragraph(spacingBefore: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = after
            style.lineHeightMultiple = 1.15
            if indent > 0 {
                style.headIndent = indent
                style.firstLineHeadIndent = 0
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                style.defaultTabInterval = indent
            }
            return style
        }

        func append(_ text: String, font: NSFont, color: NSColor = textColor, style: NSParagraphStyle) {
            doc.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style
            ]))
        }

        func heading(_ text: String) {
            append(text, font: font(14, bold: true), color: accentColor, style: paragraph(spacingBefore: 14, after: 6))
        }

        func bullets(_ items: [String], marker: String = "•") {
            for item in items {
                append("\(marker)\t\(item)", font: font(11), style: paragraph(after: 4, indent: 18))
            }
        }

        // Title block
        append(meeting.displayTitle, font: font(22, bold: true), style: paragraph(after: 4))
        var meta = meeting.date.formatted(date: .long, time: .shortened) + "  ·  \(meeting.durationMinutes) min"
        if !meeting.uniqueSpeakers.isEmpty {
            meta += "  ·  \(meeting.uniqueSpeakers.count) speaker" + (meeting.uniqueSpeakers.count == 1 ? "" : "s")
        }
        append(meta, font: font(10.5), color: mutedColor, style: paragraph(after: 2))
        if let attendees = meeting.attendees, !attendees.isEmpty {
            append("With " + attendees.joined(separator: ", "), font: font(10.5), color: mutedColor, style: paragraph(after: 2))
        }

        let notes = meeting.notes

        if let summary = notes?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            heading("Executive Summary")
            append(summary, font: font(11), style: paragraph())
        }

        if let enhanced = notes?.enhancedNotes, !enhanced.isEmpty {
            heading("Notes")
            bullets(enhanced)
        }

        if let mine = meeting.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !mine.isEmpty {
            heading("My Notes")
            for line in mine.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                append(line, font: font(11), style: paragraph(after: 4))
            }
        }

        if let decisions = notes?.keyDecisions, !decisions.isEmpty {
            heading("Key Decisions")
            bullets(decisions)
        }

        if let items = notes?.actionItems, !items.isEmpty {
            heading("Action Items & Next Steps")
            for item in items {
                var line = "\(item.isCompleted ? "☑" : "☐")\t\(item.task)"
                var details: [String] = []
                if !item.owner.isEmpty { details.append(item.owner) }
                if let due = item.due, !due.isEmpty { details.append("due \(due)") }
                if !details.isEmpty { line += " — " + details.joined(separator: ", ") }
                append(line, font: font(11), style: paragraph(after: 4, indent: 18))
            }
        }

        if !meeting.transcript.isEmpty {
            heading("Transcript")
            for segment in meeting.transcript {
                let line = NSMutableAttributedString(string: timestamp(segment.start) + "  ", attributes: [
                    .font: font(9.5), .foregroundColor: mutedColor
                ])
                line.append(NSAttributedString(string: segment.speaker + ": ", attributes: [
                    .font: font(10.5, bold: true), .foregroundColor: textColor
                ]))
                line.append(NSAttributedString(string: segment.text + "\n", attributes: [
                    .font: font(10.5), .foregroundColor: textColor
                ]))
                line.addAttribute(.paragraphStyle, value: paragraph(after: 3), range: NSRange(location: 0, length: line.length))
                doc.append(line)
            }
        }

        if notes == nil && meeting.transcript.isEmpty {
            append("No summary or transcript was recorded for this meeting.", font: font(11), color: mutedColor, style: paragraph(spacingBefore: 14))
        }

        return doc
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - PDF

    /// Lays the text out over US Letter pages with page numbers in the footer.
    static func pdfData(from text: NSAttributedString) -> Data {
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 54
        let contentSize = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
        } while NSMaxRange(layout.glyphRange(for: containers[containers.count - 1])) < layout.numberOfGlyphs
            && containers.count < 1_000

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        let footerAttributes: [NSAttributedString.Key: Any] = [.font: font(9), .foregroundColor: mutedColor]

        for (index, container) in containers.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            // Flip to top-left origin, which is what NSLayoutManager draws in.
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

            let glyphs = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)

            let footer = "Page \(index + 1) of \(containers.count)" as NSString
            let footerSize = footer.size(withAttributes: footerAttributes)
            footer.draw(
                at: CGPoint(x: (pageSize.width - footerSize.width) / 2, y: pageSize.height - margin / 2 - footerSize.height),
                withAttributes: footerAttributes
            )

            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
