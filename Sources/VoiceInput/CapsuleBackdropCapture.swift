import AppKit
import CoreVideo
import ScreenCaptureKit
import QuartzCore
import OSLog

// Only visible overlays request pixels. Frames remain in memory; no audio,
// file output or network output is used. Own-app exclusion is cached so a
// transient window-list result cannot disable an entire later recording.
final class CapsuleBackdropCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CapsuleBackdropFrame, CGRect) -> Void)?
    var onStop: (() -> Void)?
    private let queue = DispatchQueue(label: "VoiceInput.glass.backdrop", qos: .userInitiated)
    private let mailbox = LatestBackdropMailbox<(SCStream, CVPixelBuffer)>()
    private let log = Logger(subsystem: "com.yetone.VoiceInput", category: "GlassCapture")
    private var stream: SCStream?
    private var generation = UUID()
    private var captureRect = CGRect.zero
    private var displayID: CGDirectDisplayID?
    private var starting = false
    private var filterCache: (id: CGDirectDisplayID, filter: SCContentFilter)?
    private var activeFilter: SCContentFilter?
    private var activeConfiguration: SCStreamConfiguration?
    private var bootstrapTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var firstFrameWatchdog: Task<Void, Never>?
    private var receivedAnyFrame = false
    private var startedAt: CFTimeInterval = 0

    func start(screen: NSScreen, region: CGRect) {
        guard CGPreflightScreenCaptureAccess(),
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            stop(); return
        }
        let rect = region.intersection(screen.frame)
        guard !rect.isEmpty else { stop(); return }
        if displayID == id, captureRect == rect, starting || stream != nil || fallbackTask != nil { return }
        stop()
        captureRect = rect; displayID = id; starting = true
        receivedAnyFrame = false; startedAt = CACurrentMediaTime()
        let token = generation
        let sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let filter: SCContentFilter
                if let cached = self.filterCache, cached.id == id {
                    filter = cached.filter
                } else {
                    // Include offscreen windows: this menu-bar app's newly
                    // ordered panel may not yet appear in the onscreen list.
                    var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard self.generation == token else { return }
                    let pid = ProcessInfo.processInfo.processIdentifier
                    if !content.applications.contains(where: { $0.processID == pid }) {
                        try await Task.sleep(nanoseconds: 80_000_000)
                        guard self.generation == token else { return }
                        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    }
                    guard self.generation == token else { return }
                    guard let display = content.displays.first(where: { $0.displayID == id }),
                          let ownApp = content.applications.first(where: { $0.processID == pid }) else {
                        self.log.error("Background preparation unavailable; no pixels requested without own-app exclusion")
                        self.stop(); return
                    }
                    filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
                    self.filterCache = (id, filter)
                }
                guard self.generation == token else { return }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = sourceRect
                configuration.width = Int((rect.width * scale).rounded())
                configuration.height = Int((rect.height * scale).rounded())
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.capturesAudio = false
                self.activeFilter = filter; self.activeConfiguration = configuration
                // Fetch one fresh frame without waiting for stream startup.
                // A late bootstrap must never replace an already delivered frame.
                self.bootstrapTask = Task { @MainActor [weak self] in
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    if let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                       self.generation == token, !self.receivedAnyFrame, !Task.isCancelled {
                        self.deliver(.image(frame))
                    }
                }
                let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = newStream
                try await newStream.startCapture()
                guard self.generation == token else { try? await newStream.stopCapture(); return }
                self.starting = false
                // A successfully started stream may still deliver no usable
                // frame. Do not leave the complete recording on old material.
                self.firstFrameWatchdog = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self, self.generation == token, !Task.isCancelled,
                          !self.receivedAnyFrame else { return }
                    self.log.notice("No first background frame; switching to filtered frame refresh")
                    self.beginFallback(token: token)
                }
            } catch {
                guard self.generation == token else { return }
                self.log.error("Live background startup failed: \(error.localizedDescription, privacy: .public)")
                self.beginFallback(token: token)
            }
        }
    }

    private func deliver(_ frame: CapsuleBackdropFrame) {
        if !receivedAnyFrame {
            receivedAnyFrame = true
            let elapsed = Int((CACurrentMediaTime() - startedAt) * 1000)
            log.notice("Glass background ready after \(elapsed, privacy: .public) ms")
        }
        onFrame?(frame, captureRect)
    }

    // Stream setup can fail transiently even with valid permission. Keep the
    // same filtered, current background alive through single-frame requests.
    // This fallback ends on hide, revoked permission, or two consecutive errors.
    private func beginFallback(token: UUID) {
        guard generation == token, fallbackTask == nil,
              let filter = activeFilter, let configuration = activeConfiguration else { stop(); return }
        let previous = stream; stream = nil; starting = false
        filterCache = nil
        if let previous { Task { try? await previous.stopCapture() } }
        fallbackTask = Task { @MainActor [weak self] in
            var failures = 0
            while let self, self.generation == token, !Task.isCancelled {
                guard CGPreflightScreenCaptureAccess() else { self.stop(); return }
                do {
                    let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    guard self.generation == token, !Task.isCancelled else { return }
                    failures = 0
                    self.deliver(.image(frame))
                } catch {
                    guard self.generation == token else { return }
                    failures += 1
                    if failures >= 2 {
                        self.log.error("Background frame fallback unavailable; capture stopped")
                        self.stop(); return
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stop() {
        mailbox.clear()
        generation = UUID(); starting = false; displayID = nil; captureRect = .zero
        bootstrapTask?.cancel(); bootstrapTask = nil
        fallbackTask?.cancel(); fallbackTask = nil
        firstFrameWatchdog?.cancel(); firstFrameWatchdog = nil
        activeFilter = nil; activeConfiguration = nil
        let previous = stream; stream = nil
        onStop?()
        if let previous { Task { try? await previous.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        guard mailbox.offer((stream, buffer)) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let (source, buffer) = self.mailbox.take(), self.stream === source else { return }
            self.deliver(.pixelBuffer(buffer))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.log.error("Live background interrupted: \(error.localizedDescription, privacy: .public)")
            self.beginFallback(token: self.generation)
        }
    }
}
