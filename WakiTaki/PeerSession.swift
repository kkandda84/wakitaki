import AVFoundation
import MultipeerConnectivity
import UIKit

/// 주변 기기 탐색/연결과 음성 데이터 송수신.
final class PeerSession: NSObject, ObservableObject {
    @Published var connectedPeers: [String] = []
    @Published var isTalking = false
    /// true면 버튼 없이 말소리가 감지될 때만 자동 전송한다 (이어폰 사용 권장).
    @Published var handsFree = false { didSet { updateCapture() } }
    @Published var isReceiving = false
    @Published var errorMessage: String?
    /// 연결 진단용: 발견한 기기 수와 마지막 연결 상태.
    @Published var debugStatus = "시작 전"
    @Published var audioStatus = ""
    @Published var sentCount = 0
    @Published var sentPeak = 0
    @Published var receivedPeak = 0
    @Published var playState = ""
    @Published var receivedCount = 0

    private let serviceType = "wakitaki"
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
    /// 기기 이름이 같아도 초대 방향을 정할 수 있도록 실행마다 만드는 고유 ID.
    private let myID = UUID().uuidString
    private lazy var session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .optional)
    private lazy var advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["id": myID], serviceType: serviceType)
    private lazy var browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
    private let audio = AudioEngine()
    private var receiveTimer: Timer?
    private var foundPeers: [MCPeerID: String] = [:]
    private var inviteTimer: Timer?
    private var lastInvite: [MCPeerID: Date] = [:]
    private var connecting: Set<MCPeerID> = []
    private var lastVoiceTime = Date.distantPast
    private let voiceThreshold: Double = 500   // Int16 RMS 기준
    private let voiceHangover: TimeInterval = 0.6

    override init() {
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        audio.onCapture = { [weak self] data in self?.send(data) }
        audio.onStatus = { [weak self] text in DispatchQueue.main.async { self?.audioStatus = text } }
    }

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.errorMessage = "설정에서 마이크 권한을 허용해 주세요."; return }
                do { try self.audio.start() } catch { self.errorMessage = "오디오 시작 실패: \(error.localizedDescription)" }
                self.advertiser.startAdvertisingPeer()
                self.browser.startBrowsingForPeers()
                self.debugStatus = "검색 중 (발견 0)"
                self.inviteTimer?.invalidate()
                self.inviteTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                    self?.inviteFoundPeers()
                }
            }
        }
    }

    /// 진단용: 받은 데이터 없이 내부에서 만든 440Hz 음을 같은 재생 경로로 튼다.
    func playTestTone() {
        let rate = 16000.0
        let samples = (0..<Int(rate * 0.6)).map { i in
            Int16(12000 * sin(2 * Double.pi * 440 * Double(i) / rate))
        }
        audio.play(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        playState = audio.playState
    }

    func beginTalking() {
        guard !connectedPeers.isEmpty, !isTalking else { return }
        isTalking = true
        audio.startCapture()
    }

    func endTalking() {
        guard isTalking else { return }
        isTalking = false
        if !handsFree { audio.stopCapture() }
    }

    private func send(_ data: Data) {
        guard !session.connectedPeers.isEmpty else { return }
        if handsFree && !isVoice(data) { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
        let peak = Self.peak(of: data)
        DispatchQueue.main.async { self.sentCount += 1; self.sentPeak = peak }
    }

    /// 말소리가 감지된 직후 잠시(hangover) 동안은 계속 전송해 단어 끝이 잘리지 않게 한다.
    private func isVoice(_ data: Data) -> Bool {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return false }
        let sumSquares = data.withUnsafeBytes { raw -> Double in
            raw.bindMemory(to: Int16.self).reduce(0) { $0 + Double($1) * Double($1) }
        }
        if (sumSquares / Double(count)).squareRoot() > voiceThreshold { lastVoiceTime = Date() }
        return Date().timeIntervalSince(lastVoiceTime) < voiceHangover
    }

    /// 진단용: Int16 샘플의 최대 절댓값 (0이면 무음).
    private static func peak(of data: Data) -> Int {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { max($0, Int(abs(Int32($1)))) }
        }
    }

    private func updateCapture() {
        if handsFree && !connectedPeers.isEmpty {
            audio.startCapture()
        } else if !isTalking {
            audio.stopCapture()
        }
    }

    /// 초대가 시간 초과/거절돼도 연결될 때까지 주기적으로 다시 초대한다.
    private func inviteFoundPeers() {
        for (peer, theirID) in foundPeers where myID < theirID && !session.connectedPeers.contains(peer) {
            // 진행 중인 초대(제한 시간 15초)를 덮어쓰지 않도록 충분히 지난 뒤에만 다시 보낸다.
            if connecting.contains(peer) { continue }
            if let last = lastInvite[peer], Date().timeIntervalSince(last) < 20 { continue }
            lastInvite[peer] = Date()
            browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
        }
    }

    private func refreshPeers() {
        connectedPeers = session.connectedPeers.map(\.displayName)
        if connectedPeers.isEmpty { endTalking() }
        updateCapture()
    }
}

extension PeerSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let label: String
        switch state {
        case .connected: label = "연결됨"
        case .connecting: label = "연결 중"
        default: label = "연결 안 됨"
        }
        DispatchQueue.main.async {
            if state == .connecting { self.connecting.insert(peerID) } else { self.connecting.remove(peerID) }
            self.debugStatus = "\(peerID.displayName): \(label) (발견 \(self.foundPeers.count))"
            self.refreshPeers()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.audio.play(data)
            self.receivedCount += 1
            self.receivedPeak = Self.peak(of: data)
            self.playState = self.audio.playState
            self.isReceiving = true
            self.receiveTimer?.invalidate()
            self.receiveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                self.isReceiving = false
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.errorMessage = "연결 대기 실패: \(error.localizedDescription)" }
    }
}

extension PeerSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // 양쪽이 동시에 초대하지 않도록 ID가 작은 쪽만 초대한다.
        guard let theirID = info?["id"] else { return }
        DispatchQueue.main.async {
            self.foundPeers[peerID] = theirID
            self.debugStatus = "발견: \(peerID.displayName) (\(self.myID < theirID ? "초대 보냄" : "초대 기다림"))"
        }
        if myID < theirID {
            DispatchQueue.main.async { self.lastInvite[peerID] = Date() }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.foundPeers[peerID] = nil
            self.debugStatus = "기기 사라짐: \(peerID.displayName)"
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.errorMessage = "기기 검색 실패: \(error.localizedDescription)" }
    }
}
