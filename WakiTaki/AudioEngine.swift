import AVFoundation

/// 마이크 캡처(16kHz mono Int16)와 수신 음성 재생을 담당한다.
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var isTapInstalled = false

    /// 캡처된 PCM 조각. 오디오 스레드에서 호출된다.
    var onCapture: ((Data) -> Void)?
    /// 진단용 상태 문구 (엔진/마이크 상태).
    var onStatus: ((String) -> Void)?
    /// 마지막 재생 시점의 엔진/출력 상태 (진단용).
    private(set) var playState = ""
    private var scheduled = 0
    private var played = 0

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        // 음성 처리(setVoiceProcessingEnabled)는 재생 경로를 무음으로 만들어 사용하지 않는다.
        // 대신 스피커 사용 시 되먹임이 생기므로 핸즈프리는 이어폰 사용을 권장한다.
        // 엔진 시작 전에 입력 노드를 그래프에 넣어 둬야 마이크 포맷이 0Hz로 잡히지 않는다.
        _ = engine.inputNode

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        try engine.start()
        player.play()
        onStatus?("오디오 시작됨")

        // 음성 처리 전환/경로 변경으로 엔진이 멈추면 다시 시작한다.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.recover()
        }
    }

    private func recover() {
        let wasCapturing = isTapInstalled
        stopCapture()
        do {
            try engine.start()
            player.play()
            onStatus?("오디오 재시작됨")
        } catch {
            onStatus?("오디오 재시작 실패: \(error.localizedDescription)")
        }
        if wasCapturing { startCapture() }
    }

    func startCapture() {
        guard !isTapInstalled else { return }
        let input = engine.inputNode
        var inputFormat = input.outputFormat(forBus: 0)
        if inputFormat.sampleRate == 0 { inputFormat = input.inputFormat(forBus: 0) }
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: wireFormat) else {
            onStatus?("마이크 포맷 오류: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch")
            return
        }
        onStatus?("마이크 캡처 시작 (\(Int(inputFormat.sampleRate))Hz)")

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = self.wireFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.wireFormat, frameCapacity: capacity) else { return }

            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            self.onCapture?(Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size))
        }
        isTapInstalled = true
    }

    func stopCapture() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    /// 수신한 Int16 PCM 데이터를 재생 큐에 넣는다.
    func play(_ data: Data) {
        // 엔진/재생기가 멈춰 있으면 되살린다.
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count)),
              let dest = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<count { dest[i] = Float(src[i]) / 32768.0 }
        }
        scheduled += 1
        player.scheduleBuffer(buffer) { [weak self] in self?.played += 1 }
        playState = "엔진 \(engine.isRunning ? "ON" : "OFF") · 재생기 \(player.isPlaying ? "ON" : "OFF") · 대기 \(scheduled - played) · 출력 \(AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "없음")"
    }
}
