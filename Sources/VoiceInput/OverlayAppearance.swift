import Foundation

struct OverlayAppearance {
    var visualStyle: Int
    var glassAmount: Double
    var motionGain: Double
    var material: Int
    var refraction: Bool
    var refractionStrength: Double

    init(visualStyle: Int = 0, glassAmount: Double = 0.55, motionGain: Double = 2, material: Int = 0, refraction: Bool = false, refractionStrength: Double = 14) {
        self.visualStyle = visualStyle == 1 ? 1 : 0
        self.glassAmount = glassAmount.isFinite ? min(1, max(0, glassAmount)) : 0.55
        self.motionGain = motionGain.isFinite ? min(2, max(0, motionGain)) : 2
        self.material = material == 1 ? 1 : 0
        self.refraction = refraction
        self.refractionStrength = refractionStrength.isFinite ? min(32, max(0, refractionStrength)) : 14
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(visualStyle: defaults.object(forKey: "overlayVisualStyle") as? Int ?? 1,
             glassAmount: defaults.object(forKey: "overlayGlassAmount") as? Double ?? 0.55,
             motionGain: defaults.object(forKey: "overlayMotionGain") as? Double ?? 2,
             material: defaults.integer(forKey: "overlayGlassMaterial"),
             refraction: defaults.bool(forKey: "overlayBackgroundRefraction"),
             refractionStrength: defaults.object(forKey: "overlayRefractionStrength") as? Double ?? 14)
    }

    // Apply the user-approved visual preset once; subsequent slider changes
    // must survive app relaunch. Recording consent and motion remain intact.
    static func applyThickGlassPresetIfNeeded(to defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: "overlayThickGlassPresetVersion") < 1 else { return }
        var settings = load(from: defaults)
        settings.glassAmount = 0.19
        settings.refractionStrength = 24
        settings.material = 0
        settings.save(to: defaults)
        defaults.set(1, forKey: "overlayThickGlassPresetVersion")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(visualStyle, forKey: "overlayVisualStyle")
        defaults.set(glassAmount, forKey: "overlayGlassAmount")
        defaults.set(motionGain, forKey: "overlayMotionGain")
        defaults.set(material, forKey: "overlayGlassMaterial")
        defaults.set(refraction, forKey: "overlayBackgroundRefraction")
        defaults.set(refractionStrength, forKey: "overlayRefractionStrength")
    }
}

// One audio envelope drives both the waveform and the shell spring.
struct CapsuleMotion {
    private(set) var energy: Double = 0
    private(set) var expansion: Double = 0
    private(set) var velocity: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var recording = false
    private var target: Double = 0

    var hasSettled: Bool {
        !recording && energy < 0.001 && abs(expansion) < 0.001 && abs(velocity) < 0.005
    }

    mutating func begin() { self = Self(); recording = true }
    mutating func end() { recording = false; target = 0 }
    mutating func reset() { self = Self() }

    mutating func setLevel(_ level: Double) {
        guard recording, level.isFinite else { return }
        let normalized = min(1, max(0, (level - 0.025) / 0.975))
        target = pow(normalized, 0.72)
    }

    mutating func step(delta: Double) {
        guard delta.isFinite, delta > 0 else { return }
        let dt = min(0.05, delta)
        elapsed += dt
        let response = target > energy ? 0.045 : 0.17
        energy += (target - energy) * (1 - exp(-dt / response))
        let desired = recording ? energy : 0
        velocity += (165 * (desired - expansion) - 22 * velocity) * dt
        expansion += velocity * dt
    }
}
