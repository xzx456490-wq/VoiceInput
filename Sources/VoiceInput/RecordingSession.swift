import Foundation

/// A result belongs to one recording; finishing is allowed once, after release.
struct RecordingSession {
    enum Phase { case idle, recording, waiting, refining, injecting }
    private(set) var phase: Phase = .idle
    private(set) var id = UUID()
    private(set) var text = ""
    private(set) var hasFinalResult = false

    mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        id = UUID(); text = ""; hasFinalResult = false; phase = .recording
        return id
    }
    mutating func receive(_ value: String, final: Bool, id: UUID) -> Bool {
        guard self.id == id, phase == .recording || phase == .waiting else { return false }
        text = value
        hasFinalResult = hasFinalResult || final
        return true
    }
    mutating func release() -> Bool {
        guard phase == .recording else { return false }
        phase = .waiting
        return true
    }
    mutating func finish(id: UUID, refine: Bool) -> String? {
        guard self.id == id, phase == .waiting else { return nil }
        phase = refine ? .refining : .injecting
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    mutating func prepareInjection(id: UUID) -> Bool {
        guard self.id == id, phase == .refining || phase == .injecting else { return false }
        phase = .injecting
        return true
    }
    mutating func reset() { id = UUID(); phase = .idle; text = ""; hasFinalResult = false }
}
