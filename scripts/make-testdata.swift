// Generates the two test PDFs in testdata/: a flat worksheet and a real form.
// Run: swift scripts/make-testdata.swift testdata
import AppKit
import PDFKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "testdata")

func pdf(_ draw: (CGContext) -> Void) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let c = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    c.beginPDFPage(nil)
    let g = NSGraphicsContext(cgContext: c, flipped: false)
    NSGraphicsContext.current = g
    draw(c)
    c.endPDFPage(); c.closePDF()
    return data as Data
}
// y is given from the top of the page
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, bold: Bool = false) {
    let f = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont(name: "Helvetica", size: size)!
    (s as NSString).draw(at: CGPoint(x: x, y: 842 - y - size), withAttributes: [.font: f])
}
func line(_ c: CGContext, _ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) {
    c.setLineWidth(0.7); c.move(to: CGPoint(x: x1, y: 842 - y)); c.addLine(to: CGPoint(x: x2, y: 842 - y)); c.strokePath()
}
func rect(_ c: CGContext, _ r: CGRect) {
    c.setLineWidth(0.8); c.stroke(CGRect(x: r.minX, y: 842 - r.maxY, width: r.width, height: r.height))
}

let sheet = pdf { c in
    text("Arbeitsblatt Mathematik", 60, 60, size: 20, bold: true)
    text("Name: ____________________", 60, 100)
    text("Datum: ______________", 360, 100)
    text("1. Berechne.", 60, 150, bold: true)
    text("a) 12 × 7 = ________", 80, 175)
    text("b) 144 ÷ 12 = ________", 240, 175)
    text("c) 3² + 4² = ________", 410, 175)
    text("2. Löse die Gleichung 3x + 5 = 20 nach x auf. Schreibe den Rechenweg auf.", 60, 225, bold: true)
    line(c, 80, 535, 265); line(c, 80, 535, 290); line(c, 80, 535, 315)
    text("3. Welche Zahl ist eine Primzahl? Kreuze an.", 60, 360, bold: true)
    for (i, n) in ["21", "23", "27", "33"].enumerated() {
        let x = 80 + CGFloat(i) * 110
        rect(c, CGRect(x: x, y: 385, width: 12, height: 12)); text(n, x + 20, 385)
    }
    text("4. Fülle die Tabelle aus.", 60, 440, bold: true)
    for r in 0..<2 { for col in 0..<5 { rect(c, CGRect(x: 80 + CGFloat(col) * 80, y: 465 + CGFloat(r) * 28, width: 80, height: 28)) } }
    for (i, h) in ["x", "1", "2", "3", "4"].enumerated() { text(h, 110 + CGFloat(i) * 80, 472) }
    text("x²", 110, 500)
    text("5. Erkläre in einem Satz, was eine Primzahl ist.", 60, 565, bold: true)
    line(c, 80, 535, 605); line(c, 80, 535, 632)
    text("6. Ein Rechteck ist 8 cm lang und 5 cm breit.", 60, 680, bold: true)
    text("Umfang: ................ cm", 80, 705)
    text("Fläche: ................ cm²", 300, 705)
}
try! sheet.write(to: out.appendingPathComponent("worksheet.pdf"))

let base = pdf { c in
    text("Anmeldung Sporttag", 60, 60, size: 20, bold: true)
    text("Vorname", 60, 120); text("Nachname", 320, 120)
    text("Klasse", 60, 180); text("Geburtsjahr", 320, 180)
    text("Ich kann schwimmen", 85, 243)
    text("Ich brauche ein Mittagessen", 85, 273)
    text("Wie viele Minuten hat eine Doppellektion (2 × 45 min)?", 60, 330)
    text("Hauptstadt der Schweiz", 60, 390)
}
let doc = PDFDocument(data: base)!
let page = doc.page(at: 0)!
func field(_ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
    let a = PDFAnnotation(bounds: CGRect(x: x, y: 842 - y - 22, width: w, height: 22), forType: .widget, withProperties: nil)
    a.widgetFieldType = .text; a.fieldName = name; a.font = NSFont(name: "Helvetica", size: 12)
    a.backgroundColor = NSColor(white: 0.94, alpha: 1)
    page.addAnnotation(a)
}
func checkbox(_ name: String, _ x: CGFloat, _ y: CGFloat) {
    let a = PDFAnnotation(bounds: CGRect(x: x, y: 842 - y - 14, width: 14, height: 14), forType: .widget, withProperties: nil)
    a.widgetFieldType = .button; a.widgetControlType = .checkBoxControl; a.fieldName = name
    page.addAnnotation(a)
}
field("vorname", 60, 136, 220); field("nachname", 320, 136, 215)
field("klasse", 60, 196, 220); field("geburtsjahr", 320, 196, 215)
checkbox("schwimmen", 60, 242); checkbox("mittagessen", 60, 272)
field("minuten", 60, 346, 120); field("hauptstadt", 60, 406, 220)
doc.write(to: out.appendingPathComponent("form.pdf"))
print("ok")
