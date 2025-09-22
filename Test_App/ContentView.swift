import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = RecordingController()
    @State private var use24h = false
    @State private var showDate = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var showVault = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ClockView(use24h: use24h, showDate: showDate, isRecording: recorder.isRecording)
                .padding(.horizontal, 0)
                .padding(.top, 80)
                .safeAreaPadding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if recorder.isRecording {
                HStack(spacing: 1) { }
                    .padding(1)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.red.opacity(0.01), lineWidth: 0.1))
                    .padding(.top, 22)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .onTapGesture(count: 5) {
            VaultAuth.authenticate { result in
                switch result {
                case .success:
                    showVault = true
                case .failure:
                    showVault = false
                }
            }
        }
        .onTapGesture {
            recorder.isRecording ? recorder.stopRecording() : recorder.startRecording()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                recorder.stopRecording()
                showVault = false
            }
        }
        .sheet(isPresented: $showVault) {
            VideoVaultView()
                .presentationDragIndicator(.hidden)
        }
        .statusBar(hidden: true)
    }
}
