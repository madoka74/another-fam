import Foundation
import AVFoundation
import Speech

/// 사람 목소리 듣기 (함께하는 동안만). 기기 안 음성 인식으로 짧은 말을 낱말로 잘라 넘김.
/// 강아지는 낱말 자체를 외우는 게 아니라 '이 소리가 들린 뒤 이 재주를 해서 간식을 받았다'를 쌓아 가며 배움 (Dog.hear·Dog.associate)
/// 0.10.0: 마이크·음성 인식 시작과 다시 시작은 모두 따로 도는 일꾼(SpeechWorker)이 맡음 — 0.9 까지는 말이 끝날 때마다·50초마다
/// 화면을 그리는 줄(메인)에서 인식을 새로 시작해, 그때마다 몇 초씩 멈추는 원인이 됐음
@MainActor
final class VoiceEar {
    var onWord: ((String) -> Void)?
    private(set) var running = false
    private let worker = SpeechWorker()
    private var text = ""                 // 지금 말(한 번 말한 것)의 글자 (부분 결과)
    private var gen = -1                  // 일꾼의 묶음 번호 (바뀌면 새 말)
    private var changedAt: Double = 0

    /// 최근 알아들은 낱말 (설정에서 마이크가 듣고 있는지 확인용)
    static var recent: [String] = []

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "af.voice") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "af.voice") }
    }

    /// 허락을 받고 듣기 시작. 실패하면 이유를 돌려줌
    func start() async -> String? {
        guard VoiceEar.enabled else { return nil }
        let sp = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard sp == .authorized else { return "음성 인식을 허락하면 말로 부를 수 있어요." }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return "마이크를 허락하면 말로 부를 수 있어요." }
        let r = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR")) ?? SFSpeechRecognizer()
        guard let r, r.isAvailable else { return "이 기기에서 음성 인식을 쓸 수 없어요." }
        worker.onText = VoiceEar.handler(self)
        let w = worker
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in w.start(r) { c.resume(returning: $0) } }
        guard ok else { return "마이크를 시작하지 못했어요." }
        running = true
        return nil
    }

    func stop() {
        running = false
        worker.stop()
    }

    /// 일꾼 쪽(다른 스레드)에서 부르는 함수 — 메인 격리 밖에서 만든 클로저로만 닿음
    nonisolated private static func handler(_ me: VoiceEar) -> @Sendable (Int, String, Bool) -> Void {
        { [weak me] g, s, fin in Task { @MainActor in me?.got(g, s, final: fin) } }
    }

    private func got(_ g: Int, _ s: String, final: Bool) {
        if g != gen {
            // 새 묶음: 지난 말이 남아 있으면 마저 넘김
            if !text.isEmpty { emit(text) }
            gen = g; text = ""
        }
        if !s.isEmpty && s != text { text = s; changedAt = CACurrentMediaTime() }
        if final, !text.isEmpty { emit(text); text = "" }
    }

    /// 매 화면: 글자가 0.9초 넘게 그대로면 '한 번 말한 것'이 끝난 것 → 통째로 낱말로 넘기고 듣기를 새로 시작.
    /// 0.10.4 까지: 4분 동안 한 인식 묶음에 말을 계속 이어 붙이고 '몇 번째 낱말까지 넘겼는지'만 셌음 →
    /// ① 말하는 도중의 부분 결과('엎')를 낱말로 넘겨 버리고 ② 같은 말을 되풀이하거나 인식기가 앞의 글자를 고쳐 쓰면
    /// 낱말 수가 늘지 않아 그 뒤의 말을 하나도 넘기지 못했음 ('엎'·'자' 한 번 뒤로 아무것도 안 나온 까닭)
    /// 0.10.10: 0.9초는 인식기가 '앉자'를 '안'까지만 적고 잠시 멈춘 사이에 끝난 것으로 쳐 '안'만 넘기고, 이어진 '자'는
    /// 새 묶음에서 따로 넘겨 한 글자 말을 자주 배웠음 → 1.3초, 글자가 한 자뿐이면 2초까지 기다림
    func tick(now: Double) {
        guard running, !text.isEmpty, now - changedAt > (text.count <= 1 ? 2.0 : 1.3) else { return }
        emit(text)
        text = ""
        worker.restart()
    }

    /// 알아듣기 쉽게 인식기에 미리 알려 줄 말 (재주 말·이름·배운 말)
    func hint(_ words: [String]) { worker.setHints(words) }

    /// 팸 이름들 (소문자·띄어쓰기 없앰) — 한 번 말한 것을 낱말로 나눌 때 이름은 따로 떼어 냄 (0.11.0 여러 팸)
    var names: [String] = []

    private func emit(_ t: String) {
        for w in VoiceEar.utterance(t, names: names) {
            onWord?(w)
            VoiceEar.recent.insert(w, at: 0)
            if VoiceEar.recent.count > 8 { VoiceEar.recent.removeLast() }
        }
    }

    /// 한 글자로도 쓰는 재주 말 (그 밖의 한 글자는 말 조각으로 보고 넘기지 않음)
    static let single: Set<String> = ["손", "빵", "코", "서", "앉", "와"]

    /// 한 번 말한 것 → 넘길 낱말들 (0.10.10):
    /// ① 두 글자 이상 낱말은 그대로 (지금까지 배운 말 그대로 알아들음)
    /// ② 한 글자 조각('안'·'자')은 버리고, 여러 낱말이 짧으면(이름 빼고 6자 이하) 붙인 말('안 자' → '안자')도 넘김
    /// ③ 같은 말 되풀이('엎드려 엎드려')는 한 번으로
    static func utterance(_ t: String, names: [String]) -> [String] {
        var ws = words(t)
        var out: [String] = []
        for name in names where !name.isEmpty {
            if let i = ws.firstIndex(where: { $0.contains(name) }) { out.append(ws.remove(at: i)) }
        }
        for w in ws where w.count >= 2 || single.contains(w) {
            let u = unrepeat(w)
            if !out.contains(u) { out.append(u) }
        }
        let joined = unrepeat(ws.joined())
        if ws.count > 1, joined.count <= 6, !out.contains(joined) { out.append(joined) }
        return out
    }

    /// 같은 말을 붙여 되풀이한 것 → 한 번 ('엎드려엎드려' → '엎드려')
    static func unrepeat(_ w: String) -> String {
        let c = Array(w)
        guard c.count >= 2 else { return w }
        for u in 1...(c.count / 2) where c.count % u == 0 {
            let unit = c[0..<u]
            if stride(from: 0, to: c.count, by: u).allSatisfy({ c[$0..<($0 + u)] == unit }) { return String(unit) }
        }
        return w
    }

    /// 낱말로 자르고 다듬음: 소문자, 문장부호·띄어쓰기 없앰
    /// 같은 말을 붙여 되풀이한 덩어리('엎드려엎드려엎드려')는 한 낱말로 나눔 (0.10.4 까지는 10자 넘는 덩어리를 버렸음)
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        for t in s.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)) where !t.isEmpty {
            if t.count <= 10 { out.append(t); continue }
            let c = Array(t)
            for u in 1...6 where c.count % u == 0 {
                let unit = c[0..<u]
                if stride(from: 0, to: c.count, by: u).allSatisfy({ c[$0..<($0 + u)] == unit }) { out.append(String(unit)); break }
            }
        }
        return out
    }
}

/// 마이크 + 음성 인식 일꾼: 자기 줄(q)에서만 돎. 결과 글자는 onText 로 (묶음 번호, 글자, 끝남)
final class SpeechWorker: @unchecked Sendable {
    var onText: (@Sendable (Int, String, Bool) -> Void)?
    private let q = DispatchQueue(label: "af.speech", qos: .utility)
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: DispatchSourceTimer?
    private var gen = 0
    private var stopped = false
    private var tapOn = false
    private var hints: [String] = []

    /// 지금 말이 끝났으니 다음 말은 새 묶음으로 (q 에서)
    func restart() { q.async { self.begin() } }
    func setHints(_ h: [String]) { q.async { self.hints = h } }

    func start(_ r: SFSpeechRecognizer, done: @escaping @Sendable (Bool) -> Void) {
        q.async {
            self.recognizer = r
            let rq = OperationQueue()
            rq.maxConcurrentOperationCount = 1
            rq.qualityOfService = .utility
            r.queue = rq                                   // 인식 결과도 메인이 아닌 곳에서 받음
            do {
                let ses = AVAudioSession.sharedInstance()
                try ses.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
                try ses.setActive(true)
                let input = self.engine.inputNode
                let fmt = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.feed(buf) }
                self.tapOn = true
                self.engine.prepare()
                try self.engine.start()
            } catch {
                done(false)
                return
            }
            self.begin()
            // 기기 안 인식은 1분 제한이 없음 — 혹시 멈춰 있어도 4분마다 새로
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 240, repeating: 240)
            t.setEventHandler { [weak self] in self?.begin() }
            t.resume()
            self.timer = t
            done(true)
        }
    }

    func stop() {
        q.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.task?.cancel()
            self.task = nil
            self.lock.lock(); self.request?.endAudio(); self.request = nil; self.lock.unlock()
            if self.engine.isRunning { self.engine.stop() }
            if self.tapOn { self.engine.inputNode.removeTap(onBus: 0); self.tapOn = false }
        }
    }

    private func feed(_ b: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        lock.unlock()
        r?.append(b)
    }

    /// 새 듣기 묶음 (q 에서만)
    private func begin() {
        guard !stopped, let r = recognizer else { return }
        gen += 1
        let g = gen
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.taskHint = .search                                    // 짧은 낱말 위주
        req.contextualStrings = hints                             // 재주 말·이름을 먼저 떠올리게 ('엎드려'를 '엎'으로 끊지 않게)
        req.addsPunctuation = false
        lock.lock(); request?.endAudio(); request = req; lock.unlock()
        task = r.recognitionTask(with: req) { [weak self] res, err in
            guard let self else { return }
            let s = res?.bestTranscription.formattedString ?? ""
            let fin = (res?.isFinal ?? false) || err != nil
            self.q.async {
                guard g == self.gen, !self.stopped else { return }          // 지난 묶음(취소된 것)의 소식은 버림
                self.onText?(g, s, fin)
                if fin { self.q.asyncAfter(deadline: .now() + (err != nil ? 1.0 : 0.05)) { if g == self.gen { self.begin() } } }
            }
        }
    }
}
