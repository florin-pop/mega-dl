//
//  DownloadProgress.swift
//  mega-dl
//
//  Created by Florin Pop on 16.12.21.
//

import Foundation

class DownloadProgress {
    var downloadSpeed: Int64 = 0
    var lastMeasurement: Int64 = 0
    var totalBytesExpected: Int64 = 0
    var totalBytesDownloaded: Int64 = 0

    var totalBytesDecrypted: Int64 = 0
    var numberOfTerminalRows: UInt16 = 0

    init() {
        var w = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_row > 0 else {
            return
        }

        numberOfTerminalRows = w.ws_row
        reserveBottomLine(totalNumerOfRows: w.ws_row)
    }

    func reserveBottomLine(totalNumerOfRows: UInt16) {
        // Inspired by https://mdk.fr/blog/how-apt-does-its-fancy-progress-bar.html
        write("\n") // Ensure the last line is available.
        write("\u{001B}7") // Save cursor position
        write("\u{001B}[0;\(totalNumerOfRows - 1)r") // Reserve the bottom line
        write("\u{001B}8") // Restore the cursor position
        write("\u{001B}[1A") // Move up one line
    }

    func cleanup() {
        write("\u{001B}7") // Save cursor position
        write("\u{001B}[0;\(numberOfTerminalRows)r") // Drop line reservation
        write("\u{001B}[\(numberOfTerminalRows);0f") // Move the cursor to the bottom line
        write("\u{001B}[0K") // Clean that line
        write("\u{001B}8") // Restore the cursor position
    }

    func reset() {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            cleanup()
            numberOfTerminalRows = w.ws_row
            reserveBottomLine(totalNumerOfRows: w.ws_row)
        }
    }

    func printProgress() {
        DispatchQueue.main.async {
            let byteCountFormatter = ByteCountFormatter()
            byteCountFormatter.allowedUnits = [.useAll]
            byteCountFormatter.countStyle = .file
            let humanReadableDownloadSpeed = byteCountFormatter.string(fromByteCount: Int64(self.downloadSpeed))

            write("\u{001B}7") // Save cursor position
            write("\u{001B}[\(self.numberOfTerminalRows)0f") // Move cursor to the bottom margin
            write("\n\u{001B}[0K") // Clean that line
            // Write the progress
            if self.totalBytesDownloaded < self.totalBytesExpected {
                write("Download Size: \(byteCountFormatter.string(fromByteCount: Int64(self.totalBytesExpected))) | Progress: \(self.totalBytesDownloaded * 100 / self.totalBytesExpected)% | Speed: \(humanReadableDownloadSpeed)/s | Decryption Progress: \(self.totalBytesDecrypted * 100 / self.totalBytesExpected)%")
            } else {
                write("Download Finished | Decryption Progress: \(self.totalBytesDecrypted * 100 / self.totalBytesExpected)%")
            }
            write("\u{001B}8") // Restore cursor position
        }
    }
}

func write(_ s: String) {
    DispatchQueue.main.async {
        print(s, terminator: "")
    }
}
