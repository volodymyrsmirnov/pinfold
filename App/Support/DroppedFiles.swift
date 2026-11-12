import Foundation
import UniformTypeIdentifiers

/// Filtering and staging for files dragged onto the window (C8).
///
/// A drop provider's file URL is only valid inside its completion handler, so each supported
/// file is copied to a temporary location that outlives the handler before it is queued for
/// import. The pure parts (`accepts`, `stage`) are unit-tested; `load` adapts providers.
enum DroppedFiles {
    /// Whether the file's extension is one Pinfold imports (`ImportFormats.originalExtensions`).
    static func accepts(_ url: URL) -> Bool {
        ImportFormats.originalExtensions.contains(url.pathExtension.lowercased())
    }

    /// Copies the supported files among `urls` into a fresh subfolder of `directory`, keeping
    /// each file name, and returns the copies. Unsupported files and failed copies are dropped.
    static func stage(_ urls: [URL], into directory: URL) -> [URL] {
        var staged: [URL] = []
        for url in urls where accepts(url) {
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let target = folder.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
                staged.append(target)
            } catch {
                continue
            }
        }
        return staged
    }

    /// The temporary folder dropped files are staged in.
    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DroppedFiles", isDirectory: true)
    }

    /// Resolves every provider to a staged copy of its supported file, in drop order.
    @MainActor static func load(_ providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for provider in providers {
            result += await loadOne(provider)
        }
        return result
    }

    @MainActor private static func loadOne(_ provider: NSItemProvider) async -> [URL] {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                // The URL is only valid inside this handler: stage the copy before returning.
                guard let url else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: stage([url], into: stagingDirectory))
            }
        }
    }
}
