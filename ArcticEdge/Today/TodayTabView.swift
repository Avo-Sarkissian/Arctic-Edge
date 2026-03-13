// TodayTabView.swift
// ArcticEdge
//
// Today tab: ContentView (session control) as the base.
// Two overlays triggered automatically by AppModel state:
//   - fullScreenCover: LiveTelemetryView when classifierStateLabel == "SKIING"
//   - .sheet: PostRunAnalysisView when lastFinalizedRunID becomes non-nil
//
// The user never taps to open either overlay — both are automatic.
// Live view dismisses when classifierStateLabel transitions away from "SKIING".
// Post-run sheet dismisses when user taps the X button (or swipes down).
// A dismissed run ID is tracked so the sheet does not re-present for the same run.

import SwiftUI

struct TodayTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showLive: Bool = false
    @State private var presentedRunID: UUID? = nil
    @State private var dismissedRunIDs: Set<UUID> = []

    var body: some View {
        ContentView()
            .fullScreenCover(isPresented: $showLive) {
                LiveTelemetryView()
                    .environment(appModel)
            }
            .sheet(isPresented: Binding(
                get: { presentedRunID != nil },
                set: { if !$0 { clearPresentedRun() } }
            )) {
                if let runID = presentedRunID {
                    PostRunAnalysisView(runID: runID)
                        .environment(appModel)
                        .onDisappear {
                            clearPresentedRun()
                        }
                }
            }
            .onChange(of: appModel.classifierStateLabel) { _, newLabel in
                let isSkiing = (newLabel == "SKIING")
                if isSkiing != showLive {
                    showLive = isSkiing
                }
            }
            .onChange(of: appModel.lastFinalizedRunID) { _, newID in
                guard let id = newID, !dismissedRunIDs.contains(id) else { return }
                presentedRunID = id
            }
    }

    private func clearPresentedRun() {
        if let id = presentedRunID {
            dismissedRunIDs.insert(id)
        }
        presentedRunID = nil
    }
}
