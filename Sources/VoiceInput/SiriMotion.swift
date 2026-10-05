import Foundation
struct SiriMotion {
    private(set) var progress: Double = 0
    private(set) var velocity: Double = 0
    private(set) var energy: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var intro: Double = 0
    private(set) var recording = false
    private var targetEnergy: Double = 0
    private var exitElapsed: Double?
    private var exitStartProgress: Double = 0
    private var exitStartIntro: Double = 0
    private(set) var exitLightScale: Double = 1
    private(set) var lightOpacity: Double = 1
    private(set) var opacity: Double = 1
    private static func ease(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x*x*x * (x * (x * 6 - 15) + 10)
    }
    var hasSettled: Bool {
        !recording && (exitElapsed.map { $0 >= 0.88 } ?? (abs(progress) < 0.001 && abs(velocity) < 0.005))
    }
    mutating func begin() {
        self = Self(); recording = true
        // Light is ready from the first opening frame. The glass geometry and
        // panel entrance already soften its arrival; do not wait for full size.
        intro = 1.5
    }
    mutating func end() {
        guard recording else { return }
        recording = false; targetEnergy = 0
        exitElapsed = 0; exitStartProgress = max(0, progress); exitStartIntro = min(intro, 1.5)
    }
    mutating func setLevel(_ level: Float) {
        guard recording, level.isFinite else { return }
        targetEnergy = pow(min(1, max(0, Double(level))), 0.72)
    }
    mutating func step(_ delta: Double, reducedMotion: Bool = false) {
        guard delta.isFinite, delta > 0 else { return }
        let dt = min(0.05, delta)
        elapsed += dt
        energy += (targetEnergy - energy) * (1 - exp(-dt / (targetEnergy > energy ? 0.045 : 0.17)))
        if let age = exitElapsed {
            let t = reducedMotion ? 0.88 : age + dt
            exitElapsed = t
            let u = min(1, max(0, (t - 0.06) / 0.64))
            progress = exitStartProgress * (1 - Self.ease(u))
            velocity = -exitStartProgress * 30 * u*u * (u-1)*(u-1) / 0.64
            intro = exitStartIntro
            exitLightScale = 1 - 0.85 * Self.ease(t / 0.48)
            lightOpacity = 1 - Self.ease((t - 0.24) / 0.46)
            opacity = 1 - Self.ease((t - 0.54) / 0.28)
            return
        }
        if reducedMotion { progress = recording ? 1 : 0 }
        else {
            let h = dt / 4
            for _ in 0..<4 {
                velocity += (450 * ((recording ? 1 : 0) - progress) - 28 * velocity) * h
                progress += velocity * h
            }
        }
        if recording && progress > 0.99 { intro += dt }
    }
}
