// MARK: - StandByCamApp.swift
// Swift 5.9+, iOS 17+, SwiftUI lifecycle
import SwiftUI
import AVFoundation
import Photos

@main
struct StandByCamApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { IdleManager.shared.setIdleDisabled(true) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { IdleManager.shared.setIdleDisabled(true) }
        }
    }
}

final class IdleManager {
    static let shared = IdleManager()
    private init() {}
    func setIdleDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
