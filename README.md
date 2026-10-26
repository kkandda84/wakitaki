# 와키타키 (WakiTaki)

근처의 아이폰끼리 인터넷 없이 연결해 쓰는 눌러서 말하기(PTT) 워키토키 앱.

- 연결: MultipeerConnectivity (블루투스 / P2P Wi-Fi, 암호화 필수)
- 음성: AVAudioEngine, 16kHz mono PCM을 실시간 전송
- 참고: iOS는 아이폰끼리 블루투스 클래식 음성 통화를 직접 지원하지 않아 이 방식을 사용합니다.

## 빌드
1. macOS에서 `brew install xcodegen`
2. `xcodegen generate` → `WakiTaki.xcodeproj` 생성
3. Xcode에서 Signing Team 지정 후 **실제 아이폰 2대**에 설치 (시뮬레이터는 마이크/P2P 제한)
4. 두 기기에서 앱을 열고 로컬 네트워크·마이크 권한 허용 → 자동 연결 → 버튼을 누른 채로 말하기
