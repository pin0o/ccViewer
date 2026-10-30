import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import RemoteCloud

public enum FileThumbnailGenerator {
    public static func generate(item: RemoteItem, video: Bool, maximumPixels: Int) async throws -> CGImage {
        let session = try await item.openThumbnail(maximumBytes: (video ? 16 : 24) * 1024 * 1024)
        return try await withTaskCancellationHandler {
            do {
                let result = try await Task.detached(priority: .utility) {
                    let ext = (item.ext.isEmpty ? (item.name as NSString).pathExtension : item.ext).lowercased()
                    if video {
                        if ext == "ts" {
                            let header = try await session.read(position: 0, length: 564)
                            guard header.count == 564, header[0] == 0x47, header[188] == 0x47, header[376] == 0x47 else {
                                if !header.contains(0), String(data: header, encoding: .utf8) != nil { throw ThumbnailReadError.textFile }
                                throw ThumbnailReadError.unsupported
                            }
                        }
                        do {
                            return try await videoImage(session: session, ext: ext, maximumPixels: maximumPixels)
                        } catch {
                            try session.check()
                            let code = (error as NSError).code
                            guard (error as NSError).domain == AVFoundationErrorDomain,
                                  [AVError.Code.fileFormatNotRecognized.rawValue,
                                   AVError.Code.decoderNotFound.rawValue,
                                   AVError.Code.decodeFailed.rawValue].contains(code) else { throw error }
                            return try await ffmpegImage(session: session, maximumPixels: maximumPixels)
                        }
                    }
                    guard item.size > 0, item.size <= 20 * 1024 * 1024 else { throw ThumbnailReadError.limitExceeded }
                    let data = try await session.read(position: 0, length: Int(item.size))
                    guard data.count == item.size,
                          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                        throw ThumbnailReadError.invalidData
                    }
                    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                       let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                       width.doubleValue * height.doubleValue > 64 * 1024 * 1024 {
                        throw ThumbnailReadError.limitExceeded
                    }
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { throw ThumbnailReadError.invalidData }
                    try session.check()
                    return image
                }.value
                try session.check()
                await session.close()
                return result
            } catch {
                await session.close()
                throw error
            }
        } onCancel: { session.cancel() }
    }

    private static func videoImage(session: ThumbnailReadSession, ext: String, maximumPixels: Int) async throws -> CGImage {
        let loader = ThumbnailAssetLoader(session: session, ext: ext)
        // Opaque token avoids encoding storage names or file IDs into URL components.
        let asset = AVURLAsset(url: URL(string: "thumbnail-stream://asset/\(UUID().uuidString)")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: CGFloat(maximumPixels), height: CGFloat(maximumPixels))
        generator.appliesPreferredTrackTransform = true
        let cancellation = session.onCancel {
            generator.cancelAllCGImageGeneration()
            loader.cancel()
        }
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(session.timeRemaining))
                session.cancel()
                generator.cancelAllCGImageGeneration()
                loader.cancel()
            } catch { }
        }
        defer {
            session.removeCancellationHandler(cancellation)
            timeout.cancel(); generator.cancelAllCGImageGeneration(); loader.cancel()
        }
        return try await withTaskCancellationHandler {
            do { return try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image }
            catch {
                try session.check()
                guard (error as NSError).domain == AVFoundationErrorDomain,
                      (error as NSError).code == AVError.Code.noImageAtTime.rawValue else { throw error }
                return try await generator.image(at: .zero).image
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
            loader.cancel()
        }
    }

    private static func ffmpegImage(session: ThumbnailReadSession, maximumPixels: Int) async throws -> CGImage {
        let bridge = ThumbnailFFmpegInput(session: session)
        return try await Task.detached(priority: .utility) {
            var pixels: UnsafeMutablePointer<UInt8>?
            var width: Int32 = 0, height: Int32 = 0
            var rotation = 0.0
            let status = thumbnail_extract(Unmanaged.passUnretained(bridge).toOpaque(), ThumbnailFFmpegInput.read,
                ThumbnailFFmpegInput.seek, ThumbnailFFmpegInput.interrupted, Int32(maximumPixels), &pixels, &width, &height, &rotation)
            defer { thumbnail_free(pixels) }
            try session.check()
            guard status == 0, let pixels, width > 0, height > 0 else { throw ThumbnailReadError.unsupported }
            let data = Data(bytes: pixels, count: Int(width * height * 4))
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: Int(width * 4), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ThumbnailReadError.invalidData }
            guard rotation.isFinite else { return image }
            let angle = Int(rotation.rounded()) % 360
            guard angle != 0 else { return image }
            let swap = abs(angle) == 90 || abs(angle) == 270
            let w = swap ? image.height : image.width, h = swap ? image.width : image.height
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
            context.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            context.rotate(by: CGFloat(rotation) * .pi / 180)
            context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width), height: CGFloat(image.height)))
            return context.makeImage() ?? image
        }.value
    }
}

private final class ThumbnailAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "thumbnail.asset-loader")
    let session: ThumbnailReadSession
    let ext: String
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(session: ThumbnailReadSession, ext: String) { self.session = session; self.ext = ext }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(request)
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        tasks[id] = Task { [self] in
            defer { remove(id) }
            do {
                try session.check()
                if let info = request.contentInformationRequest {
                    info.contentLength = session.size
                    info.isByteRangeAccessSupported = true
                    info.contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier
                }
                if let dataRequest = request.dataRequest {
                    var offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
                    guard offset >= 0, offset <= session.size else { throw ThumbnailReadError.invalidData }
                    let length = dataRequest.requestsAllDataToEndOfResource ? session.size - offset :
                        max(0, Int64(dataRequest.requestedLength) - (offset - dataRequest.requestedOffset))
                    let end = offset + min(length, session.size - offset)
                    while offset < end {
                        try Task.checkCancellation()
                        guard !request.isCancelled, !isStopped() else { throw CancellationError() }
                        let data = try await session.read(position: offset, length: Int(min(256 * 1024, end - offset)))
                        guard !data.isEmpty else { throw ThumbnailReadError.invalidData }
                        guard !request.isCancelled, !isStopped(), !Task.isCancelled else { throw CancellationError() }
                        dataRequest.respond(with: data)
                        offset += Int64(data.count)
                    }
                }
                if !request.isCancelled { request.finishLoading() }
            } catch {
                if !request.isCancelled { request.finishLoading(with: error) }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        // The stream is shared by the asset's range requests. Allow an in-flight read
        // to finish; cancelling its Task can put a crypto/slot stream into an error state.
        // request.isCancelled prevents any response or further reads for this request.
    }
    private func remove(_ id: ObjectIdentifier) { lock.lock(); tasks.removeValue(forKey: id); lock.unlock() }
    private func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() {
        lock.lock(); stopped = true; tasks.removeAll(); lock.unlock()
    }
}

private final class ThumbnailFFmpegInput: @unchecked Sendable {
    let session: ThumbnailReadSession
    var position: Int64 = 0 // Only accessed by the single C decoder worker.
    init(session: ThumbnailReadSession) { self.session = session }
    static let interrupted: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
        guard let pointer else { return 1 }
        let input = Unmanaged<ThumbnailFFmpegInput>.fromOpaque(pointer).takeUnretainedValue()
        return (try? input.session.check()) == nil ? 1 : 0
    }
    static let seek: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { pointer, offset, whence in
        guard let pointer else { return -1 }
        let input = Unmanaged<ThumbnailFFmpegInput>.fromOpaque(pointer).takeUnretainedValue()
        if whence & 0x10000 != 0 { return input.session.size }
        let base: Int64
        switch whence & ~0x20000 {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = input.position
        case SEEK_END: base = input.session.size
        default: return -1
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0, target <= input.session.size else { return -1 }
        input.position = target
        return target
    }
    static let read: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { pointer, buffer, count in
        guard let pointer, let buffer, count > 0 else { return averror_exit }
        let input = Unmanaged<ThumbnailFFmpegInput>.fromOpaque(pointer).takeUnretainedValue()
        if input.position >= input.session.size { return averror_eof }
        let result = ThumbnailReadResult()
        let done = DispatchSemaphore(value: 0)
        let position = input.position
        Task.detached(priority: .utility) {
            result.data = try? await input.session.read(position: position, length: Int(count))
            done.signal()
        }
        done.wait()
        guard let data = result.data, !data.isEmpty else { return averror_exit }
        data.copyBytes(to: buffer, count: data.count)
        input.position += Int64(data.count)
        return Int32(data.count)
    }
}
private final class ThumbnailReadResult: @unchecked Sendable { var data: Data? }
