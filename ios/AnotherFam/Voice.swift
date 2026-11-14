import Foundation
import AVFoundation
import Speech

/// 사람 목소리 듣기 (함께하는 동안만). 기기 안 음성 인식으로 짧은 말을 낱말로 잘라 넘김.
/// 강아지는 낱말 자체를 외우는 게 아니라 '이 소리가 들린 뒤 이 재주를 해서 간식을 받았다'를 쌓아 가며 배움 (Dog.hear·Dog.associate)
@MainActor
final class VoiceEar {
    var onWord: ((String) -> Void)?
    private(set) var running = false

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var text = ""                 // 지금 말 묶음의 글자 (부분 결과)
    private var changedAt: Double = 0
    private var used = 0                  // 이 묶음에서 이미 넘긴 낱말 수
    private var restartAt: Double = 0
    private var stopped = false

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
        recognizer = r
        do {
            let ses = AVAudioSession.sharedInstance()
            try ses.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try ses.setActive(true)
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt, block: VoiceEar.tap(box))
            engine.prepare()
            try engine.start()
        } catch {
            return "마이크를 시작하지 못했어요."
        }
        running = true
        begin()
        return nil
    }

    func stop() {
        stopped = true
        running = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        box.req = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// 마이크 쪽(다른 스레드)에서 읽는 요청 — 메인 격리 밖에서 만든 함수로만 닿음 (오디오 스레드에서 메인 격리 검사로 멈추지 않게)
    final class Box: @unchecked Sendable { var req: SFSpeechAudioBufferRecognitionRequest? }
    private let box = Box()
    nonisolated private static func tap(_ b: Box) -> AVAudioNodeTapBlock { { buf, _ in b.req?.append(buf) } }
    nonisolated private static func handler(_ me: VoiceEar) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak me] res, err in
            let s = res?.bestTranscription.formattedString
            let fin = res?.isFinal ?? false
            let bad = err != nil
            Task { @MainActor in me?.got(s, final: fin, failed: bad) }
        }
    }

    /// 새 듣기 묶음 (한 묶음은 1분을 넘기지 못하므로 말이 끝나거나 50초마다 새로)
    private func begin() {
        guard !stopped, let r = recognizer else { return }
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.taskHint = .search                                    // 짧은 낱말 위주
        request = req
        box.req = req
        text = ""
        used = 0
        restartAt = CACurrentMediaTime() + 50
        task = r.recognitionTask(with: req, resultHandler: VoiceEar.handler(self))
    }

    private func got(_ s: String?, final: Bool, failed: Bool) {
        if let s, s != text { text = s; changedAt = CACurrentMediaTime() }
        if final || failed {
            flush(all: true)
            request?.endAudio()
            if !stopped { begin() }
        }
    }

    /// 매 화면: 0.5초 넘게 그대로인 낱말을 넘김 (부분 결과는 말하는 중에 고쳐지므로 잠깐 기다림)
    func tick(now: Double) {
        guard running else { return }
        if !text.isEmpty && now - changedAt > 0.5 { flush(all: true) }
        else if !text.isEmpty { flush(all: false) }
        if now > restartAt { request?.endAudio(); begin() }
    }

    private func flush(all: Bool) {
        let words = VoiceEar.words(text)
        let upto = all ? words.count : max(0, words.count - 1)       // 마지막 낱말은 아직 바뀔 수 있음
        guard upto > used else { return }
        for w in words[used..<upto] { onWord?(w) }
        used = upto
    }

    /// 낱말로 자르고 다듬음: 소문자, 문장부호·띄어쓰기 없앰
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            .filter { !$0.isEmpty && $0.count <= 10 }
    }
}
