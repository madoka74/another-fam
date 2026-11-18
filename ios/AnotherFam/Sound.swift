import Foundation
import RealityKit

/// 소리: Sounds/*.wav (tools/dog_sounds.py 가 만든 것). 개 몸(머리)에 붙여 그 자리에서 들리게 함.
/// 목소리는 소리 크기 변화(초당 60칸)를 미리 뽑아 두고 그에 맞춰 입을 벌림. 나이에 맞춰 빠르기(높이)를 바꿔 냄
@MainActor
final class SoundBank {
    static let shared = SoundBank()
    private var res: [String: AudioFileResource] = [:]
    private var env: [String: [Float]] = [:]
    private var groups: [String: [String]] = [:]
    private var loaded = false
    /// 설정의 소리 크기 (dB)
    var master: Double = 0

    func preload() {
        guard !loaded else { return }
        loaded = true
        var urls = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "Sounds") ?? []
        // 쓸 소리 목록(index.txt)이 있으면 그것만 — 저장소에 남은 예전 소리 파일은 무시 (GitHub 웹 업로드로는 파일을 지우기 번거로움)
        if let use = SoundBank.manifest() { urls = urls.filter { use.contains($0.deletingPathExtension().lastPathComponent) } }
        for u in urls {
            let name = u.deletingPathExtension().lastPathComponent
            guard let r = try? AudioFileResource.load(contentsOf: u, withName: name,
                                                      configuration: AudioFileResource.Configuration(loadingStrategy: .preload, shouldLoop: false)) else { continue }
            res[name] = r
            env[name] = SoundBank.envelope(u)
            var base = name
            while let l = base.last, l.isNumber { base.removeLast() }
            groups[base, default: []].append(name)
        }
        for k in Array(groups.keys) { groups[k]?.sort() }
    }

    nonisolated static func manifest() -> Set<String>? {
        guard let u = Bundle.main.url(forResource: "index", withExtension: "txt", subdirectory: "Sounds"),
              let t = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let names = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : Set(names)
    }

    func has(_ base: String) -> Bool { groups[base] != nil || res[base] != nil }

    /// base 이름(끝 숫자 뺀 것)의 여러 소리 중 하나를 골라 냄. 반환: 고른 이름 (입 맞추기에 씀)
    @discardableResult
    func play(_ base: String, on e: Entity, gain: Double = 0, speed: Double = 1) -> String? {
        let list = groups[base] ?? (res[base] != nil ? [base] : [])
        guard let name = list.randomElement(), let r = res[name] else { return nil }
        let c = e.playAudio(r)
        c.gain = gain + master
        c.speed = speed
        return name
    }

    func envelope(_ name: String) -> [Float] { env[name] ?? [] }
    func duration(_ name: String) -> Float { Float(env[name]?.count ?? 0) / 60 }

    /// WAV(16비트) → 1/60초마다 소리 크기 (0~1)
    private static func envelope(_ url: URL) -> [Float] {
        guard let d = try? Foundation.Data(contentsOf: url), d.count > 44 else { return [] }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            var o = 12
            var rate = 44100, ch = 1
            var dataOff = -1, dataLen = 0
            while o + 8 <= raw.count {
                let id = String(bytes: [raw[o], raw[o + 1], raw[o + 2], raw[o + 3]], encoding: .ascii) ?? ""
                let len = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self)))
                if id == "fmt ", o + 16 <= raw.count {
                    ch = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 10, as: UInt16.self)))
                    rate = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 12, as: UInt32.self)))
                } else if id == "data" {
                    dataOff = o + 8; dataLen = min(len, raw.count - o - 8)
                    break
                }
                o += 8 + len + (len & 1)
            }
            guard dataOff > 0, rate > 0, ch > 0 else { return [] }
            let n = dataLen / (2 * ch)
            let win = max(1, rate / 60)
            var out: [Float] = []
            var peak: Float = 1e-6
            var i = 0
            while i < n {
                var s: Float = 0
                let m = min(win, n - i)
                for k in 0..<m {
                    let v = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: dataOff + (i + k) * 2 * ch, as: Int16.self))) / 32768
                    s += v * v
                }
                let r = (s / Float(m)).squareRoot()
                out.append(r)
                peak = max(peak, r)
                i += win
            }
            return out.map { min(1, $0 / peak) }
        }
    }
}
