//
//  main.swift
//  mega-dl
//
//  Created by Florin Pop on 22.07.21.
//

import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MegaKit

// Upcoming features:
// Resume on error
// Read credentials from Keychain

extension Dictionary where Key == String, Value == DecryptedMegaNodeMetadata {
    func getPath(key: String, url: inout URL) {
        if let node = self[key] {
            getPath(key: node.parent, url: &url)
            url = url.appendingPathComponent(node.attributes.name)
        }
    }
}

extension MegaError {
    var description: String {
        switch self {
        case .badURL:
            return "The URL is not a valid Mega link"
        case .requestFailed:
            return "HTTP request failed"
        case let .apiError(code):
            // https://help.servmask.com/knowledgebase/mega-error-codes/
            switch code {
            case -2: return "Invalid arguments"
            case -4: return "Too many requests per second"
            case -6: return "Too many requests accessing the URL"
            case -8: return "Expired URL"
            case -9: return "Not found"
            case -15: return "Invalid or expired user session"
            case -17: return "Quota exceeded"
            case -18: return "Resource temporarily not available"
            case -19: return "Too many connections"
            default: return "API error code \(code)"
            }
        case let .httpError(code):
            return "HTTP error code \(code)"
        case .badResponse:
            return "Received unexpected response from API"
        case .unknown:
            return "Unknown error"
        case .decryptionFailed:
            return "Cryptography error"
        case .unimplemented:
            return "The API required a functionality that is not yet implemented"
        }
    }
}

extension DownloadProgress: DownloadDelegate {
    func downloadManagerDidSchedule(file: String) {
        write("Download scheduled: \(file)\n")
    }

    func downloadManagerDidWrite(bytes: Int64) {
        guard totalBytesExpected > 0 else {
            return
        }

        totalBytesDownloaded = bytes

        printProgress()
    }

    func downloadManagerDidComplete(file: String, error: Error?) {
        if error == nil {
            write("Download complete: \(file)\n")
        } else {
            write("Download failed: \(file)\n")
        }
    }
}

extension DownloadProgress: AESDecryptorDelegate {
    func decryptorDidStart(decryptedFileUrl: URL) {
        write("Decryption started: \(decryptedFileUrl.lastPathComponent)\n")
    }

    func decryptorDidFinish(decryptedFileUrl: URL, error: Error?) {
        if error == nil {
            write("Decryption complete: \(decryptedFileUrl.lastPathComponent)\n")
        } else {
            write("Decryption failed: \(decryptedFileUrl.lastPathComponent)\n")
        }
    }

    func decryptorDidDecrypt(bytesDecrypted: Int64) {
        guard totalBytesExpected > 0 else {
            return
        }

        totalBytesDecrypted += bytesDecrypted

        printProgress()
    }
}

struct MegaDL: ParsableCommand {
    @Argument(help: "The download url.") var url: String

    static let decryptor = AESFileDecryptor()

    func run() {
        guard let megaLink = try? MegaLink(url: url) else {
            fatalError("Failed to recognize given url as a Mega link.")
        }

        let downloadProgress: DownloadProgress = {
            let downloadProgress = DownloadProgress()
            DownloadManager.shared.delegate = downloadProgress
            Self.decryptor.delegate = downloadProgress
            return downloadProgress
        }()

        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        dispatchGroup.notify(queue: .main) {
            MegaDL.exit(withError: nil)
        }

        DispatchQueue.global(qos: .default).async {
            let homeDirURL = FileManager.default.homeDirectoryForCurrentUser
            let optionalConfig = try? String(contentsOf: homeDirURL.appendingPathComponent(".megarc"))

            if let config = optionalConfig.map({ parseConfig($0) }),
               let credentials = config["Login"],
               let email = credentials["Username"],
               let password = credentials["Password"]
            {
                print("Authenticating using stored credentials")

                let megaClient = MegaClient()
                megaClient.login(using: email, password: password) { result in
                    switch result {
                    case let .success(sessionID):
                        process(megaLink: megaLink, dispatchGroup: dispatchGroup, sessionID: sessionID, bytesExpectedCallback: { downloadProgress.totalBytesExpected = $0 })
                    case let .failure(error):
                        print("Authentication failed with error: \(error.description)")
                        dispatchGroup.leave()
                    }
                }
            } else {
                print("Downloading without credentials")
                process(megaLink: megaLink, dispatchGroup: dispatchGroup, bytesExpectedCallback: { downloadProgress.totalBytesExpected = $0 })
            }
        }

        dispatchMain()
    }

    func process(megaLink: MegaLink, dispatchGroup: DispatchGroup, sessionID: String? = nil, bytesExpectedCallback: @escaping (Int64) -> Void) {
        if megaLink.type == .folder {
            let megaClient = MegaClient()
            megaClient.getContents(of: megaLink, sessionID: sessionID) { result in
                switch result {
                case let .success(items):
                    let totalBytesExpected = items.values.filter { $0.type == .file }.compactMap { Int64($0.size ?? 0) }.reduce(0, +)
                    bytesExpectedCallback(totalBytesExpected)

                    for (_, item) in items {
                        var decryptedFileUrl = URL(fileURLWithPath: FileManager().currentDirectoryPath)
                        items.getPath(key: item.id, url: &decryptedFileUrl)

                        if item.type == .folder {
                            try? FileManager().createDirectory(at: decryptedFileUrl, withIntermediateDirectories: true, attributes: nil)
                        } else if item.type == .file {
                            dispatchGroup.enter()
                            megaClient.getDownloadLink(from: item.id, parentNode: megaLink.id, sessionID: sessionID) { result in
                                switch result {
                                case let .success(fileInfo):
                                    guard let url = URL(string: fileInfo.downloadLink) else {
                                        print("Bad download URL for \(item.attributes.name). Skipping.")
                                        dispatchGroup.leave()
                                        return
                                    }

                                    downloadFile(from: url, to: decryptedFileUrl, fileName: item.attributes.name, decryptionKey: item.key) {
                                        dispatchGroup.leave()
                                    }
                                case .failure:
                                    print("Cannot resolve download URL for \(item.attributes.name). Skipping.")
                                    dispatchGroup.leave()
                                }
                            }
                        }
                    }
                case let .failure(error):
                    print("Retrieve folder contents failed with error: \(error.description)")
                }

                dispatchGroup.leave()
            }
        } else {
            let megaClient = MegaClient()
            megaClient.getFileMetadata(from: megaLink, sessionID: sessionID) { result in
                switch result {
                case let .success(downloadMetadata):
                    bytesExpectedCallback(downloadMetadata.size)
                    let decryptedFileUrl = URL(fileURLWithPath: FileManager().currentDirectoryPath).appendingPathComponent(downloadMetadata.name)
                    downloadFile(from: downloadMetadata.url, to: decryptedFileUrl, fileName: downloadMetadata.name, decryptionKey: downloadMetadata.key) {
                        dispatchGroup.leave()
                    }
                case let .failure(error):
                    print("Retrieve file metadata failed with error: \(error.description)")
                    dispatchGroup.leave()
                }
            }
        }
    }

    func downloadFile(from downloadUrl: URL, to decryptedFileUrl: URL, fileName: String, decryptionKey: Data, completion: @escaping () -> Void) {
        let encryptedFileUrl = decryptedFileUrl.appendingPathExtension("encrypted")

        if FileManager.default.fileExists(atPath: encryptedFileUrl.path) {
            FileManager.default.createFile(atPath: decryptedFileUrl.path, contents: nil)

            Self.decryptor.decrypt(encryptedFileUrl: encryptedFileUrl, decryptedFileUrl: decryptedFileUrl, key: decryptionKey) {
                try? FileManager.default.removeItem(at: encryptedFileUrl)
                completion()
            }
        } else {
            DownloadManager.shared.download(url: downloadUrl, name: fileName) { downloadedFileUrl, error in
                guard let downloadedFileUrl = downloadedFileUrl, error == nil else {
                    completion()
                    return
                }

                try? FileManager.default.moveItem(at: downloadedFileUrl, to: encryptedFileUrl)
                FileManager.default.createFile(atPath: decryptedFileUrl.path, contents: nil)

                Self.decryptor.decrypt(encryptedFileUrl: encryptedFileUrl, decryptedFileUrl: decryptedFileUrl, key: decryptionKey) {
                    try? FileManager.default.removeItem(at: encryptedFileUrl)
                    completion()
                }
            }
        }
    }
}

MegaDL.main()
