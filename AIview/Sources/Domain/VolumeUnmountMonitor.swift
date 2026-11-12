import AppKit
import os

/// ボリュームの unmount（NAS の切断、外付けディスクの取り外しを含む）を window 単位で受け取る。
///
/// `NSWorkspace` の通知は process 全体で共有されるが、どのフォルダを開いているかは window ごとに
/// 違うため、各 `BrowserWindowSession` が 1 つずつ所有し、scene close の `stop()` で解除する。
/// will / did の両方を購読する（will の時点で読み込みを止めると、開いている file handle が
/// unmount を妨げない）。受け手は二重通知を冪等に扱うこと。
@MainActor
final class VolumeUnmountMonitor {
    typealias Handler = @MainActor @Sendable (URL) -> Void

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    var isRunning: Bool { !observers.isEmpty }

    func start(handler: @escaping Handler) {
        guard observers.isEmpty else { return }
        let names = [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                    return
                }
                MainActor.assumeIsolated {
                    handler(volumeURL)
                }
            }
        }
    }

    func stop() {
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
    }
}
