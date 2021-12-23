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
            // As documented in https://help.servmask.com/knowledgebase/mega-error-codes/
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
        case .cryptographyError:
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

    func run() {
        guard let megaLink = try? MegaLink(url: url) else {
            fatalError("Failed to recognize given url as a Mega link.")
        }

        let downloadProgress: DownloadProgress = {
            let downloadProgress = DownloadProgress()
            DownloadManager.shared.delegate = downloadProgress
            return downloadProgress
        }()

        let decryptor = AESFileDecryptor()
        decryptor.delegate = downloadProgress

        let sigwinchSrc = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

        sigwinchSrc.setEventHandler {
            downloadProgress.reset()
        }
        sigwinchSrc.resume()

        // Intercept Ctrl+C in order to leave the Terminal in a clean state
        signal(SIGINT, SIG_IGN)
        sigintSrc.setEventHandler {
            downloadProgress.cleanup()
            MegaDL.exit(withError: nil)
        }
        sigintSrc.resume()

        // Use a dispatch group in order to wait for all downloads to finish
        let dispatchGroup = DispatchGroup()

        dispatchGroup.enter()
        dispatchGroup.notify(queue: .main) {
            MegaDL.exit(withError: nil)
        }

        scheduleDownloadSpeedUpdateTimer(downloadProgress: downloadProgress)
        DispatchQueue.global(qos: .default).async {
            openSession { sessionID, error in
                guard error == nil else {
                    dispatchGroup.leave()
                    return
                }

                download(from: megaLink, sessionID: sessionID, dispatchGroup: dispatchGroup, decryptor: decryptor, progress: downloadProgress)
            }
        }

        dispatchMain()
    }
}

func openSession(completion: @escaping (String?, MegaError?) -> Void) {
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
                completion(sessionID, nil)
            case let .failure(error):
                print("Authentication failed with error: \(error.description)")
                completion(nil, error)
            }
        }
    } else {
        print("Proceeding without credentials")
        completion(nil, nil)
    }
}

func download(from megaLink: MegaLink, sessionID: String? = nil, dispatchGroup: DispatchGroup, decryptor: AESFileDecryptor, progress: DownloadProgress) {
    if megaLink.type == .folder {
        let megaClient = MegaClient()
        megaClient.getContents(of: megaLink, sessionID: sessionID) { result in
            switch result {
            case let .success(items):
                var totalBytesExpected = items.values.filter { $0.type == .file }.compactMap { Int64($0.size ?? 0) }.reduce(0, +)
                progress.totalBytesExpected = totalBytesExpected

                for (_, item) in items {
                    var decryptedFileUrl = URL(fileURLWithPath: FileManager().currentDirectoryPath)
                    items.getPath(key: item.id, url: &decryptedFileUrl)

                    if item.type == .folder {
                        try? FileManager().createDirectory(at: decryptedFileUrl, withIntermediateDirectories: true, attributes: nil)
                    } else if item.type == .file {
                        if FileManager.default.fileExists(atPath: decryptedFileUrl.path) {
                            print("File exists: \(item.attributes.name).")
                            totalBytesExpected -= Int64(item.size ?? 0)
                            progress.totalBytesExpected = totalBytesExpected
                            continue
                        }

                        dispatchGroup.enter()
                        megaClient.getDownloadLink(from: item.id, parentNode: megaLink.id, sessionID: sessionID) { result in
                            switch result {
                            case let .success(fileInfo):
                                guard let url = URL(string: fileInfo.downloadLink) else {
                                    print("Bad download URL for \(item.attributes.name). Skipping.")
                                    dispatchGroup.leave()
                                    return
                                }

                                downloadAndDecryptFile(from: url, to: decryptedFileUrl, fileName: item.attributes.name, decryptionKey: item.key, decryptor: decryptor) {
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
                progress.totalBytesExpected = downloadMetadata.size
                let decryptedFileUrl = URL(fileURLWithPath: FileManager().currentDirectoryPath).appendingPathComponent(downloadMetadata.name)
                if FileManager.default.fileExists(atPath: decryptedFileUrl.path) {
                    print("File exists: \(downloadMetadata.name).")
                    dispatchGroup.leave()
                } else {
                    downloadAndDecryptFile(from: downloadMetadata.url, to: decryptedFileUrl, fileName: downloadMetadata.name, decryptionKey: downloadMetadata.key, decryptor: decryptor) {
                        dispatchGroup.leave()
                    }
                }
            case let .failure(error):
                print("Retrieve file metadata failed with error: \(error.description)")
                dispatchGroup.leave()
            }
        }
    }
}

func downloadAndDecryptFile(from downloadUrl: URL, to decryptedFileUrl: URL, fileName: String, decryptionKey: Data, decryptor: AESFileDecryptor, completion: @escaping () -> Void) {
    let encryptedFileUrl = decryptedFileUrl.appendingPathExtension("encrypted")

    if FileManager.default.fileExists(atPath: encryptedFileUrl.path) {
        FileManager.default.createFile(atPath: decryptedFileUrl.path, contents: nil)

        decryptor.decrypt(encryptedFileUrl: encryptedFileUrl, decryptedFileUrl: decryptedFileUrl, key: decryptionKey) {
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

            decryptor.decrypt(encryptedFileUrl: encryptedFileUrl, decryptedFileUrl: decryptedFileUrl, key: decryptionKey) {
                try? FileManager.default.removeItem(at: encryptedFileUrl)
                completion()
            }
        }
    }
}

func scheduleDownloadSpeedUpdateTimer(downloadProgress: DownloadProgress) {
    DispatchQueue.global(qos: .userInteractive).async {
        let downloadSpeedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if downloadProgress.lastMeasurement < downloadProgress.totalBytesDownloaded {
                downloadProgress.downloadSpeed = downloadProgress.totalBytesDownloaded - downloadProgress.lastMeasurement
            } else {
                downloadProgress.downloadSpeed = 0
            }
            downloadProgress.lastMeasurement = downloadProgress.totalBytesDownloaded

            if downloadProgress.totalBytesDownloaded > 0 {
                downloadProgress.printProgress()
            }
        }

        let runLoop = RunLoop.current
        runLoop.add(downloadSpeedTimer, forMode: .default)
        runLoop.run()
    }
}

MegaDL.main()
