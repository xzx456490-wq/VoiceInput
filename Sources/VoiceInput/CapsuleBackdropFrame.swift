import AppKit
import CoreImage
import CoreVideo
import Metal

// Capture pixels stay in their IOSurface until the renderer has finished using
// them. Ordinary images remain supported for the first-frame/fallback paths.
enum CapsuleBackdropFrame {
    case image(CGImage)
    case pixelBuffer(CVPixelBuffer)

    func image(using context: CIContext) -> CGImage? {
        switch self {
        case .image(let image): return image
        case .pixelBuffer(let buffer):
            let image = CIImage(cvPixelBuffer: buffer)
            return context.createCGImage(image, from: image.extent)
        }
    }
}

final class SiriPixelBufferTexture {
    let pixelBuffer: CVPixelBuffer
    let metalTexture: CVMetalTexture
    let texture: MTLTexture

    init?(buffer: CVPixelBuffer, cache: CVMetalTextureCache) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var mapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer,
            nil, .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &mapped)
        guard status == kCVReturnSuccess, let mapped, let texture = CVMetalTextureGetTexture(mapped) else { return nil }
        pixelBuffer = buffer; metalTexture = mapped; self.texture = texture
    }
}

// A stalled main thread retains at most the newest capture, rather than queuing
// a conversion/upload for every stale frame. All state is protected by the lock.
final class LatestBackdropMailbox<Element> {
    private let lock = NSLock()
    private var pending: Element?
    private var scheduled = false
    func offer(_ value: Element) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending = value
        if scheduled { return false }
        scheduled = true
        return true
    }
    func take() -> Element? {
        lock.lock(); defer { lock.unlock() }
        let value = pending; pending = nil; scheduled = false
        return value
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
        // A delivery already queued on main must still drain/reset the mailbox.
    }
}
