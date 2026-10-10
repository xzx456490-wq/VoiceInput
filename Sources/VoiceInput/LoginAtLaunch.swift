import Foundation
import ServiceManagement

protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginService {}

final class LoginAtLaunch {
    private let service: LoginService
    private let defaults: UserDefaults
    private let bundlePath: String
    init(service: LoginService = SMAppService.mainApp, defaults: UserDefaults = .standard,
         bundlePath: String = Bundle.main.bundleURL.path) {
        self.service = service
        self.defaults = defaults
        self.bundlePath = bundlePath
    }
    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    func configureInitialPreference() {
        // Candidate builds and XCTest must never register a temporary executable.
        guard bundlePath == "/Applications/VoiceInput.app",
              !defaults.bool(forKey: "loginAtLaunchConfigured") else { return }
        do {
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            if service.status == .enabled || service.status == .requiresApproval {
                defaults.set(true, forKey: "loginAtLaunchConfigured")
            }
        } catch { NSLog("VoiceInput login registration failed: %@", error.localizedDescription) }
    }

    func toggle() throws {
        if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        } else {
            try service.register()
        }
        defaults.set(true, forKey: "loginAtLaunchConfigured")
    }
}
