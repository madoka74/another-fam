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
    private var text = ""                 // 지금 말 묶음의 글자 (부분 결과)
    private var gen = -1                  // 일꾼의 묶음 번호 (바뀌면 새 묶음)
    private var changedAt: Double = 0
    private var used = 0                  // 이 묶음에서 이미 넘긴 낱말 수

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
            // 새 묶음: 지난 묶음에서 아직 안 넘긴 낱말을 마저 넘기고 새로 셈
            flush(all: true)
            gen = g; text = ""; used = 0
        }
        if !s.isEmpty && s != text { text = s; changedAt = CACurrentMediaTime() }
        if final { flush(all: true) }
    }

    /// 매 화면: 0.5초 넘게 그대로인 낱말을 넘김 (부분 결과는 말하는 중에 고쳐지므로 잠깐 기다림)
    func tick(now: Double) {
        guard running, !text.isEmpty else { return }
        flush(all: now - changedAt > 0.5)
    }

    private func flush(all: Bool) {
        let words = VoiceEar.words(text)
        let upto = all ? words.count : max(0, words.count - 1)       // 마지막 낱말은 아직 바뀔 수 있음
        guard upto > used else { return }
        for w in words[used..<upto] {
            onWord?(w)
            VoiceEar.recent.insert(w, at: 0)
            if VoiceEar.recent.count > 8 { VoiceEar.recent.removeLast() }
        }
        used = upto
    }

    /// 낱말로 자르고 다듬음: 소문자, 문장부호·띄어쓰기 없앰
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            .filter { !$0.isEmpty && $0.count <= 10 }
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
