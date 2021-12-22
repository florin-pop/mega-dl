//
//  DownloadManager.swift
//  mega-dl
//
//  Created by Florin Pop on 22.07.21.
//

import Foundation

protocol DownloadDelegate: AnyObject {
    func downloadManagerDidSchedule(file: String)
    func downloadManagerDidWrite(bytes: Int64)
    func downloadManagerDidComplete(file: String, error: Error?)
}

enum DownloadError: Error {
    case statusCodeError(Int)
}

class DownloadManager: NSObject {
    class DownloadItem {
        var totalBytesWritten: Int64 = 0
        var totalBytesExpectedToWrite: Int64 = 0
        var completionHandler: ((URL?, Error?) -> Void)?

        let id: String
        let name: String
        let url: URL

        fileprivate var downloadTask: URLSessionDownloadTask!

        fileprivate init(id: String, url: URL, name: String, completion: ((URL?, Error?) -> Void)?) {
            self.id = id
            self.url = url
            self.name = name
            completionHandler = completion

            downloadTask = DownloadManager.shared.urlSession.downloadTask(with: url)
            downloadTask.resume()
        }
    }

    fileprivate lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public static let shared: DownloadManager = .init()

    weak var delegate: DownloadDelegate?
    var downloadQueue: [DownloadItem] = []

    fileprivate func downloadItem(by id: String) -> DownloadItem? {
        downloadQueue.first(where: { $0.id == id })
    }

    fileprivate func downloadItem(by downloadTask: URLSessionTask) -> DownloadItem? {
        downloadQueue.first(where: { $0.downloadTask == downloadTask })
    }

    func download(url: URL, name: String, completion: ((URL?, Error?) -> Void)?) {
        objc_sync_enter(downloadQueue)
        defer { objc_sync_exit(self.downloadQueue) }

        let downloadID: String = UUID().uuidString
        downloadQueue.append(DownloadItem(id: downloadID, url: url, name: name, completion: completion))
        delegate?.downloadManagerDidSchedule(file: name)
    }

    func removeDownload(downloadID: String) {
        objc_sync_enter(downloadQueue)
        defer { objc_sync_exit(self.downloadQueue) }

        downloadQueue.removeAll(where: { $0.id == downloadID })
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let downloadItem = DownloadManager.shared.downloadItem(by: downloadTask) else { return }

        let error: Error?

        if let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(statusCode) {
            error = DownloadError.statusCodeError(statusCode)
        } else {
            error = nil
        }

        delegate?.downloadManagerDidComplete(file: downloadItem.name, error: error)
        downloadItem.completionHandler?(location, error)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let downloadItem = DownloadManager.shared.downloadItem(by: task) else { return }

        delegate?.downloadManagerDidComplete(file: downloadItem.name, error: error)
        downloadItem.completionHandler?(nil, error)
    }

    func urlSession(_: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64)
    {
        guard let downloadItem = DownloadManager.shared.downloadItem(by: downloadTask) else { return }

        downloadItem.totalBytesWritten = totalBytesWritten
        downloadItem.totalBytesExpectedToWrite = totalBytesExpectedToWrite

        let totalBytesWritten = downloadQueue.map(\.totalBytesWritten).reduce(0, +)

        delegate?.downloadManagerDidWrite(bytes: totalBytesWritten)
    }
}
