import SwiftUI
import CoreLocation

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: TrackStore
    @EnvironmentObject var recorder: Recorder
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("서버 주소", text: $settings.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("앱 토큰 (선택)", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(checking ? "확인 중…" : "연결 확인") {
                        Task { await check() }
                    }
                    .disabled(checking)
                    if let checkResult {
                        Text(checkResult).font(.caption)
                    }
                } header: {
                    Text("서버")
                } footer: {
                    Text("토큰을 비워 두면 기록은 이 기기에만 저장됩니다. 토큰을 넣으면 개인 서버(location.b-612.kr)와 동기화합니다.")
                }

                Section("상태") {
                    LabeledContent("위치 권한", value: authText)
                    if recorder.authorization != .authorizedAlways {
                        Button("설정 앱에서 '항상 허용' 켜기") {
                            if let u = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(u)
                            }
                        }
                    }
                    LabeledContent("안 올린 점", value: "\(store.pendingPoints)개")
                    LabeledContent("마지막 올림", value: store.lastSyncAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "-")
                    if let e = store.lastSyncError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                    Button("지금 올리기") { Task { await store.sync() } }
                }

                Section("앱") {
                    LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                }
            }
            .navigationTitle("설정")
        }
    }

    private var authText: String {
        switch recorder.authorization {
        case .authorizedAlways: return "항상"
        case .authorizedWhenInUse: return "앱 사용 중에만"
        case .denied: return "거부됨"
        case .restricted: return "제한됨"
        case .notDetermined: return "아직 묻지 않음"
        @unknown default: return "알 수 없음"
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            checkResult = try await API.health() ? "연결됨" : "응답 이상"
        } catch {
            checkResult = error.localizedDescription
        }
    }
}
