import SwiftUI

struct ContentView: View {
    @StateObject private var peers = PeerSession()

    private var statusText: String {
        if peers.connectedPeers.isEmpty { return "주변 기기 찾는 중…" }
        return "연결됨: " + peers.connectedPeers.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 32) {
            Text("와키타키").font(.largeTitle.bold())

            Text(statusText)
                .foregroundStyle(peers.connectedPeers.isEmpty ? .secondary : Color.green)

            Spacer()

            if peers.isReceiving {
                Label("수신 중…", systemImage: "speaker.wave.3.fill").font(.title2)
            }

            ZStack {
                Circle()
                    .fill(peers.isTalking ? Color.red : (peers.connectedPeers.isEmpty ? Color.gray : Color.blue))
                    .frame(width: 220, height: 220)
                    .scaleEffect(peers.isTalking ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.15), value: peers.isTalking)
                Text(peers.isTalking ? "말하는 중" : "누르고 말하기")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in peers.beginTalking() }
                    .onEnded { _ in peers.endTalking() }
            )

            Spacer()
        }
        .padding()
        .onAppear { peers.start() }
        .alert("오류", isPresented: Binding(get: { peers.errorMessage != nil }, set: { _ in peers.errorMessage = nil })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(peers.errorMessage ?? "")
        }
    }
}
