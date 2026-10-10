import XCTest
import AVFoundation
import AudioCapture
import AudioCaptureTestSupport
import ServiceManagement
@testable import VoiceInput

final class AudioStartupTests: XCTestCase {
    func testAudioDeviceExceptionReturnsErrorInsteadOfTerminatingProcess() {
        var error: NSError?
        let installed = VIInstallAudioTap(VIExceptionTestNode(), 0, 1024, nil, { _, _ in }, &error)
        XCTAssertFalse(installed)
        XCTAssertEqual(error?.domain, "VoiceInput.AudioCapture")
        XCTAssertTrue(error?.localizedDescription.contains("audio-device format change") == true)
    }

    func testNewTapAPIFailureWithoutNSErrorStillExplainsFailure() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("Error-returning tap API requires macOS 27") }
        var error: NSError?
        XCTAssertFalse(VIInstallAudioTap(VIFailedTapTestNode(), 0, 1024, nil, { _, _ in }, &error))
        XCTAssertNotNil(error)
    }

    func testRealMixerTapCanBeRemovedAndInstalledAgain() {
        let engine = AVAudioEngine()
        let node = AVAudioMixerNode()
        engine.attach(node)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for _ in 0..<10 {
            var error: NSError?
            let installed = VIInstallAudioTap(node, 0, 4800, format, { _, _ in }, &error)
            XCTAssertTrue(installed, "\(String(describing: error))")
            XCTAssertNil(error)
            guard installed else { return }
            node.removeTap(onBus: 0)
        }
    }

    func testCaptureInstancesDoNotReuseAudioEngineAndStopIsIdempotent() {
        let first = VIAudioInputCapture(), next = VIAudioInputCapture()
        XCTAssertFalse(first.engine === next.engine)
        first.stop(); first.stop(); next.stop()
    }

    final class StubLoginService: LoginService {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var fail = false
        func register() throws {
            registrations += 1
            if fail { throw NSError(domain: "test", code: 1) }
            status = .enabled
        }
        func unregister() throws { status = .notRegistered }
    }

    func testLoginRegistrationHappensOnceAndRespectsLaterUserDisable() throws {
        let suite = "VoiceInput.login.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = StubLoginService()
        let login = LoginAtLaunch(service: service, defaults: defaults, bundlePath: "/Applications/VoiceInput.app")
        login.configureInitialPreference(); login.configureInitialPreference()
        XCTAssertEqual(service.registrations, 1)
        XCTAssertTrue(login.isEnabled)
        try login.toggle()
        login.configureInitialPreference()
        XCTAssertFalse(login.isEnabled)
        XCTAssertEqual(service.registrations, 1)
    }

    func testUninstalledCandidateNeverRegistersAndFailedRegistrationCanRetry() {
        let suite = "VoiceInput.login.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = StubLoginService()
        LoginAtLaunch(service: service, defaults: defaults, bundlePath: "/tmp/VoiceInput.app").configureInitialPreference()
        XCTAssertEqual(service.registrations, 0)
        let login = LoginAtLaunch(service: service, defaults: defaults, bundlePath: "/Applications/VoiceInput.app")
        service.fail = true
        login.configureInitialPreference()
        XCTAssertFalse(defaults.bool(forKey: "loginAtLaunchConfigured"))
        service.fail = false
        login.configureInitialPreference()
        XCTAssertTrue(login.isEnabled)
    }

    func testPendingLoginApprovalIsNotShownAsEnabled() {
        let suite = "VoiceInput.login.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = StubLoginService(); service.status = .requiresApproval
        let login = LoginAtLaunch(service: service, defaults: defaults, bundlePath: "/Applications/VoiceInput.app")
        login.configureInitialPreference()
        XCTAssertEqual(service.registrations, 0)
        XCTAssertFalse(login.isEnabled)
        XCTAssertTrue(login.requiresApproval)
    }

    func testMissingLoginEntryIsRegisteredBeforeSavingPreference() {
        let suite = "VoiceInput.login.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = StubLoginService(); service.status = .notFound
        let login = LoginAtLaunch(service: service, defaults: defaults, bundlePath: "/Applications/VoiceInput.app")
        login.configureInitialPreference()
        XCTAssertEqual(service.registrations, 1)
        XCTAssertTrue(login.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "loginAtLaunchConfigured"))
    }
}
