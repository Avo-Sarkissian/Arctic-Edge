// OnboardingView.swift
// ArcticEdge
//
// Shown once, before the first day.
//
// The job is not to sell the app: the user already installed it. The job is to
// explain why three fairly invasive permissions are about to be requested, in
// terms of what breaks without each one, so the answer is an informed yes rather
// than a reflexive no. A denied location permission silently removes speed,
// distance, and a third of the carving score, and the old app never said so.

import CoreMotion
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings

    @State private var isRequesting = false

    var body: some View {
        ZStack {
            Theme.Gradients.slate.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Spacer(minLength: Theme.Spacing.xl)

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("BEFORE YOUR FIRST DAY").arcticLabel(Theme.Palette.arctic)
                    Text("ArcticEdge needs three things")
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.heading")
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    permissionRow(
                        icon: "location.fill",
                        title: "Location, while using the app",
                        body: "Measures speed and distance, and keeps recording once your phone is in your pocket and the screen locks. Without it, the app still scores your carving but reports no speed, distance, or vertical."
                    )
                    permissionRow(
                        icon: "figure.skiing.downhill",
                        title: "Motion and fitness",
                        body: "Reads the 100 Hz motion sensors the carving score is built from, and tells skiing apart from a chairlift so runs split themselves."
                    )
                    permissionRow(
                        icon: "heart.fill",
                        title: "Health, to save workouts",
                        body: "Records each day as a ski workout and keeps capture alive in the background. Decline it and recording may stop when the screen locks."
                    )
                }

                Spacer()

                Text("Everything stays on your device. Nothing is uploaded, and you can delete all of it from Settings at any time.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await requestPermissions() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if isRequesting {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        }
                        Text(isRequesting ? "WAITING FOR YOUR ANSWER" : "CONTINUE")
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(3)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Theme.Gradients.primaryAction)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.action, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
                .accessibilityIdentifier("onboarding.continue")

                Button("Not now") {
                    settings.hasCompletedOnboarding = true
                }
                .accessibilityIdentifier("onboarding.skip")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: .infinity)

                Spacer(minLength: Theme.Spacing.m)
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
    }

    private func permissionRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.Palette.arctic)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(body)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Requests location up front so the first Start Day is not interrupted by a
    /// prompt. Motion and Health prompt on first use, which iOS handles itself.
    private func requestPermissions() async {
        isRequesting = true
        await appModel.locationAuthorization.requestIfNeeded()
        isRequesting = false
        settings.hasCompletedOnboarding = true
    }
}
