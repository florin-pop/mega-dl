//
//  ConfigParserTests.swift
//  MegaKitTests
//
//  Created by Florin Pop on 08.12.21.
//

import XCTest
@testable import MegaKit

class ConfigParserTests: XCTestCase {
    func testParseEmptyConfig() throws {
        XCTAssertEqual(parseConfig(""), Config())
    }
    
    func testParseConfigWithTwoSections() throws {
        let configFileContents = """
        [Section 1]
        Param11 = Value11
        Param12 = Value12
        
        [Section 2]
        Param21 = Value21
        Param22 = Value22
        """
        
        let expectedConfig = [
            "Section 1": ["Param11": "Value11", "Param12": "Value12"],
            "Section 2": ["Param21": "Value21", "Param22": "Value22"]
        ]
        
        XCTAssertEqual(parseConfig(configFileContents), expectedConfig)
    }
}
