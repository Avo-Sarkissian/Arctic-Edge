// ContentView.swift
// ArcticEdge
//
// Session control screen: Start Day arms the classifier; End Day tears it down.
// Arctic Dark aesthetic: near-black background, frosted glass card, SF Pro tracking.

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            // Background: deep slate with a hint of cold blue
            Color(red: 0.07, green: 0.08, blue: 0.10)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Wordmark
                Text("ARCTICEDGE")
                    .font(.system(.largeTitle, design: .default, weight: .black))
                    .tracking(8)
                    .foregroundStyle(.white)

                // Status indicator
                statusCard

                // Primary action button
                actionButton

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding()

            #if DEBUG
            ClassifierDebugHUD()
                .allowsHitTesting(false)
            #endif
        }
    }

    private var statusCard: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(appModel.isDayActive ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 12, height: 12)
            Text(appModel.isDayActive ? "Day Active" : "Ready")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var actionButton: some View {
        Button {
            Task {
                do {
                    if appModel.isDayActive {
                        try await appModel.endDay()
                    } else {
                        try await appModel.startDay()
                    }
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            Text(appModel.isDayActive ? "End Day" : "Start Day")
                .font(.headline)
                .tracking(2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    appModel.isDayActive
                        ? Color.red.opacity(0.8)
                        : Color.blue.opacity(0.8)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
