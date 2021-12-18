//
//  DownloadProgress.swift
//  mega-dl
//
//  Created by Florin Pop on 16.12.21.
//

import Foundation

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
        numberOfTerminalRows = w.ws_row

        sigwinchSrc.setEventHandler {
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
                write("\u{001B}7") // Save cursor position
                write("\u{001B}[0;\(self.numberOfTerminalRows)r") // Drop line reservation
                write("\u{001B}[\(self.numberOfTerminalRows);0f") // Move the cursor to the bottom line
                write("\u{001B}[0K") // Clean that line
                write("\u{001B}8") // Restore the cursor position

                self.numberOfTerminalRows = w.ws_row

                write("\n") // Ensure the last line is available.
                write("\u{001B}7") // Save cursor position
                write("\u{001B}[0;\(w.ws_row - 1)r") // Reserve the bottom line
                write("\u{001B}8") // Restore the cursor position
                write("\u{001B}[1A") // Move up one line
            }
        }
        sigwinchSrc.resume()

        /* Setup */

        write("\n") // Ensure the last line is available.
        write("\u{001B}7") // Save cursor position
        write("\u{001B}[0;\(w.ws_row - 1)r") // Reserve the bottom line
        write("\u{001B}8") // Restore the cursor position
        write("\u{001B}[1A") // Move up one line
    }

    func printProgress() {
        DispatchQueue.main.async {
            write("\u{001B}7") // Save cursor position
            write("\u{001B}[\(self.numberOfTerminalRows)0f") // Move cursor to the bottom margin
            write("\n\u{001B}[0K") // Clean that line
            write("Download progress: \(self.totalBytesDownloaded * 100 / self.totalBytesExpected)% | Decryption progress: \(self.totalBytesDecrypted * 100 / self.totalBytesExpected)%") // Write the progress
            write("\u{001B}8") // Restore cursor position
        }
    }
}

func write(_ s: String) {
    DispatchQueue.main.async {
        print(s, terminator: "")
    }
}
