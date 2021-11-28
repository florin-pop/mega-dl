//
//  main.swift
//  mega-dl
//
//  Created by Florin Pop on 22.07.21.
//

import ArgumentParser
import CryptoSwift
import Darwin
import Dispatch
import Foundation
import OSLog

let logger = Logger()

func write(_ s: String) {
    DispatchQueue.main.async {
        print(s, terminator: "")
    }
}

extension Dictionary where Key == String, Value == DecryptedMegaNodeMetadata {
    func getPath(key: String, url: inout URL) {
        if let node = self[key] {
            getPath(key: node.parent, url: &url)
            url = url.appendingPathComponent(node.attributes.name)
        }
    }
}

class DownloadProgress {
    var totalBytesExpected: Int64 = 0
    var totalBytesDownloaded: Int64 = 0
    var totalBytesDecrypted: Int64 = 0
    var numberOfTerminalRows: UInt16 = 0
    let sigwinchSrc: DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    
    init() {
        var w = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_row > 0 else {
            return
        }
        self.numberOfTerminalRows = w.ws_row
        
        sigwinchSrc.setEventHandler {
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
                write("\u{001B}7")  // Save cursor position
                write("\u{001B}[0;\(self.numberOfTerminalRows)r")  // Drop line reservation
                write("\u{001B}[\(self.numberOfTerminalRows);0f")  // Move the cursor to the bottom line
                write("\u{001B}[0K")  // Clean that line
                write("\u{001B}8")  // Restore the cursor position
                
                self.numberOfTerminalRows = w.ws_row
                
                write("\n")  // Ensure the last line is available.
                write("\u{001B}7")  // Save cursor position
                write("\u{001B}[0;\(w.ws_row - 1)r")  // Reserve the bottom line
                write("\u{001B}8")  // Restore the cursor position
                write("\u{001B}[1A")  // Move up one line
            }
        }
        sigwinchSrc.resume()
        
        /* Setup */
        
        write("\n")  // Ensure the last line is available.
        write("\u{001B}7")  // Save cursor position
        write("\u{001B}[0;\(w.ws_row - 1)r")  // Reserve the bottom line
        write("\u{001B}8")  // Restore the cursor position
        write("\u{001B}[1A")  // Move up one line
    }
    
    func printProgress() {
        DispatchQueue.main.async {
            write("\u{001B}7")  // Save cursor position
            write("\u{001B}[\(self.numberOfTerminalRows)0f")  // Move cursor to the bottom margin
            write("\n\u{001B}[0K")  // Clean that line
            write("Download progress: \(self.totalBytesDownloaded * 100 / self.totalBytesExpected)% | Decryption progress: \(self.totalBytesDecrypted * 100 / self.totalBytesExpected)%")  // Write the progress
            write("\u{001B}8")  // Restore cursor position
        }
    }
}

extension DownloadProgress: DownloadDelegate {
    func downloadManagerDidSchedule(file: String) {
        write("Download scheduled: \(file)\n")
    }
    
    func downloadManagerDidWrite(bytes: Int64) {
        guard self.totalBytesExpected > 0 else {
            return
        }
        
        self.totalBytesDownloaded = bytes
        
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
        guard self.totalBytesExpected > 0 else {
            return
        }
        
        self.totalBytesDecrypted += bytesDecrypted
        
        printProgress()
    }
}


struct MegaDL: ParsableCommand {
    @Argument(help: "The download url.") var url: String
    
    func run() {
        guard let megaLink = MegaLink(url: url) else {
            fatalError("Failed to recognize given url as a mega link.")
        }
        
        let downloadProgress: DownloadProgress = {
            let downloadProgress = DownloadProgress()
            DownloadManager.shared.delegate = downloadProgress
            AESDecryptor.shared.delegate = downloadProgress
            return downloadProgress
        }()
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        
        if megaLink.type == .folder {
            getContents(of: megaLink) { result in
                switch result {
                case .success(let items):
                    downloadProgress.totalBytesExpected = items.values.filter {$0.type == .file}.compactMap { Int64($0.size ?? 0) }.reduce(0, +)
                    
                    for (_, item) in items {
                        var decryptedFileUrl = URL(fileURLWithPath: FileManager().currentDirectoryPath)
                        items.getPath(key: item.id, url: &decryptedFileUrl)
                        
                        if item.type == .folder {
                            try? FileManager().createDirectory(at: decryptedFileUrl, withIntermediateDirectories: true, attributes: nil)
                        } else if item.type == .file {
                            dispatchGroup.enter()
                            getDownloadLink(from: item.id, parentNode: megaLink.id) { result in
                                switch result {
                                case .success(let fileInfo):
                                    guard let url = URL(string: fileInfo.downloadLink) else {
                                        print("Bad download URL for \(item.attributes.name). Skipping.")
                                        dispatchGroup.leave()
                                        return
                                    }
                                    
                                    DownloadManager.shared.download(url: url, name: item.attributes.name) { encryptedFileUrl, error in
                                        guard let encryptedFileUrl = encryptedFileUrl, error == nil else {
                                            // Download error should be handled by the delegate
                                            dispatchGroup.leave()
                                            return
                                        }
                                        
                                        AESDecryptor.shared.decrypt(encryptedFileUrl: encryptedFileUrl, decryptedFileUrl: decryptedFileUrl, key: item.key) {
                                            dispatchGroup.leave()
                                        }
                                    }
                                case .failure(let error):
                                    print("Cannot resolve download URL for \(item.attributes.name). Skipping.")
                                    logger.error("Resolve download URL failed with error: \(error.localizedDescription, privacy: .public)")
                                    dispatchGroup.leave()
                                }
                            }
                        }
                    }
                case .failure(let error):
                    print("Failed to retrieve folder contents")
                    logger.error("Retrieve folder contents failed with error: \(error.localizedDescription, privacy: .public)")
                }
                
                dispatchGroup.leave()
            }
        } else {
            getFileMetadata(from: megaLink) { result in
                switch result {
                case .success(let downloadMetadata):
                    downloadProgress.totalBytesExpected = downloadMetadata.size
                    let decryptedFileUrl = URL(fileURLWithPath: FileManager().currentDirectoryPath).appendingPathComponent(downloadMetadata.name)
                    
                    DownloadManager.shared.download(url: downloadMetadata.url, name: downloadMetadata.name) { encryptedFileUrl, error in
                        guard let encryptedFileUrl = encryptedFileUrl, error == nil else {
                            // Download error should be handled by the delegate
                            dispatchGroup.leave()
                            return
                        }
                        
                        AESDecryptor.shared.decrypt(encryptedFileUrl: encryptedFileUrl, decryptedFileUrl: decryptedFileUrl, key: downloadMetadata.key) {
                            dispatchGroup.leave()
                        }
                    }
                case .failure(let error):
                    print("Failed to retrieve file metadata")
                    logger.error("Retrieve file metadata failed with error: \(error.localizedDescription, privacy: .public)")
                    dispatchGroup.leave()
                }
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            MegaDL.exit(withError: nil)
        }
        dispatchMain()
        
    }
}

MegaDL.main()
