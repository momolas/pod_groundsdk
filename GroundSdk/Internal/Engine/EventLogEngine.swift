//    Copyright (C) 2020 Parrot Drones SAS
//
//    Redistribution and use in source and binary forms, with or without
//    modification, are permitted provided that the following conditions
//    are met:
//    * Redistributions of source code must retain the above copyright
//      notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above copyright
//      notice, this list of conditions and the following disclaimer in
//      the documentation and/or other materials provided with the
//      distribution.
//    * Neither the name of the Parrot Company nor the names
//      of its contributors may be used to endorse or promote products
//      derived from this software without specific prior written
//      permission.
//
//    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
//    PARROT COMPANY BE LIABLE FOR ANY DIRECT, INDIRECT,
//    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
//    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
//    OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
//    AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
//    OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
//    SUCH DAMAGE.

import Foundation

/// Engine managing the application/sdk event logger.
class EventLogEngine: EngineBaseCore {
    /// Event logger facility for which this engine is the backend
    private var eventLoggerFacility: EventLoggerCore!

    /// Name of the directory in which the event logs should be stored
    private let eventLogLocalDirName = "eventLog"

    /// Internal logger
    private let logger: SdkCoreEventLogger

    /// Flight log storage utility
    private var flightLogStorage: FlightLogStorageCore!

    /// Folder monitor
    private var folderMonitor: FolderMonitor!

    /// Background timestamp
    private var backgroundTimeStamp: Double?

    /// Constructor.
    ///
    /// - Parameter enginesController: engines controller
    public required init(enginesController: EnginesControllerCore) {
        ULog.d(.eventLogEngineTag, "Loading EventLogEngine.")

        logger = SdkCoreEventLogger()

        super.init(enginesController: enginesController)

        eventLoggerFacility = EventLoggerCore(store: enginesController.facilityStore, backend: self)
        publishUtility(EventLogUtilityCoreImpl(engine: self))
    }

    override func startEngine() {
        ULog.d(.eventLogEngineTag, "Starting EventLogEngine.")

        let properties: Dictionary = [
            "app.sessionid": UUID().uuidString,
            "phone.os": UIDevice.current.systemName,
            "phone.os_version": UIDevice.current.systemVersion,
            "phone.manufacturer": "Apple",
            "phone.model": UIDevice.identifier,
            "ro.parrot.build.product": AppInfoCore.appBundle,
            "ro.parrot.build.version": AppInfoCore.appVersion,
            "ro.parrot.gsdk.product": AppInfoCore.sdkBundle,
            "ro.parrot.gsdk.version": AppInfoCore.sdkVersion
        ]

        // EventLogEngine is only enabled if FlightLogEngine is enabled
        flightLogStorage = utilities.getUtility(Utilities.flightLogStorage)
        let workDir = flightLogStorage.workDir
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: nil)
        } catch let err {
            ULog.e(.eventLogEngineTag, "Failed to create folder at \(workDir.path): \(err)")
        }

        folderMonitor = FolderMonitor(url: workDir, handler: handleNewFile)
        folderMonitor.startMonitoring()

        logger.start(workDir.path, properties: properties)
        let notificationCenter = NotificationCenter.default
        if #available(iOS 13.0, *) {
            notificationCenter.addObserver(
                self, selector: #selector(appMovedToBackground),
                name: UIScene.didEnterBackgroundNotification, object: nil)
            notificationCenter.addObserver(
                self, selector: #selector(appMovedToForeground),
                name: UIScene.willEnterForegroundNotification, object: nil)
        } else {
            notificationCenter.addObserver(
                self, selector: #selector(appMovedToBackground),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            notificationCenter.addObserver(
                self, selector: #selector(appMovedToForeground),
                name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        eventLoggerFacility.publish()
    }

    override func stopEngine() {
        ULog.d(.eventLogEngineTag, "Stopping EventLogEngine.")

        eventLoggerFacility.unpublish()
        logger.stop()
        folderMonitor.stopMonitoring()
        let notificationCenter = NotificationCenter.default
        if #available(iOS 13.0, *) {
            notificationCenter.removeObserver(self, name: UIScene.didEnterBackgroundNotification, object: nil)
            notificationCenter.removeObserver(self, name: UIScene.willEnterForegroundNotification, object: nil)
        } else {
            notificationCenter.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
            notificationCenter.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        }
    }

    /// Updates drone boot id in event log file.
    ///
    /// - Parameter bootId: new drone boot id
    func update(bootId: String) {
        logger.log("PROP:app.drone.bootid=\(bootId)")
    }

    /// Closes current event log session and starts a new one, creating a new log file.
    func newSession() {
        logger.newSession()
    }

    /// Handles new file detected in work directory.
    ///
    /// - Parameter file: new file
    private func handleNewFile(file: URL) {
        if file.lastPathComponent.range(of: "log-\\d+.bin", options: .regularExpression) != nil {
            flightLogStorage?.notifyFlightLogReady(flightLogUrl: file.resolvingSymlinksInPath())
        }
    }

    @objc private func appMovedToBackground() {
        backgroundTimeStamp = NSDate().timeIntervalSince1970
    }

    @objc private func appMovedToForeground() {
        if let backgroundTimeStamp = backgroundTimeStamp,
           NSDate().timeIntervalSince1970 - backgroundTimeStamp > 300 {
            self.logger.newSession()
        }
        backgroundTimeStamp = nil
    }
}

/// Extension of the engine that implements the EventLogger backend
extension EventLogEngine: EventLoggerBackend {
    func log(_ message: String) {
        logger.log(message)
    }
}

/// Utility class monitoring a folder for new files.
private class FolderMonitor {
    /// URL for the directory being monitored
    private let url: URL

    /// Handler called when a new file is detected
    private let onNewFile: ((URL) -> Void)

    /// File descriptor for the monitored directory
    private var fileDescriptor: CInt = -1

    /// Dispatch source monitoring the directory
    private var dispatchSource: DispatchSourceFileSystemObject?

    /// Dispatch queue used for sending file changes in the directory
    private let dispatchQueue = DispatchQueue(label: "FolderMonitorQueue", attributes: .concurrent)

    /// List of file paths in the monitored folder
    private var folderContent: [URL]?

    /// Constructor.
    ///
    /// - Parameters:
    ///   - url: URL of the directory to monitor
    ///   - handler: handler called when a new file is detected
    init(url: URL, handler: @escaping (URL) -> Void) {
        self.url = url
        self.onNewFile = handler
    }

    /// Starts listening for changes to the directory.
    func startMonitoring() {
        guard fileDescriptor == -1 && dispatchSource == nil else {
            return
        }

        fileDescriptor = open(url.path, O_EVTONLY)
        dispatchSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor,
                                                                   eventMask: .write, queue: dispatchQueue)
        dispatchSource?.setEventHandler { [weak self] in
            if let self = self,
                let files = try? FileManager.default.contentsOfDirectory(
                    at: self.url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                var newFile: URL?
                for file in files {
                    if !(self.folderContent?.contains(file) ?? false) {
                        newFile = file
                        break
                    }
                }
                self.folderContent = files
                if let newFile = newFile {
                    self.onNewFile(newFile)
                }
            }
        }

        dispatchSource?.setCancelHandler { [weak self] in
            guard let strongSelf = self else { return }
            close(strongSelf.fileDescriptor)
            strongSelf.fileDescriptor = -1
            strongSelf.dispatchSource = nil
        }

        dispatchSource?.resume()
    }

    /// Stops listening for changes to the directory, if the source has been created.
    func stopMonitoring() {
        dispatchSource?.cancel()
    }
}
