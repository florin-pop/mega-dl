//
//  String+Base64.swift
//  MegaKit
//
//  Created by Florin Pop on 22.07.21.
//

import Foundation

public extension String {
    func base64Decoded() -> Data? {
        let padded = self.replacingOccurrences(of: ",", with: "")
            .padding(toLength: ((self.count + 3) / 4) * 4,
                     withPad: "=",
                     startingAt: 0)
        let sanitized = padded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: sanitized)
    }
}
