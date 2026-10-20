import Foundation
import OSLog
import UIKit

final class CameraDiagnostics {
    static let shared = CameraDiagnostics()
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.example.stillcamera", category: "Camera")
    private var events: [String] = []
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Still-camera-diagnostics.txt")

    private init() {
        if let text = try? String(contentsOf: file, encoding: .utf8) { events = Array(text.components(separatedBy: "\n").suffix(80)) }
    }

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let entry = "\(ISO8601DateFormatter().string(from: Date()))  \(message)"
        events.append(entry)
        if events.count > 100 { events.removeFirst(events.count - 100) }
        logger.info("\(message, privacy: .public)")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? events.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Still \(version) (\(build))\niOS \(UIDevice.current.systemVersion)\n\n" + events.joined(separator: "\n")
    }
}
