import SwiftUI
import Photos
import ImageIO
import UniformTypeIdentifiers

struct EditRecipe: Codable, Hashable {
    var aspect: CaptureAspect = .standard
    var look = "Original"
    var values: [String: Double] = [:]
    var hue: [Double] = Array(repeating: 0, count: 6)
    var saturation: [Double] = Array(repeating: 0, count: 6)
    var luminance: [Double] = Array(repeating: 0, count: 6)
    var curve: [Double] = [0, 0.25, 0.5, 0.75, 1]
    var frame = "None"
    var dateStamp = false
    subscript(_ key: String) -> Double {
        get { values[key] ?? 0 }
        set { values[key] = newValue }
    }
}

struct LibraryPhoto: Codable, Identifiable, Hashable {
    let id: UUID
    let sourceExtension: String
    let hasRaw: Bool
    var metadata: PhotoMetadata
    var recipe: EditRecipe

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.recipe == rhs.recipe }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(recipe) }
    var directory: URL { PhotoLibraryStore.root.appendingPathComponent(id.uuidString, isDirectory: true) }
    var originalURL: URL { directory.appendingPathComponent("original.\(sourceExtension)") }
    var rawURL: URL { directory.appendingPathComponent("original.dng") }
    var thumbnailURL: URL { directory.appendingPathComponent("thumbnail.jpg") }
}

@MainActor
final class PhotoLibraryStore: ObservableObject {
    @Published private(set) var photos: [LibraryPhoto] = []
    @Published var error: String?
    nonisolated static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StillLibrary", isDirectory: true)

    init() {
        Task {
            let entries = await Task.detached(priority: .utility) {
                let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
                return folders.compactMap { folder -> LibraryPhoto? in
                    guard let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")) else { return nil }
                    return try? JSONDecoder().decode(LibraryPhoto.self, from: data)
                }.sorted { $0.metadata.date > $1.metadata.date }
            }.value
            // Avoid replacing a new capture if initial loading was still in flight.
            let existing = Set(photos.map(\.id))
            photos.append(contentsOf: entries.filter { !existing.contains($0.id) })
            photos.sort { $0.metadata.date > $1.metadata.date }
        }
    }

    func add(_ capture: CapturedPhoto) async throws -> LibraryPhoto {
        var recipe = EditRecipe()
        recipe.aspect = capture.aspect
        let entry = LibraryPhoto(id: capture.id, sourceExtension: capture.processedFileExtension,
            hasRaw: capture.rawData != nil, metadata: capture.metadata, recipe: recipe)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: entry.directory, withIntermediateDirectories: true)
            try capture.processedData.write(to: entry.originalURL, options: .atomic)
            if let raw = capture.rawData { try raw.write(to: entry.rawURL, options: .atomic) }
            try JSONEncoder().encode(entry).write(to: entry.directory.appendingPathComponent("record.json"), options: .atomic)
            if let source = CGImageSourceCreateWithData(capture.processedData as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 320
               ] as CFDictionary), let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) {
                try data.write(to: entry.thumbnailURL, options: .atomic)
            }
        }.value
        photos.insert(entry, at: 0)
        return entry
    }

    func importPhoto(data: Data) async throws -> LibraryPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension else {
            throw LibraryError.invalidImage
        }
        var metadata = PhotoMetadata(lens: "Imported")
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let date = formatter.date(from: text) { metadata.date = date }
            metadata.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double ?? 0
            metadata.exposure = exif[kCGImagePropertyExifExposureTime] as? Double ?? 0
        }
        return try await add(CapturedPhoto(processedData: data, rawData: nil,
            processedFileExtension: ext, metadata: metadata, aspect: .standard))
    }

    func update(_ entry: LibraryPhoto) async throws {
        try await Task.detached(priority: .utility) {
            try JSONEncoder().encode(entry).write(to: entry.directory.appendingPathComponent("record.json"), options: .atomic)
        }.value
        if let index = photos.firstIndex(where: { $0.id == entry.id }) { photos[index] = entry }
    }

    func delete(_ entry: LibraryPhoto) async throws {
        try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: entry.directory) }.value
        photos.removeAll { $0.id == entry.id }
    }
}

enum LibraryError: LocalizedError {
    case invalidImage, permissionDenied, writeFailed
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "This image could not be opened."
        case .permissionDenied: return "Allow Still to add photos in iPhone Settings. Your original is safe in Still."
        case .writeFailed: return "The photo could not be saved. Your original is safe in Still."
        }
    }
}

enum PhotosWriter {
    static func save(data: Data, raw: Data? = nil, date: Date) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw LibraryError.permissionDenied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = date
                if let raw {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "Still.dng"
                    options.uniformTypeIdentifier = UTType(filenameExtension: "dng")?.identifier ?? "com.adobe.raw-image"
                    request.addResource(with: .photo, data: raw, options: options)
                    request.addResource(with: .alternatePhoto, data: data, options: nil)
                } else { request.addResource(with: .photo, data: data, options: nil) }
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: LibraryError.writeFailed) }
            }
        }
    }
}
