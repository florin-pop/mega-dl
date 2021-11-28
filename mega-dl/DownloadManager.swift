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
            self.completionHandler = completion
            
            self.downloadTask = DownloadManager.shared.urlSession.downloadTask(with: url)
            self.downloadTask.resume()
        }
    }
    
    fileprivate lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    public static let shared: DownloadManager = DownloadManager()
    
    weak var delegate: DownloadDelegate?
    var downloadQueue: [DownloadItem] = []
    
    fileprivate func downloadItem(by id: String) -> DownloadItem? {
        return self.downloadQueue.first(where: {$0.id == id})
    }
    
    fileprivate func downloadItem(by downloadTask: URLSessionTask) -> DownloadItem? {
        return self.downloadQueue.first(where: {$0.downloadTask == downloadTask})
    }
    
    func download(url: URL, name: String, completion: ((URL?, Error?) -> Void)?) {
        objc_sync_enter(self.downloadQueue)
        defer { objc_sync_exit(self.downloadQueue) }
        
        let downloadID: String = UUID().uuidString
        self.downloadQueue.append(DownloadItem(id: downloadID, url: url, name: name, completion: completion))
        self.delegate?.downloadManagerDidSchedule(file: name)
    }
    
    func removeDownload(downloadID: String) {
        objc_sync_enter(self.downloadQueue)
        defer { objc_sync_exit(self.downloadQueue) }
        
        self.downloadQueue.removeAll(where: {$0.id == downloadID})
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let downloadItem = DownloadManager.shared.downloadItem(by: downloadTask) else { return }
        
        self.delegate?.downloadManagerDidComplete(file: downloadItem.name, error: nil)
        downloadItem.completionHandler?(location, nil)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let downloadItem = DownloadManager.shared.downloadItem(by: task) else { return }
        
        self.delegate?.downloadManagerDidComplete(file: downloadItem.name, error: error)
        downloadItem.completionHandler?(nil, error)
    }
    
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let downloadItem = DownloadManager.shared.downloadItem(by: downloadTask) else { return }
        
        downloadItem.totalBytesWritten = totalBytesWritten
        downloadItem.totalBytesExpectedToWrite = totalBytesExpectedToWrite
        
        let totalBytesWritten = self.downloadQueue.compactMap { $0.totalBytesWritten }.reduce(0, +)
        
        self.delegate?.downloadManagerDidWrite(bytes: totalBytesWritten)
    }
}

