//
//  Data+UInt32.swift
//  mega-dl
//
//  Created by Florin Pop on 22.07.21.
//

import Foundation

extension Data {
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

// https://stackoverflow.com/a/52600783
extension Data {
  /// A hexadecimal string representation of the bytes.
  func hexEncodedString() -> String {
    let hexDigits = Array("0123456789abcdef".utf16)
    var hexChars = [UTF16.CodeUnit]()
    hexChars.reserveCapacity(count * 2)

    for byte in self {
      let (index1, index2) = Int(byte).quotientAndRemainder(dividingBy: 16)
      hexChars.append(hexDigits[index1])
      hexChars.append(hexDigits[index2])
    }

    return String(utf16CodeUnits: hexChars, count: hexChars.count)
  }
}

extension String {
  /// A data representation of the hexadecimal bytes in this string.
  func hexDecodedData() -> Data {
    // Get the UTF8 characters of this string
    let chars = Array(utf8)

    // Keep the bytes in an UInt8 array and later convert it to Data
    var bytes = [UInt8]()
    bytes.reserveCapacity(count / 2)

    // It is a lot faster to use a lookup map instead of strtoul
    let map: [UInt8] = [
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // 01234567
      0x08, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 89:;<=>?
      0x00, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x00, // @ABCDEFG
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00  // HIJKLMNO
    ]

    // Grab two characters at a time, map them and turn it into a byte
    for i in stride(from: 0, to: count, by: 2) {
      let index1 = Int(chars[i] & 0x1F ^ 0x10)
      let index2 = Int(chars[i + 1] & 0x1F ^ 0x10)
      bytes.append(map[index1] << 4 | map[index2])
    }

    return Data(bytes)
  }
}
