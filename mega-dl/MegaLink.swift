//
//  MegaLink.swift
//  mega-dl
//
//  Created by Florin Pop on 22.07.21.
//

import Foundation
import CryptoSwift

struct MegaLink {
    enum LinkType {
        case file
        case folder
    }
    
    // http://megous.com/git/megatools/tree/tools/dl.c#n363
    private static let regexes: [String: LinkType] = [
        "^https?://mega(?:\\.co)?\\.nz/#!([a-z0-9_-]{8})!([a-z0-9_-]{43})$": .file,
        "^https?://mega\\.nz/file/([a-z0-9_-]{8})#([a-z0-9_-]{43})$": .file,
        "^https?://mega(?:\\.co)?\\.nz/#F!([a-z0-9_-]{8})!([a-z0-9_-]{22})(?:[!?]([a-z0-9_-]{8}))?$": .folder,
        "^https?://mega\\.nz/folder/([a-z0-9_-]{8})#([a-z0-9_-]{22})/file/([a-z0-9_-]{8})$": .folder,
        "^https?://mega\\.nz/folder/([a-z0-9_-]{8})#([a-z0-9_-]{22})/folder/([a-z0-9_-]{8})$": .folder,
        "^https?://mega\\.nz/folder/([a-z0-9_-]{8})#([a-z0-9_-]{22})$": .folder
    ]
    
    let url: String
    let type: LinkType
    let id: String
    let key: String
    let specific: String? // ?
    
    init?(url: String) {
        self.url = url
        let matchResult: (NSTextCheckingResult, LinkType)? = {
            for (pattern, type) in Self.regexes {
                let range = NSRange(url.startIndex..<url.endIndex, in: url)
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                
                if let match = regex?.matches(in: url, range: range).first,
                   match.numberOfRanges >= 2 {
                    return (match, type)
                }
            }
            return nil
        }()
        
        guard let (match, type) = matchResult else { return nil }
        
        self.type = type
        let string = url as NSString
        self.id = string.substring(with: match.range(at: 1))
        self.key = string.substring(with: match.range(at: 2)).replacingOccurrences(of: "%20", with: "")
        if match.numberOfRanges > 3 {
            self.specific = string.substring(with: match.range(at: 3))
        } else {
            self.specific = nil
        }
    }
}

extension AES {
    enum BlockMode {
        case ctr
        case cbc
    }
    
    convenience init?(key base64Key: Data, blockMode: BlockMode) {
        if blockMode == .ctr {
            let intKey = base64Key.toUInt32Array()
            let keyNOnce = [intKey[0] ^ intKey[4], intKey[1] ^ intKey[5], intKey[2] ^ intKey[6], intKey[3] ^ intKey[7], intKey[4], intKey[5]]
            let key = Data(uInt32Array: [keyNOnce[0], keyNOnce[1], keyNOnce[2], keyNOnce[3]])
            let iiv = [keyNOnce[4], keyNOnce[5], 0, 0]
            let iv = Data(uInt32Array: iiv)
            
            try? self.init(key: Array(key), blockMode: CTR(iv: Array(iv)), padding: .noPadding)
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
            
            try? self.init(key: Array(key), blockMode: CBC(iv: Array(iv)), padding: .zeroPadding)
        } else {
            return nil
        }
    }
}

struct MegaFileAttributes: Decodable {
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case name = "n"
    }
    
    init?(from attributeData: Data) throws {
        guard let attributeString = String(data: attributeData, encoding: .utf8),
              attributeString.starts(with: "MEGA{"),
              let attributeJSONData = attributeString[attributeString.index( attributeString.startIndex, offsetBy: 4)...].data(using: .utf8),
              let attributes = try? JSONDecoder().decode(Self.self, from: attributeJSONData)
        else {
            return nil
        }
        
        self = attributes
    }
}

struct MegaFileMetadata: Decodable {
    let size: Int64
    let encryptedAttributes: String
    let downloadLink: String
    
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

typealias JSONObject = [String: Any]
typealias JSONArray = [JSONObject]

enum DownloadError: Error {
    case badURL, requestFailed, badResponse, unknown, decryptionFailed
}

func getDownloadLink(from handle: String, parentNode: String? = nil, completion: @escaping (Result<MegaFileMetadata, DownloadError>) -> Void) {
    var urlComponents = URLComponents(string: "https://g.api.mega.co.nz/cs")
    
    urlComponents?.queryItems = [
        URLQueryItem(name: "id", value: "1"), // random int
    ]
    
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
        DispatchQueue.main.async {
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
        }
    }.resume()
}


struct DecryptedMegaFileMetadata {
    let url: URL
    let name: String
    let size: Int64
    let key: Data
}

func getFileMetadata(from link: MegaLink, completion: @escaping (Result<DecryptedMegaFileMetadata, DownloadError>) -> Void) {
    getDownloadLink(from: link.id) { result in
        switch result {
        case .success(let fileInfo):
            guard let url = URL(string: fileInfo.downloadLink) else {
                completion(.failure(.badURL))
                return
            }
            
            guard let base64Key = link.key.base64Decoded(),
                  let cipher = AES(key: base64Key, blockMode: .cbc),
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

struct DecryptedMegaNodeMetadata {
    enum NodeType: Int {
        case file = 0
        case folder = 1
    }
    
    let type: NodeType
    let id: String
    let parent: String
    let attributes: MegaFileAttributes
    let key: Data
    let timestamp: Int
    let size: Int?
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
        
        guard let cipher = AES(key: decryptedKey, blockMode: .cbc),
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

func getContents(of link: MegaLink, completion: @escaping (Result<[String: DecryptedMegaNodeMetadata], DownloadError>) -> Void) {
    guard let base64Key = link.key.base64Decoded(),
          let cipher = AES(key: base64Key, blockMode: .cbc)
    else {
        completion(.failure(.decryptionFailed))
        return
    }
    
    var urlComponents = URLComponents(string: "https://g.api.mega.co.nz/cs")
    
    urlComponents?.queryItems = [
        URLQueryItem(name: "n", value: link.id), // random int
    ]
    
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
        DispatchQueue.main.async {
            if let data = data {
                if let response = try? JSONDecoder().decode([MegaTreeMetadata].self, from: data),
                   let tree = response.first {
                    let decryptedNodes: [String: DecryptedMegaNodeMetadata]
                    
                    do {
                        decryptedNodes = try tree.nodes.reduce([String: DecryptedMegaNodeMetadata]()) { dict, encryptedMetadata in
                            guard let decryptedKey = encryptedMetadata.decryptKey(using: cipher)
                            else {
                                throw DownloadError.decryptionFailed
                            }
                            
                            guard let attributes = encryptedMetadata.decryptAttributes(using: cipher),
                                  let nodeType = DecryptedMegaNodeMetadata.NodeType(rawValue: encryptedMetadata.type)
                            else {
                                throw DownloadError.decryptionFailed
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
        }
    }.resume()
}
