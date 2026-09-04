import AVFoundation
import Foundation

private let sampleRate = 44100.0
private let gainFloor = 0.0001
private let stopPadding = 0.05
private let outputGain = 4.0

private enum Waveform { case sine, triangle }
private enum FilterKind { case lowpass, bandpass }

private struct ToneLayer {
    let waveform: Waveform
    let frequency: Double
    var detune = 0.0
    var glideTo: Double?
    var glideTime: Double?
    var offset = 0.0
    let attack: Double
    let decay: Double
    let peak: Double
}

private struct NoiseLayer {
    let filter: FilterKind
    let frequency: Double
    var q = 1.0
    var offset = 0.0
    let attack: Double
    let decay: Double
    let peak: Double
}

private enum Layer {
    case tone(ToneLayer)
    case noise(NoiseLayer)

    var offset: Double {
        switch self {
        case .tone(let t): t.offset
        case .noise(let n): n.offset
        }
    }
    var duration: Double {
        switch self {
        case .tone(let t): t.attack + t.decay
        case .noise(let n): n.attack + n.decay
        }
    }
}

private struct Shimmer {
    let delay: Double
    let feedback: Double
    let wet: Double
    let lowpass: Double

    var tail: Double {
        guard feedback > 0 else { return 0 }
        guard feedback < 1 else { return delay }
        return delay * (1 + (log(gainFloor * 10) / log(feedback)).rounded(.up))
    }
}

private struct Recipe {
    let masterGain: Double
    let layers: [Layer]
    var shimmer: Shimmer?
}

private let recipes: KeyValuePairs<String, Recipe> = [
    "chime": Recipe(masterGain: 0.5, layers: [
        .tone(ToneLayer(waveform: .sine, frequency: 1046.5, attack: 0.006, decay: 0.22, peak: 0.09)),
        .tone(ToneLayer(waveform: .sine, frequency: 1568, offset: 0.09, attack: 0.006, decay: 0.26, peak: 0.08)),
    ], shimmer: Shimmer(delay: 0.12, feedback: 0.25, wet: 0.18, lowpass: 4000)),
    "sparkle": Recipe(masterGain: 0.5, layers: [
        .tone(ToneLayer(waveform: .sine, frequency: 1760, attack: 0.003, decay: 0.09, peak: 0.045)),
        .tone(ToneLayer(waveform: .sine, frequency: 2217, offset: 0.045, attack: 0.003, decay: 0.09, peak: 0.04)),
        .tone(ToneLayer(waveform: .sine, frequency: 2637, offset: 0.09, attack: 0.003, decay: 0.1, peak: 0.038)),
        .tone(ToneLayer(waveform: .sine, frequency: 3520, offset: 0.135, attack: 0.003, decay: 0.12, peak: 0.032)),
    ], shimmer: Shimmer(delay: 0.07, feedback: 0.35, wet: 0.22, lowpass: 6000)),
    "droplet": Recipe(masterGain: 0.55, layers: [
        .tone(ToneLayer(waveform: .sine, frequency: 1200, glideTo: 550, glideTime: 0.14, attack: 0.004, decay: 0.2, peak: 0.075)),
    ], shimmer: Shimmer(delay: 0.09, feedback: 0.2, wet: 0.15, lowpass: 3000)),
    "bloom": Recipe(masterGain: 0.5, layers: [
        .tone(ToneLayer(waveform: .sine, frequency: 528, attack: 0.06, decay: 0.32, peak: 0.06)),
        .tone(ToneLayer(waveform: .sine, frequency: 528, detune: 12, attack: 0.06, decay: 0.34, peak: 0.05)),
    ], shimmer: Shimmer(delay: 0.15, feedback: 0.2, wet: 0.12, lowpass: 2500)),
    "success": Recipe(masterGain: 0.5, layers: [
        .tone(ToneLayer(waveform: .sine, frequency: 880, attack: 0.004, decay: 0.09, peak: 0.06)),
        .tone(ToneLayer(waveform: .sine, frequency: 1108.73, offset: 0.06, attack: 0.004, decay: 0.1, peak: 0.06)),
        .tone(ToneLayer(waveform: .sine, frequency: 1318.51, offset: 0.12, attack: 0.004, decay: 0.18, peak: 0.07)),
    ], shimmer: Shimmer(delay: 0.1, feedback: 0.22, wet: 0.16, lowpass: 4500)),
    "ready": Recipe(masterGain: 0.48, layers: [
        .noise(NoiseLayer(filter: .bandpass, frequency: 3600, q: 1.8, attack: 0.001, decay: 0.02, peak: 0.11)),
        .tone(ToneLayer(waveform: .triangle, frequency: 330, glideTo: 660, glideTime: 0.12, offset: 0.012, attack: 0.004, decay: 0.16, peak: 0.055)),
        .tone(ToneLayer(waveform: .sine, frequency: 990, offset: 0.13, attack: 0.004, decay: 0.22, peak: 0.06)),
    ], shimmer: Shimmer(delay: 0.1, feedback: 0.16, wet: 0.1, lowpass: 4200)),
    "arrival": Recipe(masterGain: 0.44, layers: [
        .noise(NoiseLayer(filter: .lowpass, frequency: 900, q: 0.8, attack: 0.05, decay: 0.24, peak: 0.035)),
        .tone(ToneLayer(waveform: .sine, frequency: 220, glideTo: 440, glideTime: 0.32, attack: 0.04, decay: 0.34, peak: 0.055)),
        .tone(ToneLayer(waveform: .sine, frequency: 659.25, offset: 0.12, attack: 0.045, decay: 0.32, peak: 0.04)),
        .tone(ToneLayer(waveform: .sine, frequency: 987.77, offset: 0.19, attack: 0.045, decay: 0.34, peak: 0.032)),
    ], shimmer: Shimmer(delay: 0.16, feedback: 0.28, wet: 0.18, lowpass: 3200)),
]

private struct Biquad {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    private static func terms(_ freq: Double, _ q: Double) -> (alpha: Double, cw: Double, a0: Double) {
        let w = 2 * .pi * freq / sampleRate
        let alpha = sin(w) / (2 * q)
        return (alpha, cos(w), 1 + alpha)
    }

    static func lowpass(_ freq: Double, q: Double) -> Biquad {
        let (alpha, cw, a0) = terms(freq, q)
        return Biquad(b0: (1 - cw) / 2 / a0, b1: (1 - cw) / a0, b2: (1 - cw) / 2 / a0,
                      a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    static func bandpass(_ freq: Double, q: Double) -> Biquad {
        let (alpha, cw, a0) = terms(freq, q)
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0,
                      a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

private func envelope(_ t: Double, attack: Double, decay: Double, peak: Double) -> Double {
    if t < 0 { return 0 }
    if t < attack { return gainFloor * pow(peak / gainFloor, t / attack) }
    let d = t - attack
    if d < decay { return peak * pow(gainFloor / peak, d / decay) }
    return 0
}

enum CueSynth {
    static let names = recipes.map(\.key)
    static let defaultName = "chime"
    private static func recipe(_ name: String) -> Recipe? {
        recipes.first { $0.key == name }?.value
    }

    private static var players: [String: AVAudioPlayer] = [:]

    static func play(_ name: String?) {
        let key = name.flatMap { recipe($0) != nil ? $0 : nil } ?? defaultName
        if players[key] == nil, let recipe = recipe(key),
           let player = try? AVAudioPlayer(data: wavData(render(recipe))) {
            players[key] = player
        }
        guard let player = players[key] else { return }
        player.currentTime = 0
        player.play()
    }

}

extension CueSynth {
    fileprivate static func render(_ recipe: Recipe) -> [Double] {
        let sourceEnd = recipe.layers.map { $0.offset + $0.duration + stopPadding }.max() ?? 0
        let total = sourceEnd + (recipe.shimmer?.tail ?? 0)
        let count = Int(min(total, 4.0) * sampleRate)
        var dry = [Double](repeating: 0, count: count)

        for layer in recipe.layers {
            switch layer {
            case .tone(let t): renderTone(t, into: &dry)
            case .noise(let n): renderNoise(n, into: &dry)
            }
        }

        var mixed = dry
        if let s = recipe.shimmer {
            var lp = Biquad.lowpass(s.lowpass, q: 1)
            let delaySamples = max(1, Int(s.delay * sampleRate))
            var delayIn = [Double](repeating: 0, count: count)
            for n in 0..<count {
                let delayed = n >= delaySamples ? delayIn[n - delaySamples] : 0
                let filtered = lp.process(delayed)
                delayIn[n] = dry[n] + s.feedback * filtered
                mixed[n] = dry[n] + s.wet * filtered
            }
        }

        return mixed.map { tanh($0 * recipe.masterGain * outputGain) }
    }

    private static func renderTone(_ t: ToneLayer, into dry: inout [Double]) {
        let start = Int(t.offset * sampleRate)
        let length = Int((t.attack + t.decay) * sampleRate)
        let baseFreq = t.frequency * pow(2, t.detune / 1200)
        let glideTime = t.glideTime ?? (t.attack + t.decay)
        var phase = 0.0
        for i in 0..<length {
            let n = start + i
            guard n < dry.count else { break }
            let time = Double(i) / sampleRate
            var freq = baseFreq
            if let target = t.glideTo {
                let progress = min(time, glideTime) / glideTime
                freq = baseFreq * pow(target / baseFreq, progress)
            }
            phase += 2 * .pi * freq / sampleRate
            let raw = t.waveform == .sine ? sin(phase) : (2 / Double.pi) * asin(sin(phase))
            dry[n] += raw * envelope(time, attack: t.attack, decay: t.decay, peak: t.peak)
        }
    }

    private static func renderNoise(_ l: NoiseLayer, into dry: inout [Double]) {
        let start = Int(l.offset * sampleRate)
        let length = Int((l.attack + l.decay) * sampleRate)
        var filter = l.filter == .lowpass ? Biquad.lowpass(l.frequency, q: l.q)
                                          : Biquad.bandpass(l.frequency, q: l.q)
        for i in 0..<length {
            let n = start + i
            guard n < dry.count else { break }
            let time = Double(i) / sampleRate
            let white = Double.random(in: -1...1)
            dry[n] += filter.process(white) * envelope(time, attack: l.attack, decay: l.decay, peak: l.peak)
        }
    }

    fileprivate static func wavData(_ samples: [Double]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        let sr = UInt32(sampleRate)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le(UInt32(36 + pcm.count)))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(le(UInt32(16)))
        data.append(le(UInt16(1)))
        data.append(le(UInt16(1)))
        data.append(le(sr))
        data.append(le(sr * 2))
        data.append(le(UInt16(2)))
        data.append(le(UInt16(16)))
        data.append(contentsOf: Array("data".utf8))
        data.append(le(UInt32(pcm.count)))
        data.append(pcm)
        return data
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}
