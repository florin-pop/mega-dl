//
//  MegaLinkTests.swift
//  MegaKitTests
//
//  Created by Florin Pop on 10.12.21.
//

import XCTest
@testable import MegaKit

class MegaLinkTests: XCTestCase {
    func testParseEmptyUrl() throws {
        var initError: Error? = nil
        do {
            _ = try MegaLink(url: "")
        } catch let error {
            initError = error
        }
        XCTAssertEqual(initError as! MegaError, .badURL)
    }
    
    func testParseFileUrl() throws {
        let link = try! MegaLink(url: "https://mega.nz/file/Q64TCAoZ#1h9D4DUWbbiguPuXiIAk1H_fBUmCa442lUwdjE2zvoo")
        XCTAssertEqual(link.type, .file)
        XCTAssertEqual(link.key, "1h9D4DUWbbiguPuXiIAk1H_fBUmCa442lUwdjE2zvoo")
        XCTAssertEqual(link.id, "Q64TCAoZ")
    }
    
    func testParseFolderUrl() throws {
        let link = try! MegaLink(url: "https://mega.nz/folder/tq4iDSYK#QjKVw7PjbdPlggM1vkDtIg")
        XCTAssertEqual(link.type, .folder)
        XCTAssertEqual(link.key, "QjKVw7PjbdPlggM1vkDtIg")
        XCTAssertEqual(link.id, "tq4iDSYK")
    }
}
