//
//  AESDecryptor.swift
//  MegaKit
//
//  Created by Florin Pop on 25.11.21.
//

import Foundation
import CryptoSwift

public extension AES {
    enum BlockMode {
        case ctr
        case cbc
    }
    
    convenience init?(key base64Key: Data, blockMode: BlockMode, padding: Padding) {
        if blockMode == .ctr {
            let intKey = base64Key.toUInt32Array()
            let keyNOnce = [intKey[0] ^ intKey[4], intKey[1] ^ intKey[5], intKey[2] ^ intKey[6], intKey[3] ^ intKey[7], intKey[4], intKey[5]]
            let key = Data(uInt32Array: [keyNOnce[0], keyNOnce[1], keyNOnce[2], keyNOnce[3]])
            let iiv = [keyNOnce[4], keyNOnce[5], 0, 0]
            let iv = Data(uInt32Array: iiv)
            
            try? self.init(key: Array(key), blockMode: CTR(iv: Array(iv)), padding: padding)
        } else if blockMode == .cbc {
            let key: Data
            if base64Key.count == 32 {
                let keyBlocks = base64Key.toUInt32Array().blocks(of: 4)
                key = Data(uInt32Array: zip(keyBlocks[0], keyBlocks[1]).map(^))
            } else {
                key = base64Key
            }
            
            let iiv: [UInt32] = [0, 0, 0, 0]
            let iv = Data(uInt32Array: iiv)
            
            try? self.init(key: Array(key), blockMode: CBC(iv: Array(iv)), padding: padding)
        } else {
            return nil
        }
    }
}

public protocol AESDecryptorDelegate: AnyObject {
    func decryptorDidStart(decryptedFileUrl: URL)
    func decryptorDidFinish(decryptedFileUrl: URL, error: Error?)
    func decryptorDidDecrypt(bytesDecrypted: Int64)
}

public enum DecryptorError: Error {
    case readEncryptedFile, writeDecryptedFile, cypherError
}

public protocol SequentialIOHandle {
    init(forReadingFrom url: URL) throws
    init(forWritingTo url: URL) throws
    
    func readData(ofLength: Int) -> Data
    func write(_ data: Data)
}

extension FileHandle: SequentialIOHandle {}

public typealias AESFileDecryptor = AESDecryptor<FileHandle>

public class AESDecryptor<Handle: SequentialIOHandle> {
    public weak var delegate: AESDecryptorDelegate?
    
    public init() {}
    
    public func decrypt(encryptedFileUrl: URL, decryptedFileUrl: URL, key: Data, completion: (() -> Void)?) {
        self.delegate?.decryptorDidStart(decryptedFileUrl: decryptedFileUrl)
        
        guard let encryptedFileHandle = try? Handle(forReadingFrom: encryptedFileUrl) else {
            self.delegate?.decryptorDidFinish(decryptedFileUrl: decryptedFileUrl, error: DecryptorError.readEncryptedFile)
            completion?()
            return
        }
        
        guard let decryptedFileHandle = try? Handle(forWritingTo: decryptedFileUrl) else {
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
