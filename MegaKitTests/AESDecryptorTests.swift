//
//  AESDecryptorTests.swift
//  MegaKitTests
//
//  Created by Florin Pop on 08.12.21.
//

import XCTest
@testable import MegaKit

extension String: Error {}

class FileHandleMock: SequentialIOHandle {
    var readURL: URL!
    var writeURL: URL!
    static var dataWritten: [URL: Data] = [:]
    static var dataToRead: [URL: Data] = [:]
    
    required init(forReadingFrom url: URL) throws {
        self.readURL = url
    }
    
    required init(forWritingTo url: URL) throws {
        self.writeURL = url
    }
    
    func readData(ofLength: Int) -> Data {
        let dataToRead = Self.dataToRead[self.readURL]!
        let length = min(dataToRead.count, ofLength)
        if length == 0 {
            return Data()
        }
        let data = dataToRead[..<length]
        Self.dataToRead[self.readURL]! = Data(dataToRead[length...])
        return data
    }
    
    func write(_ data: Data) {
        var writtenData = Self.dataWritten[self.writeURL] ?? Data()
        writtenData.append(data)
        Self.dataWritten[self.writeURL] = writtenData
    }
}

class AESDecryptorDelegateMock: AESDecryptorDelegate {
    var decryptorDidStartCallback: ((URL) -> Void)?
    var decryptorDidFinishCallback: ((URL, Error?) -> Void)?
    var decryptorDidDecryptCallback: ((Int64) -> Void)?
    
    func decryptorDidStart(decryptedFileUrl: URL) {
        decryptorDidStartCallback?(decryptedFileUrl)
    }
    
    func decryptorDidFinish(decryptedFileUrl: URL, error: Error?) {
        decryptorDidFinishCallback?(decryptedFileUrl, error)
    }
    
    func decryptorDidDecrypt(bytesDecrypted: Int64) {
        decryptorDidDecryptCallback?(bytesDecrypted)
    }
}

class FailingInitForReadingFileHandleMock: FileHandleMock {
    required init(forReadingFrom url: URL) throws {
        throw "Cannot read from url"
    }
    
    required init(forWritingTo url: URL) throws {
        try super.init(forWritingTo: url)
    }
}

class FailingInitForWritingFileHandleMock: FileHandleMock {
    required init(forReadingFrom url: URL) throws {
        try super.init(forReadingFrom: url)
    }
    
    required init(forWritingTo url: URL) throws {
        throw "Cannot write to url"
    }
}

class AESDecryptorTests: XCTestCase {
    
    func testDecryptFailsToRead() throws {
        let encryptedTxtUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptedTxtUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptor = AESDecryptor<FailingInitForReadingFileHandleMock>()
        let decryptorDelegate = AESDecryptorDelegateMock()
        
        let decryptorDidStartCallExpectation = XCTestExpectation(description: "Decryptor did start")
        decryptorDelegate.decryptorDidStartCallback = { decryptedFileUrl in
            XCTAssertEqual(decryptedFileUrl, decryptedTxtUrl)
            decryptorDidStartCallExpectation.fulfill()
        }
        
        let decryptorDidFinishCallExpectation = XCTestExpectation(description: "Decryptor did finish")
        decryptorDelegate.decryptorDidFinishCallback = { decryptedFileUrl, error in
            XCTAssertEqual(error as! DecryptorError, .readEncryptedFile)
            XCTAssertEqual(decryptedFileUrl, decryptedTxtUrl)
            decryptorDidFinishCallExpectation.fulfill()
        }
        
        decryptor.delegate = decryptorDelegate
        FileHandleMock.dataToRead[encryptedTxtUrl] = encryptedTxt.base64Decoded()!
        
        let key = "1h9D4DUWbbiguPuXiIAk1H/fBUmCa442lUwdjE2zvoo=".base64Decoded()!
        let decryptExpectation = XCTestExpectation(description: "Decrypt")
        
        decryptor.decrypt(encryptedFileUrl: encryptedTxtUrl, decryptedFileUrl: decryptedTxtUrl, key: key) {
            decryptExpectation.fulfill()
        }
        
        wait(for: [decryptExpectation, decryptorDidStartCallExpectation, decryptorDidFinishCallExpectation], timeout: 2)
    }
    
    func testDecryptFailsToWrite() throws {
        let encryptedTxtUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptedTxtUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptor = AESDecryptor<FailingInitForWritingFileHandleMock>()
        let decryptorDelegate = AESDecryptorDelegateMock()
        
        let decryptorDidStartCallExpectation = XCTestExpectation(description: "Decryptor did start")
        decryptorDelegate.decryptorDidStartCallback = { decryptedFileUrl in
            XCTAssertEqual(decryptedFileUrl, decryptedTxtUrl)
            decryptorDidStartCallExpectation.fulfill()
        }
        
        let decryptorDidFinishCallExpectation = XCTestExpectation(description: "Decryptor did finish")
        decryptorDelegate.decryptorDidFinishCallback = { decryptedFileUrl, error in
            XCTAssertEqual(error as! DecryptorError, .writeDecryptedFile)
            XCTAssertEqual(decryptedFileUrl, decryptedTxtUrl)
            decryptorDidFinishCallExpectation.fulfill()
        }
        
        decryptor.delegate = decryptorDelegate
        FileHandleMock.dataToRead[encryptedTxtUrl] = encryptedTxt.base64Decoded()!
        
        let key = "1h9D4DUWbbiguPuXiIAk1H/fBUmCa442lUwdjE2zvoo=".base64Decoded()!
        let decryptExpectation = XCTestExpectation(description: "Decrypt")
        
        decryptor.decrypt(encryptedFileUrl: encryptedTxtUrl, decryptedFileUrl: decryptedTxtUrl, key: key) {
            decryptExpectation.fulfill()
        }
        
        wait(for: [decryptExpectation, decryptorDidStartCallExpectation, decryptorDidFinishCallExpectation], timeout: 2)
    }
    
    func testDecryptTxt() throws {
        let encryptedTxtUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptedTxtUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptor = AESDecryptor<FileHandleMock>()
        let decryptorDelegate = AESDecryptorDelegateMock()
        
        let decryptorDidStartCallExpectation = XCTestExpectation(description: "Decryptor did start")
        decryptorDelegate.decryptorDidStartCallback = { decryptedFileUrl in
            XCTAssertEqual(decryptedFileUrl, decryptedTxtUrl)
            decryptorDidStartCallExpectation.fulfill()
        }
        
        let decryptorDidFinishCallExpectation = XCTestExpectation(description: "Decryptor did finish")
        decryptorDelegate.decryptorDidFinishCallback = { decryptedFileUrl, error in
            XCTAssertNil(error)
            XCTAssertEqual(decryptedFileUrl, decryptedTxtUrl)
            decryptorDidFinishCallExpectation.fulfill()
        }
        
        let decryptorDidDecryptCallExpectation = XCTestExpectation(description: "Decryptor did decrypt")
        decryptorDelegate.decryptorDidDecryptCallback = { bytesWritten in
            XCTAssertEqual(bytesWritten, 5)
            decryptorDidDecryptCallExpectation.fulfill()
        }
        
        decryptor.delegate = decryptorDelegate
        FileHandleMock.dataToRead[encryptedTxtUrl] = encryptedTxt.base64Decoded()!
        
        let key = "1h9D4DUWbbiguPuXiIAk1H/fBUmCa442lUwdjE2zvoo=".base64Decoded()!
        let decryptExpectation = XCTestExpectation(description: "Decrypt")
        
        decryptor.decrypt(encryptedFileUrl: encryptedTxtUrl, decryptedFileUrl: decryptedTxtUrl, key: key) {
            decryptExpectation.fulfill()
        }
        
        wait(for: [decryptExpectation, decryptorDidStartCallExpectation, decryptorDidFinishCallExpectation, decryptorDidDecryptCallExpectation], timeout: 2)
        
        XCTAssertEqual(String(data: FileHandleMock.dataWritten[decryptedTxtUrl]!, encoding: .utf8)!, decryptedTxt)
    }
    
    func testDecryptJpeg() throws {
        let encryptedJpegUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptedJpegUrl = URL(fileURLWithPath: UUID().uuidString)
        let decryptor = AESDecryptor<FileHandleMock>()
        let decryptorDelegate = AESDecryptorDelegateMock()
        
        let decryptorDidStartCallExpectation = XCTestExpectation(description: "Decryptor did start")
        decryptorDelegate.decryptorDidStartCallback = { decryptedFileUrl in
            XCTAssertEqual(decryptedFileUrl, decryptedJpegUrl)
            decryptorDidStartCallExpectation.fulfill()
        }
        
        let decryptorDidFinishCallExpectation = XCTestExpectation(description: "Decryptor did finish")
        decryptorDelegate.decryptorDidFinishCallback = { decryptedFileUrl, error in
            XCTAssertNil(error)
            XCTAssertEqual(decryptedFileUrl, decryptedJpegUrl)
            decryptorDidFinishCallExpectation.fulfill()
        }
        
        let decryptorDidDecryptCallExpectation = XCTestExpectation(description: "Decryptor did decrypt")
        var totalBytesWritten: Int64 = 0
        decryptorDelegate.decryptorDidDecryptCallback = { bytesWritten in
            totalBytesWritten += bytesWritten
            decryptorDidDecryptCallExpectation.fulfill()
        }
        
        decryptor.delegate = decryptorDelegate
        FileHandleMock.dataToRead[encryptedJpegUrl] = encryptedJpeg.base64Decoded()!
        
        let key = "pQy0myUFoKq0AZzpAP7nzCLa9HET908YWGgHlfviUNU".base64Decoded()!
        let decryptExpectation = XCTestExpectation(description: "Decrypt")
        
        decryptor.decrypt(encryptedFileUrl: encryptedJpegUrl, decryptedFileUrl: decryptedJpegUrl, key: key) {
            decryptExpectation.fulfill()
        }
        
        wait(for: [decryptExpectation, decryptorDidStartCallExpectation, decryptorDidFinishCallExpectation, decryptorDidDecryptCallExpectation], timeout: 2)
        
        
        XCTAssertEqual(totalBytesWritten, 254082)
        XCTAssertEqual(FileHandleMock.dataWritten[decryptedJpegUrl]!.base64EncodedString(), decryptedJpeg)
    }
}
