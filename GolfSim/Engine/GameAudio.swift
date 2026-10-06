import Foundation
import AVFoundation
import UIKit

/// All sounds are synthesised in code (PCM -> WAV in memory -> AVAudioPlayer), so no audio assets ship.
final class GameAudio {

    enum Effect: CaseIterable {
        case impact, swish, wind, cup, splash, thud, sand
    }

    var enabled = true
    private var players: [Effect: AVAudioPlayer] = [:]
    private static let rate = 22050

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        for effect in Effect.allCases {
            let samples = Self.synth(effect)
            let data = Self.wavData(samples)
            if let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) {
                p.prepareToPlay()
                players[effect] = p
            }
        }
        players[.wind]?.numberOfLoops = -1
    }

    func play(_ effect: Effect, volume: Float = 1) {
        guard enabled, let p = players[effect] else { return }
        p.volume = volume
        p.currentTime = 0
        p.play()
    }

    func startWind(volume: Float) {
        guard enabled, let p = players[.wind] else { return }
        p.volume = max(0, min(1, volume))
        if !p.isPlaying { p.play() }
    }

    func setWindVolume(_ volume: Float) { players[.wind]?.volume = max(0, min(1, volume)) }

    func stopAll() {
        players.values.forEach { $0.stop() }
    }

    // MARK: Synthesis

    private static func noise() -> Float { Float.random(in: -1...1) }

    private static func synth(_ effect: Effect) -> [Float] {
        let r = Float(rate)
        switch effect {
        case .impact:
            // Sharp crack + low thump
            let n = Int(0.35 * r)
            var out = [Float](repeating: 0, count: n)
            var lp: Float = 0
            for i in 0..<n {
                let t = Float(i) / r
                lp += (noise() - lp) * 0.35
                let twoPi: Float = 2 * Float.pi
                let crack: Float = noise() * exp(-t * 90) * 0.9
                let tone: Float = sin(twoPi * 2800 * t) * exp(-t * 140) * 0.5
                let thump: Float = sin(twoPi * 170 * t) * exp(-t * 28) * 0.8
                let tail: Float = lp * exp(-t * 40) * 0.3
                out[i] = crack + tone + thump + tail
            }
            return out

        case .swish:
            let n = Int(0.5 * r)
            var out = [Float](repeating: 0, count: n)
            var hp: Float = 0
            for i in 0..<n {
                let t = Float(i) / r
                let s1: Float = sin(Float.pi * t / 0.5)
                let env: Float = s1 * s1
                let x = noise()
                hp = x - hp * 0.6
                let freq: Float = 1200 + 3200 * t
                let sweep: Float = sin(2 * Float.pi * freq * t) * 0.12
                out[i] = (hp * 0.35 + sweep) * env
            }
            return out

        case .wind:
            let length = Int(4.0 * r)
            let fade = Int(0.4 * r)
            var raw = [Float](repeating: 0, count: length + fade)
            var y1: Float = 0
            var y2: Float = 0
            for i in 0..<raw.count {
                let t = Float(i) / r
                y1 += (noise() - y1) * 0.025
                y2 += (y1 - y2) * 0.08
                let a1: Float = sin(2 * Float.pi * 0.31 * t)
                let a2: Float = sin(2 * Float.pi * 0.83 * t)
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

        case .cup:
            let n = Int(0.7 * r)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / r
                let twoPi: Float = 2 * Float.pi
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

        case .splash:
            let n = Int(0.9 * r)
            var out = [Float](repeating: 0, count: n)
            var lp: Float = 0
            for i in 0..<n {
                let t = Float(i) / r
                lp += (noise() - lp) * 0.18
                let a: Float = lp * exp(-t * 5.5) * 1.6
                let b: Float = sin(2 * Float.pi * 120 * t) * exp(-t * 14) * 0.3
                out[i] = a + b
            }
            return out

        case .thud:
            let n = Int(0.3 * r)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / r
                let a: Float = sin(2 * Float.pi * 90 * t) * exp(-t * 18) * 0.9
                let b: Float = noise() * exp(-t * 60) * 0.25
                out[i] = a + b
            }
            return out

        case .sand:
            let n = Int(0.5 * r)
            var out = [Float](repeating: 0, count: n)
            var lp: Float = 0
            for i in 0..<n {
                let t = Float(i) / r
                lp += (noise() - lp) * 0.25
                out[i] = lp * exp(-t * 9) * 1.4
            }
            return out
        }
    }

    private static func wavData(_ samples: [Float]) -> Data {
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for s in samples { pcm.append(Int16(max(-1, min(1, s)) * 30000)) }

        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func tag(_ s: String) { d.append(s.data(using: .ascii) ?? Data()) }

        tag("RIFF"); u32(UInt32(36 + pcm.count * 2)); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        tag("data"); u32(UInt32(pcm.count * 2))
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

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
