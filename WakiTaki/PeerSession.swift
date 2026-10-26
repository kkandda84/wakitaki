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

    private let serviceType = "wakitaki"
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
    private lazy var browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
    private let audio = AudioEngine()
    private var receiveTimer: Timer?
    private var lastVoiceTime = Date.distantPast
    private let voiceThreshold: Double = 500   // Int16 RMS 기준
    private let voiceHangover: TimeInterval = 0.6

    override init() {
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        audio.onCapture = { [weak self] data in self?.send(data) }
    }

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.errorMessage = "설정에서 마이크 권한을 허용해 주세요."; return }
                do { try self.audio.start() } catch { self.errorMessage = "오디오 시작 실패: \(error.localizedDescription)" }
                self.advertiser.startAdvertisingPeer()
                self.browser.startBrowsingForPeers()
            }
        }
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

    private func updateCapture() {
        if handsFree && !connectedPeers.isEmpty {
            audio.startCapture()
        } else if !isTalking {
            audio.stopCapture()
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
        DispatchQueue.main.async { self.refreshPeers() }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        audio.play(data)
        DispatchQueue.main.async {
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
        // 양쪽이 동시에 초대하지 않도록 이름이 작은 쪽만 초대한다.
        guard myPeerID.displayName < peerID.displayName else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.errorMessage = "기기 검색 실패: \(error.localizedDescription)" }
    }
}
