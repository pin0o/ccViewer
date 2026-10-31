#if targetEnvironment(simulator)
import Foundation
import RemoteCloud

/// Opt-in navigation and readiness signals for CI screenshots of real app views.
enum SimulatorSnapshotSupport {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--snapshot-local-files") }
    private static var opened = false

    private static var readyURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ui-snapshot-ready")
    }

    static func openLocalFiles(in env: UserEnvObject) async {
        guard enabled, !opened else { return }
        for _ in 0..<200 {
            if CloudFactory.shared.initialized { break }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard CloudFactory.shared.initialized, !Task.isCancelled else { return }
        opened = true
        env.path = [.items(storage: "Local", fileid: "")]
    }

    static func markReady() {
        guard enabled else { return }
        let state = "\(FileBrowserSettings.shared.layout.rawValue):\(FileBrowserSettings.shared.gridSize.rawValue)"
        try? FileManager.default.createDirectory(at: readyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? state.write(to: readyURL, atomically: true, encoding: .utf8)
    }
}
#endif
