//
//  MegaClient.swift
//  MegaKit
//
//  Created by Florin Pop on 10.12.21.
//

import Foundation
import CryptoSwift
import BigInt

struct MegaSequence {
    private var val = Int.random(in: 0..<0xFFFFFFFF)
    
    public static var instance: MegaSequence = MegaSequence()
    
    public mutating func next() -> Int {
        val += 1
        return val
    }
}

public struct MegaFileAttributes: Decodable {
    public let name: String
    
    enum CodingKeys: String, CodingKey {
        case name = "n"
    }
    
    init?(from attributeData: Data) throws {
        guard let attributeString = String(data: attributeData, encoding: .utf8),
              attributeString.starts(with: "MEGA{"),
              let attributeJSONData = attributeString[attributeString.index(attributeString.startIndex, offsetBy: 4)...].data(using: .utf8),
              let attributes = try? JSONDecoder().decode(Self.self, from: attributeJSONData)
        else {
            return nil
        }
        
        self = attributes
    }
}

public struct MegaFileMetadata: Decodable {
    public let size: Int64
    public let encryptedAttributes: String
    public let downloadLink: String
    
    enum CodingKeys: String, CodingKey {
        case size = "s"
        case encryptedAttributes = "at"
        case downloadLink = "g"
    }
}

extension MegaFileMetadata {
    func decryptAttributes(using cipher: Cipher) -> MegaFileAttributes? {
        guard let attributeData = try? encryptedAttributes.base64Decoded()?.decrypt(cipher: cipher)
        else {
            return nil
        }
        return try? MegaFileAttributes(from: attributeData)
    }
}

public struct DecryptedMegaFileMetadata {
    public let url: URL
    public let name: String
    public let size: Int64
    public let key: Data
}

public struct DecryptedMegaNodeMetadata {
    public enum NodeType: Int {
        case file = 0
        case folder = 1
    }
    
    public let type: NodeType
    public let id: String
    public let parent: String
    public let attributes: MegaFileAttributes
    public let key: Data
    public let timestamp: Int
    public let size: Int?
}

struct MegaNodeMetadata: Decodable {
    let type: Int
    let id: String
    let parent: String
    let encryptedAttributes: String
    let encryptedKey: String
    let timestamp: Int
    let size: Int?
    
    enum CodingKeys: String, CodingKey {
        case type = "t"
        case id = "h"
        case parent = "p"
        case encryptedAttributes = "a"
        case encryptedKey = "k"
        case timestamp = "ts"
        case size = "s"
    }
}

extension MegaNodeMetadata {
    func decryptKey(using cipher: Cipher) -> Data? {
        guard let base64EncryptedKey = self.encryptedKey.components(separatedBy: ":").last?.base64Decoded()
        else {
            return nil
        }
        
        var decryptedKey = base64EncryptedKey.blocks(of: 16).compactMap { try? $0.decrypt(cipher: cipher) }.reduce([], +)
        while decryptedKey.count % 16 != 0 {
            decryptedKey = decryptedKey + [0]
        }
        return Data(decryptedKey)
    }
    
    fileprivate func decryptAttributes(using cipher: Cipher) -> MegaFileAttributes? {
        guard let decryptedKey = self.decryptKey(using: cipher)
        else {
            return nil
        }
        
        guard let cipher = AES(key: decryptedKey, blockMode: .cbc, padding: .zeroPadding),
              let attributeData = try? encryptedAttributes.base64Decoded()?.decrypt(cipher: cipher)
        else {
            return nil
        }
        
        return try? MegaFileAttributes(from: attributeData)
    }
}

struct MegaTreeMetadata: Decodable {
    let nodes: [MegaNodeMetadata]
    
    enum CodingKeys: String, CodingKey {
        case nodes = "f"
    }
}

public func getDownloadLink(from handle: String, parentNode: String? = nil, sessionID: String? = nil, completion: @escaping (Result<MegaFileMetadata, MegaError>) -> Void) {
    var urlComponents = URLComponents(string: "https://g.api.mega.co.nz/cs")
    
    urlComponents?.queryItems = [
        URLQueryItem(name: "id", value: "\(MegaSequence.instance.next())"),
    ]
    
    if let sessionID = sessionID {
        urlComponents?.queryItems?.append(URLQueryItem(name: "sid", value: sessionID))
    }
    
    if let node = parentNode {
        urlComponents?.queryItems?.append(
            URLQueryItem(name: "n", value: node)
        )
    }
    
    guard let url = urlComponents?.url else {
        completion(.failure(.badURL))
        return
    }
    
    let requestPayload = [[
        "a": "g", // action
        "g": "1",
        "ssl": "1",
        (parentNode != nil ? "n" : "p"): handle
    ]]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    guard let requestData = try? JSONSerialization.data(withJSONObject: requestPayload, options: []) else {
        completion(.failure(.requestFailed))
        return
    }
    
    request.httpBody = requestData
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let data = data {
            if let response = try? JSONDecoder().decode([MegaFileMetadata].self, from: data),
               let fileInfo = response.first {
                
                completion(.success(fileInfo))
            } else {
                completion(.failure(.badResponse))
            }
        } else if error != nil {
            completion(.failure(.requestFailed))
        } else {
            completion(.failure(.unknown))
        }
    }.resume()
}

public func getFileMetadata(from link: MegaLink, sessionID: String? = nil, completion: @escaping (Result<DecryptedMegaFileMetadata, MegaError>) -> Void) {
    getDownloadLink(from: link.id, sessionID: sessionID) { result in
        switch result {
        case .success(let fileInfo):
            guard let url = URL(string: fileInfo.downloadLink) else {
                completion(.failure(.badURL))
                return
            }
            
            guard let base64Key = link.key.base64Decoded(),
                  let cipher = AES(key: base64Key, blockMode: .cbc, padding: .zeroPadding),
                  let fileName = fileInfo.decryptAttributes(using: cipher)?.name else {
                      completion(.failure(.decryptionFailed))
                      return
                  }
            
            completion(.success(DecryptedMegaFileMetadata(url: url, name: fileName, size: fileInfo.size, key: base64Key)))
            
        case .failure(let error):
            completion(.failure(error))
        }
    }
}

public func getContents(of link: MegaLink, sessionID: String? = nil, completion: @escaping (Result<[String: DecryptedMegaNodeMetadata], MegaError>) -> Void) {
    guard let base64Key = link.key.base64Decoded(),
          let cipher = AES(key: base64Key, blockMode: .cbc, padding: .zeroPadding)
    else {
        completion(.failure(.decryptionFailed))
        return
    }
    
    var urlComponents = URLComponents(string: "https://g.api.mega.co.nz/cs")
    
    urlComponents?.queryItems = [
        URLQueryItem(name: "id", value: "\(MegaSequence.instance.next())"),
        URLQueryItem(name: "n", value: link.id),
    ]
    
    if let sessionID = sessionID {
        urlComponents?.queryItems?.append(URLQueryItem(name: "sid", value: sessionID))
    }
    
    guard let url = urlComponents?.url else {
        completion(.failure(.badURL))
        return
    }
    
    let requestPayload = [[
        "a": "f", // action
        "c": "1",
        "r": "1"
    ]]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    guard let requestData = try? JSONSerialization.data(withJSONObject: requestPayload, options: []) else {
        completion(.failure(.requestFailed))
        return
    }
    
    request.httpBody = requestData
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let data = data {
            if let response = try? JSONDecoder().decode([MegaTreeMetadata].self, from: data),
               let tree = response.first {
                let decryptedNodes: [String: DecryptedMegaNodeMetadata]
                
                do {
                    decryptedNodes = try tree.nodes.reduce([String: DecryptedMegaNodeMetadata]()) { dict, encryptedMetadata in
                        guard let decryptedKey = encryptedMetadata.decryptKey(using: cipher)
                        else {
                            throw MegaError.decryptionFailed
                        }
                        
                        guard let attributes = encryptedMetadata.decryptAttributes(using: cipher),
                              let nodeType = DecryptedMegaNodeMetadata.NodeType(rawValue: encryptedMetadata.type)
                        else {
                            throw MegaError.decryptionFailed
                        }
                        var dict = dict
                        dict[encryptedMetadata.id] = DecryptedMegaNodeMetadata(type: nodeType, id: encryptedMetadata.id, parent: encryptedMetadata.parent, attributes: attributes, key: decryptedKey, timestamp: encryptedMetadata.timestamp, size: encryptedMetadata.size)
                        return dict
                    }
                } catch {
                    completion(.failure(.decryptionFailed))
                    return
                }
                
                completion(.success(decryptedNodes))
            } else {
                completion(.failure(.badResponse))
            }
        } else if error != nil {
            completion(.failure(.requestFailed))
        } else {
            completion(.failure(.unknown))
        }
    }.resume()
}

struct MegaLoginVersion: Decodable {
    let number: Int
    
    enum CodingKeys: String, CodingKey {
        case number = "v"
    }
}

public func login(using email: String, password: String, completion: @escaping (Result<String, MegaError>) -> Void) {
    var urlComponents = URLComponents(string: "https://g.api.mega.co.nz/cs")
    
    urlComponents?.queryItems = [
        URLQueryItem(name: "id", value: "\(MegaSequence.instance.next())"),
    ]
    
    guard let url = urlComponents?.url else {
        completion(.failure(.badURL))
        return
    }
    
    let requestPayload = [[
        "a": "us0",
        "user": email.lowercased()
    ]]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    guard let requestData = try? JSONSerialization.data(withJSONObject: requestPayload, options: []) else {
        completion(.failure(.requestFailed))
        return
    }
    
    request.httpBody = requestData
    // TODO check response code
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let data = data {
            if let response = try? JSONDecoder().decode([MegaLoginVersion].self, from: data),
               let loginVersion = response.first {
                guard loginVersion.number == 1 else {
                    completion(.failure(.unimplemented))
                    return
                }
                
                guard let arr = password.data(using: .utf8)?.toUInt32Array() else {
                    completion(.failure(.unknown))
                    return
                }
                
                // https://github.com/odwyersoftware/mega.py/blob/c27d8379e48af23072c46350396ae75f84ec1e30/src/mega/crypto.py#L55
                var passwordKey: [UInt32] = [0x93C467E3, 0x7DB0C7A4, 0xD1BE3F81, 0x0152CB56]
                for _ in 0..<0x10000 {
                    for j in stride(from: 0, to: arr.count, by: 4) {
                        var key: [UInt32] = [0, 0, 0, 0]
                        for i in 0..<4 {
                            if i + j < arr.count {
                                key[i] = arr[i + j]
                            }
                        }
                        
                        guard let cipher = AES(key: Data(uInt32Array: key), blockMode: .cbc, padding: .noPadding),
                              let encryptedKey = try? Data(uInt32Array: passwordKey).encrypt(cipher: cipher).toUInt32Array() else {
                                  completion(.failure(.decryptionFailed))
                                  return
                              }
                        passwordKey = encryptedKey
                    }
                }
                
                
                guard let s32 = email.lowercased().data(using: .utf8)?.toUInt32Array(),
                      let cipher = AES(key: Data(uInt32Array: passwordKey), blockMode: .cbc, padding: .noPadding) else {
                          completion(.failure(.decryptionFailed))
                          return
                      }
                
                var h32: [UInt32] = [0, 0, 0, 0]
                for i in 0 ..< s32.count {
                    h32[i % 4] ^= s32[i]
                }
                
                var h32Data = Data(uInt32Array: h32)
                for _ in 0..<0x4000 {
                    guard let encryptedHash = try? h32Data.encrypt(cipher: cipher) else {
                        completion(.failure(.decryptionFailed))
                        return
                    }
                    h32Data = encryptedHash
                }
                
                h32 = h32Data.toUInt32Array()
                
                let passwordHash = Data(uInt32Array: [h32[0], h32[2]]).base64EncodedString()
                
                openSession(email: email, userHash: passwordHash) { result in
                    switch result {
                    case .success(let loginSessionData):
                        getSessionId(passwordKey: Data(uInt32Array: passwordKey), loginSessionData: loginSessionData) { result in
                            switch result {
                            case .success(let sessionID):
                                completion(.success(sessionID))
                            case .failure(let error):
                                completion(.failure(error))
                            }
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            } else {
                completion(.failure(.badResponse))
            }
        } else if error != nil {
            completion(.failure(.requestFailed))
        } else {
            completion(.failure(.unknown))
        }
    }.resume()
}

func openSession(email: String, userHash: String, completion: @escaping (Result<Data, MegaError>) -> Void) {
    var urlComponents = URLComponents(string: "https://g.api.mega.co.nz/cs")
    
    urlComponents?.queryItems = [
        URLQueryItem(name: "id", value: "\(MegaSequence.instance.next())"),
    ]
    
    guard let url = urlComponents?.url else {
        completion(.failure(.badURL))
        return
    }
    
    let requestPayload = [[
        "a": "us",
        "user": email.lowercased(),
        "uh": userHash
    ]]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    guard let requestData = try? JSONSerialization.data(withJSONObject: requestPayload, options: []) else {
        completion(.failure(.requestFailed))
        return
    }
    
    request.httpBody = requestData
    // TODO check response code
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let data = data {
            //            print((response as? HTTPURLResponse)?.statusCode)
            completion(.success(data))
        } else if error != nil {
            completion(.failure(.requestFailed))
        } else {
            completion(.failure(.unknown))
        }
    }.resume()
}

struct MegaLoginSession: Decodable {
    let encryptedMasterKey: String
    let encryptedSessionID: String
    let encryptedRSAPrivateKey: String
    
    enum CodingKeys: String, CodingKey {
        case encryptedMasterKey = "k"
        case encryptedSessionID = "csid"
        case encryptedRSAPrivateKey = "privk"
    }
}

func getSessionId(passwordKey: Data, loginSessionData: Data, completion: @escaping (Result<String, MegaError>) -> Void) {
    if let response = try? JSONDecoder().decode([MegaLoginSession].self, from: loginSessionData),
       let loginSession = response.first {
        
        guard let cipher = AES(key: passwordKey, blockMode: .cbc, padding: .noPadding) else {
            completion(.failure(.decryptionFailed))
            return
        }
        
        guard let masterKey = try? loginSession.encryptedMasterKey.base64Decoded()?.decrypt(cipher: cipher) else {
            completion(.failure(.decryptionFailed))
            return
        }
        
        guard let cipher = AES(key: masterKey, blockMode: .cbc, padding: .noPadding) else {
            completion(.failure(.decryptionFailed))
            return
        }
        
        guard let encryptedRSAPrivateKeyData = loginSession.encryptedRSAPrivateKey.base64Decoded()?.toUInt32Array() else {
            completion(.failure(.decryptionFailed))
            return
        }
        
        var decryptedRSAPrivateKey = Data()
        
        for i in stride(from: 0, to: encryptedRSAPrivateKeyData.count, by: 4) {
            guard let decryptedRSAPrpoivateKeyPart = try? Data(uInt32Array: [encryptedRSAPrivateKeyData[i], encryptedRSAPrivateKeyData[i+1], encryptedRSAPrivateKeyData[i+2], encryptedRSAPrivateKeyData[i+3]]).decrypt(cipher: cipher) else {
                completion(.failure(.decryptionFailed))
                return
            }
            decryptedRSAPrivateKey.append(decryptedRSAPrpoivateKeyPart)
        }
        
        var j = 0
        var rsaPrivateKey: [BigUInt] = [0, 0, 0, 0]
        for i in 0..<4 {
            let bitlength = (Int(decryptedRSAPrivateKey[j]) * 256) + Int(decryptedRSAPrivateKey[j + 1])
            var bytelength = bitlength / 8
            bytelength = bytelength + 2
            let data = Data(decryptedRSAPrivateKey[j + 2..<j + bytelength])
            rsaPrivateKey[i] = BigUInt(data)
            j = j + bytelength
        }
        
        let first_factor_p = rsaPrivateKey[0]
        let second_factor_q = rsaPrivateKey[1]
        let private_exponent_d = rsaPrivateKey[2]
        let rsa_modulus_n = first_factor_p * second_factor_q
        
        guard let encryptedSessionID = loginSession.encryptedSessionID.base64Decoded() else {
            completion(.failure(.decryptionFailed))
            return
        }
        
        let decryptedSessionID = BigInt(Data(encryptedSessionID)).power(BigInt(private_exponent_d), modulus: BigInt(rsa_modulus_n))
        
        var binarySessionID = decryptedSessionID.serialize()
        if binarySessionID[0] == 0 {
            binarySessionID = Data(binarySessionID[1...])
        }
        var hexSessionID = binarySessionID.hexEncodedString()
        if hexSessionID.count % 2 != 0 {
            hexSessionID = "0" + hexSessionID
        }
        
        let sessionID = Data(hexSessionID.hexDecodedData()[..<43])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        completion(.success(sessionID))
    }
}
