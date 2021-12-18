//
//  DownloadProgress.swift
//  mega-dl
//
//  Created by Florin Pop on 16.12.21.
//

import Foundation

class DownloadProgress {
    var downloadSpeedTimer: Timer!
    var downloadSpeed: Int64 = 0
    var lastMeasurement: Int64 = 0
    var totalBytesExpected: Int64 = 0
    var totalBytesDownloaded: Int64 = 0

    var totalBytesDecrypted: Int64 = 0
    var numberOfTerminalRows: UInt16 = 0
    let sigwinchSrc: DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)

    init() {
        DispatchQueue.global(qos: .background).async {
            self.downloadSpeedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                if self.lastMeasurement < self.totalBytesDownloaded {
                    self.downloadSpeed = self.totalBytesDownloaded - self.lastMeasurement
                } else {
                    self.downloadSpeed = 0
                }
                self.lastMeasurement = self.totalBytesDownloaded
            }
            let runLoop = RunLoop.current
            runLoop.add(self.downloadSpeedTimer, forMode: .default)
            runLoop.run()
        }

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
            let byteCountFormatter = ByteCountFormatter()
            byteCountFormatter.allowedUnits = [.useAll]
            byteCountFormatter.countStyle = .file
            let humanReadableDownloadSpeed = byteCountFormatter.string(fromByteCount: Int64(self.downloadSpeed))

            write("\u{001B}7") // Save cursor position
            write("\u{001B}[\(self.numberOfTerminalRows)0f") // Move cursor to the bottom margin
            write("\n\u{001B}[0K") // Clean that line
            write("Download progress: \(self.totalBytesDownloaded * 100 / self.totalBytesExpected)% \(humanReadableDownloadSpeed)/s | Decryption progress: \(self.totalBytesDecrypted * 100 / self.totalBytesExpected)%") // Write the progress
            write("\u{001B}8") // Restore cursor position
        }
    }
}

func write(_ s: String) {
    DispatchQueue.main.async {
        print(s, terminator: "")
    }
}
