//
//  Data+UInt32.swift
//  MegaKit
//
//  Created by Florin Pop on 22.07.21.
//

import Foundation

public extension Data {
    init(uInt32Array: [UInt32]) {
        self.init(capacity: uInt32Array.count * 4)
        for val in uInt32Array {
            Swift.withUnsafeBytes(of: val.bigEndian) { self.append(contentsOf: $0) }
        }
    }
    
    func toUInt32Array() -> [UInt32] {
        var result = [UInt32]()
        var paddedData = self
        if paddedData.count % 4 != 0 {
            paddedData.append(Data([UInt8](repeating: 0, count: paddedData.count % 4)))
        }
        let dataChunks = paddedData.blocks(of: 4)
        
        for i in 0..<dataChunks.count {
            // https://stackoverflow.com/a/56854262
            let bigEndianUInt32 = dataChunks[i].withUnsafeBytes { $0.load(as: UInt32.self) }
            let value = CFByteOrderGetCurrent() == CFByteOrder(CFByteOrderLittleEndian.rawValue)
                ? UInt32(bigEndian: bigEndianUInt32)
                : bigEndianUInt32
            result.append(value)
        }
        
        return result
    }
    
    // https://www.hackingwithswift.com/example-code/language/how-to-split-an-array-into-chunks
    func blocks(of size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
