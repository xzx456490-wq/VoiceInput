import AppKit
import MetalKit
import CoreVideo
import CoreImage

// Shared by the live preview and the real recording view. No screen or audio
// permissions are requested here; the host supplies the background and envelope.
final class SiriMetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private let textureCache: CVMetalTextureCache?
    private var mappedBackground: SiriPixelBufferTexture?
    private lazy var fallbackContext = CIContext(options: [.cacheIntermediates: false])
    private var background: MTLTexture
    private let fallbackBackground: MTLTexture
    private var values = [SIMD4<Float>](repeating: .zero, count: 64)
    private var backdropRect: CGRect?
    private var hasBackdrop = false
    var usesPixelBufferBackground: Bool { mappedBackground != nil }
    private(set) var lastSnapshotGPUTime: Double = 0
    var elapsed: Float = 0
    var progress: Float = 0
    var intro: Float = 0
    var energy: Float = 0
    var glassAmount: Float = 0.19
    var refractionStrength: Float = 24
    var reducedTransparency = false
    // Internal switch for offscreen comparison; live rendering keeps coupling on.
    var lightGlassCoupling: Float = 1
    var exitLightScale: Float = 1
    var lightOpacity: Float = 1
    var opacity: Float = 1
    var presentationScale: Float = 1

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "SiriGlass", code: 1, userInfo: [NSLocalizedDescriptionKey:"Metal 不可用"])
        }
        self.device = device; self.queue = queue; loader = MTKTextureLoader(device: device)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        let url = Bundle.module.url(forResource: "SiriGlass", withExtension: "metal", subdirectory: "Resources")!
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "siriVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "siriFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        textureDescriptor.storageMode = .shared
        background = device.makeTexture(descriptor: textureDescriptor)!
        fallbackBackground = background
        var pixel: [UInt8] = [30, 32, 36, 255]
        pixel.withUnsafeMutableBytes { background.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        set(SiriSlot.u_scaleRatio, 3.8); set(SiriSlot.u_bezelWidth, 58)
        set(SiriSlot.u_glassThickness, 31); set(SiriSlot.u_ior, 3.05)
        set(SiriSlot.u_dispersionScale, 2); set(SiriSlot.u_surfaceCurvature, 8)
        values[SiriSlot.u_glassTint] = SIMD4(0.94, 0.96, 1, 0)
        values[SiriSlot.u_shapeParams] = SIMD4(53, 41, 0.01, 0)
        set(SiriSlot.u_topMorphUp, 4.5)
        set(SiriSlot.u_bottomRimIntensity, 0.50); set(SiriSlot.u_bottomRimWidth, 1.1)
        set(SiriSlot.u_waveRefract, 6.3); set(SiriSlot.u_waveDispersion, 15)
        set(SiriSlot.u_waveEdgeBand, 4.5); set(SiriSlot.u_wavePower, 1.55)
        set(SiriSlot.xScale, 1.6); set(SiriSlot.yScale, 0.11)
        set(SiriSlot.phaseDistance, -4.1); set(SiriSlot.lineThickness, 0.056)
        set(SiriSlot.pinTaper, 2.8); set(SiriSlot.spindleWidth, 2.3)
        set(SiriSlot.glowFalloff, 1.5); set(SiriSlot.glowIntensity, 0.92)
        set(SiriSlot.edgeFade, 0.42); set(SiriSlot.hotCoreThreshold, 7.2)
        set(SiriSlot.hotCoreIntensity, 3.2); set(SiriSlot.fillOpacity, 1)
        set(SiriSlot.activeWaves, 4); set(SiriSlot.u_introStartAmp, 0.2)
        let colors: [SIMD4<Float>] = [SIMD4(0, 47/255, 1, 0), SIMD4(0, 1, 222/255, 0),
            SIMD4(250/255, 31/255, 31/255, 0), SIMD4(1, 147/255, 13/255, 0), SIMD4(0.6, 0, 1, 0), SIMD4(0, 1, 136/255, 0)]
        for i in 0..<6 { values[SiriSlot.color0 + i] = colors[i] }
    }

    private func set(_ slot: Int, _ value: Float) { values[slot].x = value }

    func setBackground(_ image: CGImage?, rect: CGRect? = nil) {
        mappedBackground = nil
        guard let image else {
            hasBackdrop = false; backdropRect = nil; background = fallbackBackground
            if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
            return
        }
        do {
            // Bottom-left orientation preserves the upstream GLSL UV convention.
            background = try loader.newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.bottomLeft])
            backdropRect = rect; hasBackdrop = true
        } catch { hasBackdrop = false; backdropRect = nil; background = fallbackBackground }
    }

    func setBackground(_ frame: CapsuleBackdropFrame, rect: CGRect) {
        if case .pixelBuffer(let buffer) = frame,
           let textureCache, let mapped = SiriPixelBufferTexture(buffer: buffer, cache: textureCache) {
            mappedBackground = mapped; background = mapped.texture
            backdropRect = rect; hasBackdrop = true
        } else {
            // Preserve the existing image path if mapping is unavailable.
            setBackground(frame.image(using: fallbackContext), rect: rect)
        }
    }

    private func prepare(size: CGSize) {
        let scale = Float(min(size.width / 180, size.height / 110))
        values[SiriSlot.u_resolution] = SIMD4(Float(size.width)/scale, Float(size.height)/scale, 0, 0)
        set(SiriSlot.u_time, elapsed * -2.7)
        set(SiriSlot.u_progress, min(1.06, max(0, progress)))
        set(SiriSlot.u_waveFade, min(1, max(0, intro * 2)) * (0.60 + 0.40 * min(1, max(0, energy))) * lightOpacity)
        set(SiriSlot.u_waveIntro, min(1, max(0, (intro - 0.5) / 0.65)))
        set(SiriSlot.audioEnergy, min(1, max(0, energy)))
        set(SiriSlot.lightGlassCoupling, lightGlassCoupling)
        set(SiriSlot.exitLightScale, exitLightScale)
        set(SiriSlot.opacity, opacity)
        set(SiriSlot.presentationScale, min(1, max(0, presentationScale)))
        set(SiriSlot.u_absorption, max(0, glassAmount) * 0.3)
        set(SiriSlot.u_showBackground, reducedTransparency ? 0 : 1 - min(1, max(0, glassAmount)) * 0.55)
        set(SiriSlot.u_scaleRatio, max(0, refractionStrength) / 24 * 3.8)
        let rect = backdropRect ?? CGRect(origin: .zero, size: size)
        // Background rect is in AppKit's bottom-left coordinates of this view.
        values[SiriSlot.u_bgScale] = SIMD4(Float(size.width/rect.width), Float(size.height/rect.height), 0, 0)
        values[SiriSlot.u_bgOffset] = SIMD4(Float(-rect.minX/rect.width), Float(-rect.minY/rect.height), 0, 0)
        if mappedBackground != nil {
            // Stream rows are top-down. Flip sampling coordinates instead of
            // copying/flipping all pixels to the old bottom-left texture layout.
            values[SiriSlot.u_bgScale].y *= -1
            values[SiriSlot.u_bgOffset].y = 1 - values[SiriSlot.u_bgOffset].y
        }
        values[SiriSlot.u_bgNextScale] = values[SiriSlot.u_bgScale]
        values[SiriSlot.u_bgNextOffset] = values[SiriSlot.u_bgOffset]
        set(SiriSlot.u_bgCrossFade, 0)
    }

    private func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, size: CGSize) {
        prepare(size: size)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let retained = mappedBackground {
            // Metal retains the texture, but Core Video also requires its wrapper
            // and pixel buffer to survive GPU completion (including replacement).
            command.addCompletedHandler { [retained] _ in withExtendedLifetime(retained) {} }
        }
        encoder.setRenderPipelineState(pipeline)
        values.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setFragmentTexture(background, index: 0)
        encoder.setFragmentTexture(background, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func draw(in view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        encode(pass: pass, command: command, size: view.bounds.size)
        command.present(drawable); command.commit()
    }

    // Used by visual regression checks; executes the same fragment function as
    // the visible view instead of drawing a separate approximation for previews.
    func snapshot(size: CGSize, scale: CGFloat = 2) throws -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d), let command = queue.makeCommandBuffer() else {
            throw NSError(domain: "SiriGlass", code: 2)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        encode(pass: pass, command: command, size: size)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        lastSnapshotGPUTime = max(0, command.gpuEndTime - command.gpuStartTime)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
