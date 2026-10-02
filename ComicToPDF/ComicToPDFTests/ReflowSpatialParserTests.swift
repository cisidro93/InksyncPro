import XCTest
@testable import InksyncPro

final class ReflowSpatialParserTests: XCTestCase {

    func testLigatureDecomposition() {
        let input = "The \u{FB01}rst \u{FB02}ight of the \u{FB00}ice was \u{FB03}cient."
        let sanitized = PDFSpatialParser.sanitizeExtractedText(input)
        XCTAssertEqual(sanitized, "The first flight of the office was efficient.")
    }

    func testSoftHyphenAndZeroWidthStripping() {
        // Words fragmented by soft hyphens (\u{00AD}) and zero-width spaces (\u{200B}, \u{FEFF})
        let input = "in\u{00AD}tel\u{200B}li\u{FEFF}gence"
        let sanitized = PDFSpatialParser.sanitizeExtractedText(input)
        XCTAssertEqual(sanitized, "intelligence")
    }

    func testExoticSpaceNormalization() {
        // Non-breaking space (\u{00A0}) and en-space (\u{2002})
        let input = "Chapter\u{00A0}1:\u{2002}Introduction"
        let sanitized = PDFSpatialParser.sanitizeExtractedText(input)
        XCTAssertEqual(sanitized, "Chapter 1: Introduction")
    }

    func testCMapThinSpaceExclamationRepair() {
        // In some academic PDFs, thin space is encoded as ASCII 33 ('!')
        let input = "our!personal computer and!DNA analysis"
        let sanitized = PDFSpatialParser.sanitizeExtractedText(input)
        XCTAssertEqual(sanitized, "our personal computer and DNA analysis")
    }
}
