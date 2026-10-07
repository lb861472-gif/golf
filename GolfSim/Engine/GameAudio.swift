import Foundation
import AVFoundation
import UIKit

// MARK: - Shared DSP helpers

private let sampleRate = 22050
private let sr = Float(sampleRate)
private let twoPi = 2 * Float.pi

private func noise() -> Float { Float.random(in: -1...1) }

/// State-variable filter used for crowd formants.
private struct SVF {
    var low: Float = 0
    var band: Float = 0
    mutating func bandpass(_ x: Float, hz: Float, q: Float) -> Float {
        let f = 2 * sin(Float.pi * hz / sr)
        low += f * band
        let high = x - low - q * band
        band += f * high
        return band
    }
}

private func wavData(_ samples: [Float]) -> Data {
    var pcm = [Int16]()
    pcm.reserveCapacity(samples.count)
    for s in samples { pcm.append(Int16(max(-1, min(1, s)) * 30000)) }
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func tag(_ s: String) { d.append(s.data(using: .ascii) ?? Data()) }
    tag("RIFF"); u32(UInt32(36 + pcm.count * 2)); tag("WAVE")
    tag("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    tag("data"); u32(UInt32(pcm.count * 2))
    pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
    return d
}

private func midiHz(_ m: Int) -> Float { 440 * pow(2, Float(m - 69) / 12) }

// MARK: - Sound effects

/// Every sound is synthesised in code (PCM -> WAV in memory -> AVAudioPlayer), so no audio files ship.
final class GameAudio {

    enum Effect: CaseIterable {
        case impact, swish, wind, cup, splash, thud, sand
        case land, bounce, treeHit
        case cheerSmall, cheerBig, applause, groan
        case pickup, sparkle, fanfare
    }

    var enabled = true
    private var players: [Effect: AVAudioPlayer] = [:]

    /// Built once per launch, off the main thread.
    private enum Library {
        static let all: [Effect: Data] = {
            var out: [Effect: Data] = [:]
            for e in Effect.allCases { out[e] = wavData(GameAudio.synth(e)) }
            return out
        }()
    }

    init() {
        GameAudio.activateSession()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lib = Library.all
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (effect, data) in lib {
                    if let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) {
                        p.prepareToPlay()
                        if effect == .wind { p.numberOfLoops = -1 }
                        self.players[effect] = p
                    }
                }
                if self.windRequested > 0 { self.startWind(volume: self.windRequested) }
            }
        }
    }

    /// `.playback` makes sound work even with the ringer / silent switch off.
    static func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    func play(_ effect: Effect, volume: Float = 1, delay: Double = 0) {
        guard enabled else { return }
        let action = { [weak self] in
            guard let self = self, self.enabled, let p = self.players[effect] else { return }
            p.volume = max(0, min(1, volume))
            p.currentTime = 0
            p.play()
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        } else {
            action()
        }
    }

    private var windRequested: Float = 0

    func startWind(volume: Float) {
        windRequested = volume
        guard enabled, let p = players[.wind] else { return }
        p.volume = max(0, min(1, volume))
        if !p.isPlaying { p.play() }
    }

    func stopAll() {
        windRequested = 0
        players.values.forEach { $0.stop() }
    }

    // MARK: Synthesis

    fileprivate static func synth(_ effect: Effect) -> [Float] {
        switch effect {
        case .impact: return impact()
        case .swish: return swish()
        case .wind: return windLoop()
        case .cup: return cup()
        case .splash: return splash()
        case .thud: return thud()
        case .sand: return sand()
        case .land: return land()
        case .bounce: return bounce()
        case .treeHit: return treeHit()
        case .cheerSmall: return crowd(duration: 2.4, intensity: 0.7, whoops: 4, claps: 70)
        case .cheerBig: return crowd(duration: 4.2, intensity: 1.0, whoops: 9, claps: 220)
        case .applause: return applause(duration: 2.8)
        case .groan: return groan()
        case .pickup: return sadTrombone()
        case .sparkle: return sparkle()
        case .fanfare: return fanfare()
        }
    }

    private static func impact() -> [Float] {
        let n = Int(0.4 * sr)
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            lp += (noise() - lp) * 0.35
            let crack: Float = noise() * exp(-t * 110) * 0.9
            let tick: Float = sin(twoPi * 3400 * t) * exp(-t * 170) * 0.55
            let body: Float = sin(twoPi * 1250 * t) * exp(-t * 60) * 0.35
            let thump: Float = sin(twoPi * 160 * t) * exp(-t * 26) * 0.9
            let tail: Float = lp * exp(-t * 45) * 0.3
            out[i] = crack + tick + body + thump + tail
        }
        return out
    }

    private static func swish() -> [Float] {
        let n = Int(0.5 * sr)
        var out = [Float](repeating: 0, count: n)
        var hp: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            let s1: Float = sin(Float.pi * t / 0.5)
            let env: Float = s1 * s1
            hp = noise() - hp * 0.6
            let freq: Float = 1200 + 3200 * t
            let sweep: Float = sin(twoPi * freq * t) * 0.12
            out[i] = (hp * 0.35 + sweep) * env
        }
        return out
    }

    private static func windLoop() -> [Float] {
        let length = Int(4.0 * sr)
        let fade = Int(0.4 * sr)
        var raw = [Float](repeating: 0, count: length + fade)
        var y1: Float = 0, y2: Float = 0
        for i in 0..<raw.count {
            let t = Float(i) / sr
            y1 += (noise() - y1) * 0.025
            y2 += (y1 - y2) * 0.08
            let a1: Float = sin(twoPi * 0.31 * t)
            let a2: Float = sin(twoPi * 0.83 * t)
            let lfo: Float = 0.65 + 0.25 * a1 + 0.1 * a2
            raw[i] = y2 * 6.5 * lfo
        }
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            if i < fade {
                let w = Float(i) / Float(fade)
                out[i] = raw[i] * w + raw[length + i] * (1 - w)
            } else {
                out[i] = raw[i]
            }
        }
        return out
    }

    private static func cup() -> [Float] {
        let n = Int(0.7 * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / sr
            var v: Float = sin(twoPi * 900 * t) * exp(-t * 90) * 0.5
            if t > 0.08 {
                let t2: Float = t - 0.08
                v += sin(twoPi * 1300 * t2) * exp(-t2 * 90) * 0.4
            }
            if t > 0.18 {
                let tt: Float = t - 0.18
                let f: Float = 420 - 260 * tt
                v += sin(twoPi * f * tt) * exp(-tt * 10) * 0.7
                v += noise() * exp(-tt * 40) * 0.12
            }
            out[i] = v
        }
        return out
    }

    private static func splash() -> [Float] {
        let n = Int(1.0 * sr)
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            lp += (noise() - lp) * 0.2
            let a: Float = lp * exp(-t * 5) * 1.7
            let b: Float = sin(twoPi * 110 * t) * exp(-t * 12) * 0.35
            let bubble: Float = sin(twoPi * (300 + 900 * t) * t) * exp(-t * 14) * 0.15
            out[i] = a + b + bubble
        }
        return out
    }

    private static func thud() -> [Float] {
        let n = Int(0.3 * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / sr
            let a: Float = sin(twoPi * 90 * t) * exp(-t * 18) * 0.9
            let b: Float = noise() * exp(-t * 60) * 0.25
            out[i] = a + b
        }
        return out
    }

    private static func sand() -> [Float] {
        let n = Int(0.55 * sr)
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            lp += (noise() - lp) * 0.25
            out[i] = lp * exp(-t * 8) * 1.5
        }
        return out
    }

    /// Ball landing on turf: soft thump plus a rustle of grass.
    private static func land() -> [Float] {
        let n = Int(0.45 * sr)
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0, lp2: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            lp += (noise() - lp) * 0.3
            lp2 += (lp - lp2) * 0.35
            let thump: Float = sin(twoPi * (95 - 30 * t) * t) * exp(-t * 20) * 0.95
            let grass: Float = lp * exp(-t * 16) * 0.5
            let soft: Float = lp2 * exp(-t * 7) * 0.5
            out[i] = thump + grass + soft
        }
        return out
    }

    private static func bounce() -> [Float] {
        let n = Int(0.18 * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / sr
            let a: Float = sin(twoPi * 120 * t) * exp(-t * 32) * 0.8
            let b: Float = noise() * exp(-t * 90) * 0.2
            out[i] = a + b
        }
        return out
    }

    /// Ball clattering through branches: wooden knock + leaf rustle.
    private static func treeHit() -> [Float] {
        let n = Int(0.7 * sr)
        var out = [Float](repeating: 0, count: n)
        var f = SVF()
        for i in 0..<n {
            let t = Float(i) / sr
            let knock: Float = sin(twoPi * 230 * t) * exp(-t * 38) * 0.8 + sin(twoPi * 540 * t) * exp(-t * 60) * 0.35
            let rustleEnv: Float = exp(-t * 4) * (0.6 + 0.4 * sin(twoPi * 17 * t))
            let rustle: Float = f.bandpass(noise(), hz: 3200, q: 0.5) * rustleEnv * 0.35
            out[i] = knock + rustle
        }
        return out
    }

    // MARK: Crowd

    private static func crowd(duration: Float, intensity: Float, whoops: Int, claps: Int) -> [Float] {
        let n = Int(duration * sr)
        var out = [Float](repeating: 0, count: n)
        var f1 = SVF(), f2 = SVF(), f3 = SVF()
        let attack: Float = 0.22
        for i in 0..<n {
            let t = Float(i) / sr
            let env: Float = t < attack ? (t / attack) * (t / attack) : exp(-(t - attack) * (1.3 / (duration / 2.4)))
            let x = noise()
            var v: Float = f1.bandpass(x, hz: 650, q: 0.35) * 0.55
            v += f2.bandpass(x, hz: 1500, q: 0.4) * 0.45
            v += f3.bandpass(x, hz: 3100, q: 0.6) * 0.2
            out[i] = v * env * 0.9 * intensity
        }
        // Voices: rising "woo!" glides
        for _ in 0..<whoops {
            let start = Float.random(in: 0.05...(duration * 0.45))
            let len = Float.random(in: 0.35...0.7)
            let f0 = Float.random(in: 380...760)
            let amp = Float.random(in: 0.04...0.09) * intensity
            let s0 = Int(start * sr)
            let l = Int(len * sr)
            var phase: Float = 0
            for k in 0..<l where s0 + k < n {
                let tt = Float(k) / sr / len
                let freq = f0 * (1 + 0.55 * tt) * (1 + 0.012 * sin(twoPi * 6 * Float(k) / sr))
                phase += twoPi * freq / sr
                let e: Float = sin(Float.pi * tt)
                let voice: Float = sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)
                out[s0 + k] += voice * e * amp
            }
        }
        // Hand claps
        for _ in 0..<claps {
            let at = Int(Float.random(in: 0.1...(duration * 0.9)) * sr)
            let amp = Float.random(in: 0.15...0.4) * intensity * exp(-Float(at) / sr * 0.5)
            for k in 0..<140 where at + k < n {
                out[at + k] += noise() * exp(-Float(k) / 28) * amp
            }
        }
        return out
    }

    private static func applause(duration: Float) -> [Float] {
        let n = Int(duration * sr)
        var out = [Float](repeating: 0, count: n)
        var f = SVF()
        for i in 0..<n {
            let t = Float(i) / sr
            let env: Float = min(1, t / 0.3) * exp(-max(0, t - 1.0) * 1.2)
            out[i] = f.bandpass(noise(), hz: 2200, q: 0.5) * env * 0.25
        }
        for _ in 0..<320 {
            let at = Int(Float.random(in: 0.0...(duration * 0.85)) * sr)
            let t = Float(at) / sr
            let env: Float = min(1, t / 0.3) * exp(-max(0, t - 1.0) * 1.2)
            let amp = Float.random(in: 0.2...0.5) * env
            for k in 0..<120 where at + k < n {
                out[at + k] += noise() * exp(-Float(k) / 22) * amp
            }
        }
        return out
    }

    /// Disappointed "awww" from the gallery.
    private static func groan() -> [Float] {
        let n = Int(1.5 * sr)
        var out = [Float](repeating: 0, count: n)
        var f1 = SVF(), f2 = SVF(), bed = SVF()
        var phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            let env: Float = min(1, t / 0.12) * exp(-t * 1.6)
            let freq: Float = 190 - 70 * t
            phase += twoPi * freq / sr
            var saw: Float = 0
            for h in 1...8 { saw += sin(phase * Float(h)) / Float(h) }
            let vowel: Float = f1.bandpass(saw, hz: 620 - 120 * t, q: 0.25) * 0.5 + f2.bandpass(saw, hz: 1050 - 200 * t, q: 0.3) * 0.3
            let crowdBed: Float = bed.bandpass(noise(), hz: 700, q: 0.4) * 0.35
            out[i] = (vowel + crowdBed) * env * 0.9
        }
        return out
    }

    // MARK: Jingles

    /// Sad "wah wah wah wahhh" for picking up the ball.
    private static func sadTrombone() -> [Float] {
        let notes: [(Int, Float, Float)] = [(58, 0.0, 0.36), (57, 0.4, 0.36), (56, 0.8, 0.36), (55, 1.2, 1.0)]
        let n = Int(2.4 * sr)
        var out = [Float](repeating: 0, count: n)
        for (idx, note) in notes.enumerated() {
            let (midi, start, len) = note
            let s0 = Int(start * sr)
            let l = Int(len * sr)
            var phase: Float = 0
            for k in 0..<l where s0 + k < n {
                let tt = Float(k) / sr
                var freq = midiHz(midi)
                if idx == 3 { freq *= 1 - 0.035 * (tt / len) + 0.012 * sin(twoPi * 5.5 * tt) }
                phase += twoPi * freq / sr
                let wah: Float = 0.35 + 0.65 * sin(Float.pi * min(1, tt / (idx == 3 ? 0.5 : len)))
                let e: Float = min(1, tt / 0.03) * min(1, (len - tt) / 0.06)
                var v: Float = 0
                let harmonics = 2 + Int(8 * wah)
                for h in 1...harmonics { v += sin(phase * Float(h)) / Float(h) }
                out[s0 + k] += v * e * 0.28
            }
        }
        return out
    }

    /// Rising chime arpeggio played when a putt drops.
    private static func sparkle() -> [Float] {
        let notes = [84, 88, 91, 96, 100]
        let n = Int(1.4 * sr)
        var out = [Float](repeating: 0, count: n)
        for (i, m) in notes.enumerated() {
            let s0 = Int(Float(i) * 0.075 * sr)
            let f = midiHz(m)
            for k in 0..<Int(0.9 * sr) where s0 + k < n {
                let t = Float(k) / sr
                let v: Float = sin(twoPi * f * t) * 0.6 + sin(twoPi * f * 2.01 * t) * 0.25
                out[s0 + k] += v * exp(-t * 4.5) * 0.3
            }
        }
        return out
    }

    private static func fanfare() -> [Float] {
        let chords: [([Int], Float, Float)] = [([60, 64, 67], 0.0, 0.45), ([62, 67, 71], 0.5, 0.45), ([64, 67, 72], 1.0, 0.45), ([67, 72, 76], 1.5, 1.4)]
        let n = Int(3.2 * sr)
        var out = [Float](repeating: 0, count: n)
        for (notes, start, len) in chords {
            let s0 = Int(start * sr)
            let l = Int(len * sr)
            for midi in notes {
                var phase: Float = 0
                let f = midiHz(midi)
                for k in 0..<l where s0 + k < n {
                    let tt = Float(k) / sr
                    phase += twoPi * f / sr
                    let e: Float = min(1, tt / 0.03) * exp(-max(0, tt - len * 0.5) * 2.2)
                    var v: Float = 0
                    for h in 1...6 { v += sin(phase * Float(h)) / Float(h) }
                    out[s0 + k] += v * e * 0.12
                }
            }
        }
        return out
    }
}

// MARK: - Menu music

/// Procedurally composed, seamlessly looping lounge track for the home screen.
final class MenuMusic {
    static let shared = MenuMusic()

    private var player: AVAudioPlayer?
    private var building = false
    private var wantsPlay = false
    private let targetVolume: Float = 0.5

    func play() {
        wantsPlay = true
        GameAudio.activateSession()
        if let p = player {
            if !p.isPlaying {
                p.volume = 0
                p.play()
            }
            p.setVolume(targetVolume, fadeDuration: 1.2)
            return
        }
        guard !building else { return }
        building = true
        DispatchQueue.global(qos: .userInitiated).async {
            let data = wavData(MenuMusic.compose())
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.building = false
                if let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) {
                    p.numberOfLoops = -1
                    p.volume = 0
                    self.player = p
                    if self.wantsPlay {
                        p.play()
                        p.setVolume(self.targetVolume, fadeDuration: 1.5)
                    }
                }
            }
        }
    }

    func stop() {
        wantsPlay = false
        guard let p = player, p.isPlaying else { return }
        p.setVolume(0, fadeDuration: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if self?.wantsPlay == false { p.pause() }
        }
    }

    // MARK: Composition (8 bars, 96 BPM, Cmaj7 - Am7 - Fmaj7 - G6, twice)

    private static func compose() -> [Float] {
        let bpm: Float = 96
        let beat = 60 / bpm
        let bars = 8
        let n = Int(Float(bars * 4) * beat * sr)
        var buf = [Float](repeating: 0, count: n)

        func add(_ i: Int, _ v: Float) { buf[((i % n) + n) % n] += v }   // wraps so the loop is seamless

        func pluck(start: Float, midi: Int, amp: Float, dur: Float, decay: Float = 0.996) {
            let f = midiHz(midi)
            let len = max(2, Int(sr / f))
            var line = [Float](repeating: 0, count: len)
            var prev: Float = 0
            for i in 0..<len { let x = noise(); line[i] = (x + prev) * 0.5; prev = x }
            let s0 = Int(start * sr)
            var idx = 0
            for k in 0..<Int(dur * sr) {
                let cur = line[idx]
                let nxt = line[(idx + 1) % len]
                line[idx] = (cur + nxt) * 0.5 * decay
                add(s0 + k, cur * amp)
                idx = (idx + 1) % len
            }
        }

        let chords: [[Int]] = [[48, 52, 55, 59], [45, 48, 52, 55], [41, 45, 48, 52], [43, 47, 50, 52]]
        let arpPattern = [0, 1, 2, 3, 2, 1, 2, 3]

        for bar in 0..<bars {
            let chord = chords[bar % 4]
            let barStart = Float(bar * 4) * beat

            // Warm pad
            for note in chord {
                let f = midiHz(note + 12)
                let s0 = Int(barStart * sr)
                let len = Int(4.4 * beat * sr)
                for k in 0..<len {
                    let t = Float(k) / sr
                    let a: Float = min(1, t / 0.7)
                    let r: Float = min(1, Float(len - k) / (0.9 * sr))
                    let v: Float = sin(twoPi * f * t) * 0.6 + sin(twoPi * f * 2.003 * t) * 0.15 + sin(twoPi * f * 0.5 * t) * 0.25
                    add(s0 + k, v * a * r * 0.035)
                }
            }

            // Bass on beats 1 and 3
            let root = chord[0] - 12
            for b in [0, 2] {
                let s0 = Int((barStart + Float(b) * beat) * sr)
                let f = midiHz(root)
                for k in 0..<Int(0.9 * sr) {
                    let t = Float(k) / sr
                    let v: Float = sin(twoPi * f * t) + 0.4 * sin(twoPi * f * 2 * t)
                    add(s0 + k, v * exp(-t * 3.2) * 0.2)
                }
            }

            // Soft kick on 1 and 3
            for b in [0, 2] {
                let s0 = Int((barStart + Float(b) * beat) * sr)
                for k in 0..<Int(0.18 * sr) {
                    let t = Float(k) / sr
                    add(s0 + k, sin(twoPi * (52 + 70 * exp(-t * 30)) * t) * exp(-t * 14) * 0.22)
                }
            }

            // Plucked guitar arpeggio on eighth notes
            for (i, p) in arpPattern.enumerated() {
                let t0 = barStart + Float(i) * beat / 2
                pluck(start: t0, midi: chord[p] + 12, amp: 0.2, dur: 1.1)
            }

            // Shaker on off-beats
            for i in 0..<8 {
                let t0 = barStart + (Float(i) + 0.5) * beat / 2
                let s0 = Int(t0 * sr)
                for k in 0..<Int(0.05 * sr) {
                    add(s0 + k, noise() * exp(-Float(k) / (0.01 * sr)) * 0.05)
                }
            }
        }

        // Sparse pentatonic melody (bar, beat, midi, beats)
        let melody: [(Int, Float, Int, Float)] = [
            (0, 0, 79, 1.5), (0, 2, 76, 1), (0, 3, 74, 1), (1, 0, 72, 2), (1, 2.5, 76, 1.5),
            (2, 0, 81, 1.5), (2, 2, 79, 1), (2, 3, 76, 1), (3, 0, 74, 2), (3, 2.5, 72, 1.5),
            (4, 0, 76, 1.5), (4, 2, 79, 1), (4, 3, 81, 1), (5, 0, 84, 2), (5, 2.5, 81, 1.5),
            (6, 0, 79, 1.5), (6, 2, 76, 1), (6, 3, 79, 1), (7, 0, 74, 3)
        ]
        for (bar, b, midi, beats) in melody {
            pluck(start: (Float(bar * 4) + b) * beat, midi: midi, amp: 0.26, dur: beats * beat + 0.7, decay: 0.9965)
        }

        // Normalise
        var peak: Float = 0.001
        for v in buf { peak = max(peak, abs(v)) }
        let g = 0.8 / peak
        for i in 0..<n { buf[i] *= g }
        return buf
    }
}

// MARK: - Haptics

/// Thin wrapper so haptics respect the user setting.
enum Haptics {
    static func impact(enabled: Bool, strong: Bool = true) {
        guard enabled else { return }
        let g = UIImpactFeedbackGenerator(style: strong ? .heavy : .light)
        g.prepare()
        g.impactOccurred()
    }

    static func success(enabled: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning(enabled: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
