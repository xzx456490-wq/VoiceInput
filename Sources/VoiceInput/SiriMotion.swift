import Foundation
struct SiriMotion {
    private(set) var progress: Double = 0
    private(set) var velocity: Double = 0
    private(set) var energy: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var intro: Double = 0
    private(set) var recording = false
    private(set) var presentationScale: Double = 0
    private var targetEnergy: Double = 0
    private var exitElapsed: Double?
    private var exitStartProgress: Double = 0
    private var exitStartScale: Double = 0
    private var exitStartIntro: Double = 0
    private var exitStartLightOpacity: Double = 0
    private var exitDuration: Double = 0
    private var exitScaleStart: Double = 0
    private(set) var exitLightScale: Double = 1
    private(set) var lightOpacity: Double = 0
    private(set) var opacity: Double = 1
    // Overlap size and shape changes so neither handoff pauses the visible contour.
    private static let entranceScaleDuration = 0.32
    private static let expansionStart = 0.10
    private static let expansionDuration = 0.38
    private static let collapseTravel = 0.36
    private static let exitScaleOverlapStart = 0.16
    private static let exitScaleDuration = 0.38
    private static func ease(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x*x*x * (x * (x * 6 - 15) + 10)
    }
    private static func scaleEase(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x*x*(3-2*x)
    }
    var hasSettled: Bool {
        !recording && (exitElapsed.map { $0 >= exitDuration } ?? true)
    }
    mutating func begin() {
        self = Self(); recording = true
        // Color is ready; its visibility follows the approved expansion.
        intro = 1.5
    }
    mutating func end() {
        guard recording else { return }
        recording = false; targetEnergy = 0
        exitElapsed = 0; exitStartProgress = max(0, progress)
        exitStartScale = presentationScale; exitStartIntro = min(intro, 1.5)
        exitStartLightOpacity = lightOpacity
        // A short tap must shrink from its actual size, never flash a full pill.
        exitScaleStart = progress > 0.001 ? Self.exitScaleOverlapStart : 0
        exitDuration = exitScaleStart + Self.exitScaleDuration
    }
    mutating func setLevel(_ level: Float) {
        guard recording, level.isFinite else { return }
        targetEnergy = pow(min(1, max(0, Double(level))), 0.72)
    }
    mutating func step(_ delta: Double, reducedMotion: Bool = false) {
        guard delta.isFinite, delta > 0 else { return }
        let dt = min(0.05, delta)
        // Animation follows wall time even when a frame arrives late; smoothing
        // the audio envelope still uses a bounded step.
        elapsed += delta
        energy += (targetEnergy - energy) * (1 - exp(-dt / (targetEnergy > energy ? 0.045 : 0.17)))
        if let age = exitElapsed {
            let t = reducedMotion ? exitDuration : age + delta
            exitElapsed = t
            let u = min(1, max(0, t / Self.collapseTravel))
            progress = exitStartProgress * (1 - Self.ease(u))
            velocity = -exitStartProgress * 30 * u*u * (u-1)*(u-1) / Self.collapseTravel
            intro = exitStartIntro
            exitLightScale = 1 - 0.85 * Self.ease(t / 0.24)
            lightOpacity = exitStartLightOpacity * (1 - Self.ease((t - 0.08) / 0.26))
            presentationScale = exitStartScale * (1 - Self.scaleEase((t - exitScaleStart) / Self.exitScaleDuration))
            opacity = t >= exitDuration ? 0 : 1
            return
        }
        guard recording else { return }
        if reducedMotion {
            presentationScale = 1; progress = 1; lightOpacity = 1; velocity = 0
        } else {
            presentationScale = Self.scaleEase(elapsed / Self.entranceScaleDuration)
            let u = min(1, max(0, (elapsed - Self.expansionStart) / Self.expansionDuration))
            progress = Self.ease(u)
            velocity = 30 * u*u * (u-1)*(u-1) / Self.expansionDuration
            lightOpacity = Self.ease((elapsed - Self.expansionStart) / 0.24)
        }
    }
}
