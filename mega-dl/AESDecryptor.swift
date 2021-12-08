//
//  AESDecryptor.swift
//  mega-dl
//
//  Created by Florin Pop on 25.11.21.
//

import Foundation
import CryptoSwift

protocol AESDecryptorDelegate: AnyObject {
    func decryptorDidStart(decryptedFileUrl: URL)
    func decryptorDidFinish(decryptedFileUrl: URL, error: Error?)
    func decryptorDidDecrypt(bytesDecrypted: Int64)
}

enum DecryptorError: Error {
    case readEncryptedFile, writeDecryptedFile, cypherError
}

class AESDecryptor {
    public static let shared: AESDecryptor = AESDecryptor()
    weak var delegate: AESDecryptorDelegate?
    
    func decrypt(encryptedFileUrl: URL, decryptedFileUrl: URL, key: Data, completion: (() -> Void)?) {
        self.delegate?.decryptorDidStart(decryptedFileUrl: decryptedFileUrl)
        
        guard let encryptedFileHandle = try? FileHandle(forReadingFrom: encryptedFileUrl) else {
            self.delegate?.decryptorDidFinish(decryptedFileUrl: decryptedFileUrl, error: DecryptorError.readEncryptedFile)
            completion?()
            return
        }
        
        guard FileManager.default.createFile(atPath: decryptedFileUrl.path, contents: nil),
              let decryptedFileHandle = FileHandle(forWritingAtPath: decryptedFileUrl.path) else {
                  self.delegate?.decryptorDidFinish(decryptedFileUrl: decryptedFileUrl, error: DecryptorError.writeDecryptedFile)
                  completion?()
                  return
              }
        
        DispatchQueue.global(qos: .default).async { [weak self] in
            do {
                var decryptor = try AES(key: key, blockMode: .ctr, padding: .noPadding)?.makeDecryptor()
                var reachedEndOfFile = false
                repeat {
                    let encryptedData = encryptedFileHandle.readData(ofLength: 64 * 1024)
                    reachedEndOfFile = encryptedData.isEmpty
                    
                    let decryptedBytes: Array<UInt8>?
                    
                    if !encryptedData.isEmpty {
                        decryptedBytes = try decryptor?.update(withBytes: encryptedData.bytes)
                    } else {
                        decryptedBytes = try decryptor?.finish()
                    }
                    
                    if let decryptedBytes = decryptedBytes, !decryptedBytes.isEmpty
                    {
                        decryptedFileHandle.write(Data(decryptedBytes))
                        self?.delegate?.decryptorDidDecrypt(bytesDecrypted: Int64(decryptedBytes.count))
                    }
                } while !reachedEndOfFile
                self?.delegate?.decryptorDidFinish(decryptedFileUrl: decryptedFileUrl, error: nil)
                completion?()
            } catch {
                self?.delegate?.decryptorDidFinish(decryptedFileUrl: decryptedFileUrl, error: DecryptorError.cypherError)
                completion?()
            }
        }
        
    }
}
