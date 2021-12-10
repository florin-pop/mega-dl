//
//  MegaError.swift
//  MegaKit
//
//  Created by Florin Pop on 10.12.21.
//

import Foundation

public enum MegaError: Error {
    case badURL, requestFailed, badResponse, unknown, decryptionFailed, unimplemented
}
