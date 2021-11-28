//
//  Array+Blocks.swift
//  mega-dl
//
//  Created by Florin Pop on 22.07.21.
//

import Foundation

// https://www.hackingwithswift.com/example-code/language/how-to-split-an-array-into-chunks
extension Array {
    func blocks(of size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
