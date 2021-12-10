//
//  MegaLink.swift
//  MegaKit
//
//  Created by Florin Pop on 22.07.21.
//

import Foundation

public struct MegaLink {
    public enum LinkType {
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
    
    public let url: String
    public let type: LinkType
    public let id: String
    public let key: String
    let specific: String? // ?
    
    public init(url: String) throws {
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
        
        guard let (match, type) = matchResult else { throw MegaError.badURL }
        
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
