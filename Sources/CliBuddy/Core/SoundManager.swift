import AVFAudio
import Combine
import Foundation

/// Programmatically synthesised chiptune alerts for session transitions.
/// No audio assets shipped — every event renders from a tone descriptor.

// MARK: - Events

enum SoundEvent: String, CaseIterable {
    case sessionStart     = "session_start"
    case processingBegins = "processing_begins"
    case needsApproval    = "needs_approval"
    case approvalGranted  = "approval_granted"
    case approvalDenied   = "approval_denied"
    case sessionComplete  = "session_complete"
    case error            = "error"
    case compacting       = "compacting"
    case rateLimitWarning = "rate_limit_warning"

    var displayName: String {
        switch self {
        case .sessionStart:      return "Session start"
        case .processingBegins:  return "Processing begins"
        case .needsApproval:     return "Needs approval"
        case .approvalGranted:   return "Approval granted"
        case .approvalDenied:    return "Approval denied"
        case .sessionComplete:   return "Session complete"
        case .error:             return "Error"
        case .compacting:        return "Compacting"
        case .rateLimitWarning:  return "Rate limit warning"
        }
    }

    /// Whether this event plays by default on a clean install.
    var defaultEnabled: Bool {
        switch self {
        case .processingBegins, .compacting: return false
        default:                              return true
        }
    }
}

// MARK: - Tone descriptor

/// One voice = a chain of notes played sequentially. A chord is
/// multiple voices layered at the same time.
private struct Voice {
    struct Note {
        var hz: Double
        var endHz: Double?         // non-nil = glide from hz to endHz
        var seconds: Double
        var wave: Wave
    }
    enum Wave { case sine, square }

    var notes: [Note]
    var gain: Float = 0.35

    var totalSeconds: Double { notes.reduce(0) { $0 + $1.seconds } }
}

// MARK: - Manager

final class SoundManager: ObservableObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = SoundManager()

    private let defaults = UserDefaults.standard
    let engine = AVAudioEngine()
    private let renderQueue = DispatchQueue(
        label: "com.cli-buddy.sound-synth",
        qos: .userInteractive
    )

    private enum Keys {
        static let mute = "soundManager.globalMute"
        static let volume = "soundManager.volume"
        static func enabled(_ e: SoundEvent) -> String {
            "soundManager.event.\(e.rawValue).enabled"
        }
    }

    @Published var globalMute: Bool {
        didSet { defaults.set(globalMute, forKey: Keys.mute) }
    }

    @Published var volume: Float {
        didSet { defaults.set(volume, forKey: Keys.volume) }
    }

    private init() {
        self.globalMute = defaults.bool(forKey: Keys.mute)
        if defaults.object(forKey: Keys.volume) != nil {
            self.volume = defaults.float(forKey: Keys.volume)
        } else {
            self.volume = 0.7
        }
    }

    // MARK: - Per-event toggles

    func isEnabled(_ event: SoundEvent) -> Bool {
        let key = Keys.enabled(event)
        return defaults.object(forKey: key) == nil
            ? event.defaultEnabled
            : defaults.bool(forKey: key)
    }

    func setEnabled(_ enabled: Bool, for event: SoundEvent) {
        defaults.set(enabled, forKey: Keys.enabled(event))
        objectWillChange.send()
    }

    // MARK: - Public triggers

    func play(_ event: SoundEvent) {
        guard !globalMute, isEnabled(event) else { return }
        let voices = voices(for: event)
        let gain = volume
        renderQueue.async { [weak self] in
            self?.render(voices: voices, masterGain: gain)
        }
    }

    func handlePhaseTransition(from old: SessionPhase, to new: SessionPhase) {
        guard let event = Self.mapTransition(from: old, to: new) else { return }
        play(event)
    }

    // MARK: - Transition → event

    private static func mapTransition(
        from old: SessionPhase,
        to new: SessionPhase
    ) -> SoundEvent? {
        switch new {
        case .processing:
            if case .idle = old { return .sessionStart }
            if case .waitingForApproval = old { return .approvalGranted }
            return .processingBegins
        case .waitingForApproval, .waitingForQuestion:
            return .needsApproval
        case .waitingForInput:
            if case .waitingForApproval = old { return .approvalDenied }
            return .sessionComplete
        case .idle:
            if case .waitingForApproval = old { return .approvalDenied }
            return nil
        case .compacting:
            return .compacting
        case .ended:
            return .sessionComplete
        }
    }

    // MARK: - Tone patterns

    private func voices(for event: SoundEvent) -> [Voice] {
        switch event {
        case .sessionStart:
            // Rising triad blip: G4 → B4 → D5
            return [Voice(notes: [
                .init(hz: 392, endHz: nil, seconds: 0.08, wave: .sine),
                .init(hz: 494, endHz: nil, seconds: 0.08, wave: .sine),
                .init(hz: 587, endHz: nil, seconds: 0.10, wave: .sine),
            ])]

        case .processingBegins:
            // Very short square blip (barely noticeable)
            return [Voice(notes: [
                .init(hz: 500, endHz: nil, seconds: 0.04, wave: .square)
            ], gain: 0.22)]

        case .needsApproval:
            // Three ascending beeps, each a touch longer than the last
            return [Voice(notes: [
                .init(hz: 660,  endHz: nil, seconds: 0.07, wave: .sine),
                .init(hz: 784,  endHz: nil, seconds: 0.08, wave: .sine),
                .init(hz: 988,  endHz: nil, seconds: 0.12, wave: .sine),
            ])]

        case .approvalGranted:
            // Two-tone confirmation, A5 → C6
            return [Voice(notes: [
                .init(hz: 880,  endHz: nil, seconds: 0.10, wave: .sine),
                .init(hz: 1047, endHz: nil, seconds: 0.14, wave: .sine),
            ])]

        case .approvalDenied:
            // Low thud, single short square note at 155Hz (E♭3)
            return [Voice(notes: [
                .init(hz: 155, endHz: nil, seconds: 0.18, wave: .square)
            ], gain: 0.40)]

        case .sessionComplete:
            // Four-note arpeggio: C5 → G5 → E5 → C5
            return [Voice(notes: [
                .init(hz: 523,  endHz: nil, seconds: 0.07, wave: .sine),
                .init(hz: 784,  endHz: nil, seconds: 0.07, wave: .sine),
                .init(hz: 659,  endHz: nil, seconds: 0.07, wave: .sine),
                .init(hz: 523,  endHz: nil, seconds: 0.10, wave: .sine),
            ])]

        case .error:
            // 100Hz square buzz, longer duration
            return [Voice(notes: [
                .init(hz: 100, endHz: nil, seconds: 0.25, wave: .square)
            ], gain: 0.38)]

        case .compacting:
            // Ascending glide 400→650Hz — a "wind up"
            return [Voice(notes: [
                .init(hz: 400, endHz: 650, seconds: 0.18, wave: .sine)
            ])]

        case .rateLimitWarning:
            // Alternating octave alarm A4↔A5 over a longer window
            return [Voice(notes: [
                .init(hz: 440, endHz: nil, seconds: 0.11, wave: .square),
                .init(hz: 880, endHz: nil, seconds: 0.11, wave: .square),
                .init(hz: 440, endHz: nil, seconds: 0.11, wave: .square),
                .init(hz: 880, endHz: nil, seconds: 0.15, wave: .square),
            ])]
        }
    }

    // MARK: - Rendering

    private func render(voices: [Voice], masterGain: Float) {
        let sampleRate: Double = 44100
        guard let buffer = mix(voices: voices, sampleRate: sampleRate, masterGain: masterGain) else {
            return
        }

        let player = AVAudioPlayerNode()
        let sourceFormat = buffer.format

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)

        // Gate on live `isRunning` — macOS silently stops the engine on
        // output-routing changes (headphones, BT, sleep/wake), so a
        // cached "started" flag goes stale and every later play would
        // schedule on a stopped engine and be silent.
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                engine.detach(player)
                return
            }
        }

        // Schedule, play, detach when done. The completionHandler runs
        // on an internal audio thread; hop back to the render queue to
        // keep engine mutations serialised.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, player] _ in
            self?.renderQueue.async { [weak self] in
                self?.engine.detach(player)
            }
        }
        player.play()
    }

    /// Synthesise a mix of voices into a single mono PCM buffer.
    private func mix(voices: [Voice], sampleRate: Double, masterGain: Float) -> AVAudioPCMBuffer? {
        let totalSeconds = voices.map(\.totalSeconds).max() ?? 0
        guard totalSeconds > 0 else { return nil }

        let frameCount = AVAudioFrameCount(totalSeconds * sampleRate)
        guard frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let out = pcm.floatChannelData?[0]
        else { return nil }
        pcm.frameLength = frameCount

        // Zero the buffer; each voice adds into it.
        for i in 0..<Int(frameCount) { out[i] = 0 }

        for voice in voices {
            fill(buffer: out, frameCount: Int(frameCount), voice: voice,
                 sampleRate: sampleRate, masterGain: masterGain)
        }

        return pcm
    }

    /// Paint a single voice's notes sequentially into the shared buffer.
    private func fill(
        buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        voice: Voice,
        sampleRate: Double,
        masterGain: Float
    ) {
        var cursor = 0
        let amp = masterGain * voice.gain

        for note in voice.notes {
            let noteFrames = Int(note.seconds * sampleRate)
            guard noteFrames > 0 else { continue }

            // 3ms attack/release envelope — prevents clicks.
            let edge = min(Int(0.003 * sampleRate), noteFrames / 3)

            var phase: Double = 0
            for n in 0..<noteFrames {
                guard cursor + n < frameCount else { break }

                let hz: Double
                if let end = note.endHz {
                    let t = Double(n) / Double(noteFrames)
                    hz = note.hz + (end - note.hz) * t
                } else {
                    hz = note.hz
                }
                phase += 2 * .pi * hz / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }

                let raw: Double
                switch note.wave {
                case .sine:   raw = sin(phase)
                case .square: raw = sin(phase) >= 0 ? 1 : -1
                }

                // Linear attack/release envelope
                let env: Float
                if n < edge {
                    env = Float(n) / Float(edge)
                } else if n > noteFrames - edge {
                    env = Float(noteFrames - n) / Float(edge)
                } else {
                    env = 1
                }

                buffer[cursor + n] += Float(raw) * amp * env
            }
            cursor += noteFrames
        }
    }
}
