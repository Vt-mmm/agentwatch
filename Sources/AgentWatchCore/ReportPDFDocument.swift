import Foundation
import CoreGraphics
import CoreText

/// A4, selectable Unicode text, predictable pagination and a compact dashboard.
enum ReportPDFDocument {
    static func render(_ report: DailyReportDraft, revision: Int?) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw ReportValidationError.invalid("Không tạo được PDF.") }
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw ReportValidationError.invalid("Không tạo được PDF.") }
        let navy = CGColor(red: 0.09, green: 0.16, blue: 0.26, alpha: 1)
        let teal = CGColor(red: 0.04, green: 0.43, blue: 0.46, alpha: 1)
        let muted = CGColor(red: 0.36, green: 0.41, blue: 0.47, alpha: 1)
        let pale = CGColor(red: 0.94, green: 0.96, blue: 0.97, alpha: 1)
        let compact = report.narrativeProvenance == "automatic-local-v1"
        let margin: CGFloat = 44, width: CGFloat = 507
        var number = 0, y: CGFloat = 0
        let day = DailyReportRenderer.dateLabel(report.period.start, zone: report.period.timeZone)

        func attributed(_ text: String, size: CGFloat, bold: Bool = false, color: CGColor? = nil) -> NSAttributedString {
            var spacing: CGFloat = 3
            let style = withUnsafePointer(to: &spacing) { pointer in
                var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
            return NSAttributedString(string: ShareText.clean(text), attributes: [
                .init(kCTFontAttributeName as String): CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil),
                .init(kCTForegroundColorAttributeName as String): color ?? navy,
                .init(kCTParagraphStyleAttributeName as String): style])
        }
        func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, color: CGColor? = nil) {
            context.saveGState(); defer { context.restoreGState() }
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed(text, size: size, bold: bold, color: color)), context)
        }
        func finish() {
            context.setFillColor(pale); context.fill(CGRect(x: margin, y: 43, width: width, height: 1))
            label("AGENTWATCH  /  BÁO CÁO NỘI BỘ", x: margin, y: 27, size: 8, color: muted)
            label("\(day)   ·   Trang \(number)", x: 424, y: 27, size: 8, color: muted)
            context.endPDFPage()
        }
        func begin() {
            if number > 0 { finish() }
            context.beginPDFPage(nil); number += 1
            context.setFillColor(teal); context.fill(CGRect(x: 0, y: 834, width: 595, height: 8))
            label("AGENTWATCH", x: margin, y: 807, size: 10, bold: true, color: teal)
            label("DAILY ACTIVITY  /  \(day)", x: 366, y: 807, size: 8, color: muted)
            y = 779
        }
        func measuredHeight(_ text: String, size: CGFloat, bold: Bool = false) -> CGFloat {
            CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(attributed(text, size: size, bold: bold)), CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
        }
        func paragraph(_ text: String, size: CGFloat = 10.5, bold: Bool = false, color: CGColor? = nil) {
            let value = attributed(text, size: size, bold: bold, color: color)
            let setter = CTFramesetterCreateWithAttributedString(value)
            var offset = 0
            while offset < value.length {
                if y < 92 { begin() }
                let remaining = CFRange(location: offset, length: value.length - offset)
                let available = y - 64
                let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, remaining, nil, CGSize(width: width, height: available), nil)
                let height = min(available, ceil(measured.height) + 5)
                let path = CGPath(rect: CGRect(x: margin, y: y - height, width: width, height: height), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, remaining, path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { begin(); continue }
                context.saveGState(); context.textMatrix = .identity
                CTFrameDraw(frame, context); context.restoreGState()
                offset += visible.length; y -= height + (compact ? 3 : 5)
                if offset < value.length {
                    begin(); label("Tiếp theo", x: margin, y: y, size: 8, color: muted); y -= 15
                }
            }
        }
        func metrics() {
            let prompts = (report.dailyActivity?.prompts ?? []).filter { ($0.origin ?? .employee) == .employee }
            let paths: [String] = prompts.flatMap { prompt in
                (prompt.fileActivities ?? []).map { $0.path.hasPrefix("/") ? $0.path : prompt.observedProject + "/" + $0.path }
            }
            let values: [(String, String)] = [("PROMPT ĐÃ GỬI", String(prompts.count)),
                ("FILE GHI NHẬN", String(Set(paths).count)),
                ("ỨNG DỤNG", String(report.desktopActivity?.apps.count ?? 0)),
                ("PHÚT QUAN SÁT", String(Int((report.desktopActivity?.observedSeconds ?? 0) / 60)))]
            for (index, value) in values.enumerated() {
                let x = margin + CGFloat(index) * 129
                context.setFillColor(pale); context.fill(CGRect(x: x, y: y - 68, width: 120, height: 63))
                label(value.0, x: x + 10, y: y - 23, size: 7.5, bold: true, color: muted)
                label(value.1, x: x + 10, y: y - 53, size: 23, bold: true, color: teal)
            }
            y -= 86
        }
        begin()
        for (index, block) in DailyReportRenderer.blocks(report, revision: revision).enumerated() {
            let isHero = index == 0
            let titleSize: CGFloat = isHero ? (compact ? 20 : 23) : (compact ? 11 : 12)
            let headingHeight = block.title.map { measuredHeight($0, size: titleSize, bold: true) } ?? 0
            let blockHeight = headingHeight + measuredHeight(block.text, size: block.kind == .appUsage ? 9 : 10.5) + 45
            if y < min(250, headingHeight + (compact ? 60 : 125)) || (blockHeight < 600 && y - 64 < blockHeight) { begin() }
            if block.kind == .section {
                context.setFillColor(pale); context.fill(CGRect(x: margin - 9, y: y - headingHeight - 13, width: width + 18, height: headingHeight + 22))
                context.setFillColor(teal); context.fill(CGRect(x: margin - 9, y: y - headingHeight - 13, width: 3, height: headingHeight + 22))
            } else if block.kind == .prompt {
                context.setFillColor(teal); context.fill(CGRect(x: margin, y: y + 6, width: width, height: 1))
                y -= 6
            }
            if let title = block.title { paragraph(title, size: titleSize, bold: true, color: block.kind == .prompt ? teal : navy) }
            if block.kind == .section { y -= 10 }
            if block.kind == .appUsage {
                context.setFillColor(pale); context.fill(CGRect(x: margin, y: y - 3, width: width, height: 5))
                context.setFillColor(teal); context.fill(CGRect(x: margin, y: y - 3, width: width * max(0, min(1, block.fraction)), height: 5)); y -= 14
            }
            paragraph(block.text, size: block.kind == .appUsage ? 9 : 10.5, color: isHero ? muted : navy)
            y -= compact ? 6 : (block.kind == .prompt ? 18 : 13)
            if isHero && report.narrativeProvenance == "automatic-local-v1" { metrics() }
        }
        finish(); context.closePDF()
        return data as Data
    }
}
