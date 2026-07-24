// Permission and nightly-automation status after onboarding.

import AppIntents
import RiseAndGrindCore
import SwiftUI

struct SetupView: View {
  @Environment(AppModel.self) private var model

  @Binding var wakeChallengeSquatCount: Int
  let alarmAuthorization: String
  let calendarAuthorization: String
  let notificationAuthorization: String
  let motionAuthorization: String
  let automationAcknowledged: Bool
  let lastNightlyRun: Date?
  let lastBackgroundRefresh: Date?
  let scheduledTestAlarms: [ScheduledAlarmRecord]
  let isWorking: Bool
  let requestPermissions: @MainActor () async -> RGActionResult?
  let scheduleAlarmTest: @MainActor (Int) async -> RGActionResult?
  let cancelAlarmTest: @MainActor () async -> RGActionResult?
  let acknowledgeAutomation: () -> Void
  let openSettings: () -> Void

  @State private var actionResult: RGActionResult?
  @State private var isAwaitingResult = false
  @State private var isShowingFactoryResetConfirmation = false
  @State private var isShowingSquatCalibration = false
  @State private var squatPracticeRequest: WakeChallengeRequest?
  @State private var testAlarmCount = 3

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          RGCard(accent: RGTheme.gold) {
            VStack(alignment: .leading, spacing: 16) {
              RGSectionHeading(
                "Required access",
                eyebrow: "Permission portfolio",
                detail:
                  "Alarm, full Calendar, Notification, and Motion access stay mandatory."
              )

              RGPermissionRow(
                icon: "alarm.fill",
                title: "AlarmKit",
                status: alarmAuthorization
              )
              RGPermissionRow(
                icon: "calendar",
                title: "Calendar",
                status: calendarAuthorization
              )
              RGPermissionRow(
                icon: "bell.badge.fill",
                title: "Notifications",
                status: notificationAuthorization
              )
              RGPermissionRow(
                icon: "figure.strengthtraining.functional",
                title: "Motion & Fitness",
                status: motionAuthorization
              )

              HStack(spacing: 10) {
                Button {
                  isAwaitingResult = true
                  Task { @MainActor in
                    actionResult = await requestPermissions()
                    isAwaitingResult = false
                  }
                } label: {
                  HStack {
                    if isBusy {
                      ProgressView().tint(RGTheme.ink)
                    } else {
                      Image(systemName: "checkmark.shield.fill")
                    }
                    Text("VERIFY")
                  }
                }
                .buttonStyle(RGPrimaryButtonStyle())
                .disabled(isBusy)

                Button(action: openSettings) {
                  Label("Settings", systemImage: "gearshape.fill")
                }
                .buttonStyle(RGSecondaryButtonStyle())
              }
            }
          }

          automationCard
          wakeChallengeCard
          alarmTestCard
          factoryResetCard

          RGCard(accent: RGTheme.graphite) {
            VStack(alignment: .leading, spacing: 8) {
              Text("RISE & GRIND  ·  0.2.0")
                .font(.caption.weight(.black))
                .tracking(1.5)
                .foregroundStyle(RGTheme.gold)
              Text(
                "A vertically integrated consciousness platform. No productivity claims have been reviewed by the board."
              )
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
            }
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Setup")
    .rgInlineNavigationTitle()
    .sheet(item: $actionResult) { result in
      RGActionResultSheet(result: result)
    }
    .fullScreenCover(isPresented: $isShowingSquatCalibration) {
      SquatCalibrationView { profile in
        model.saveSquatCalibration(profile)
      }
    }
    .fullScreenCover(item: $squatPracticeRequest) { request in
      WakeChallengeView(
        request: request,
        coordinator: WakeChallengeCoordinator.shared,
        calibrationProfile: model.settings.squatCalibration,
        openSettings: model.openSystemSettings,
        purpose: .settingsTest,
        exitSettingsTest: {
          squatPracticeRequest = nil
        }
      )
      .id(request.id)
    }
    .alert(
      "Factory Reset Rise & Grind?",
      isPresented: $isShowingFactoryResetConfirmation
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Erase Everything", role: .destructive) {
        performFactoryReset()
      }
    } message: {
      Text(
        "This clears every app-owned alarm, imported sound, setting, mute, and squat challenge, then returns to onboarding. This cannot be undone."
      )
    }
  }

  private var isBusy: Bool {
    isWorking || isAwaitingResult
  }

  private var automationCard: some View {
    RGCard(accent: RGTheme.mint) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top) {
          RGSectionHeading(
            "The nightly handoff",
            eyebrow: "Shortcuts automation",
            detail:
              "A daily Personal Automation runs Prepare Tomorrow’s Barrage while the app is closed."
          )
          Spacer(minLength: 10)
          RGStatusPill(
            text: automationStatus.text,
            color: automationStatus.color,
            icon: automationStatus.icon
          )
        }

        if let lastNightlyRun {
          Label(
            "Last ran \(lastNightlyRun.formatted(date: .abbreviated, time: .shortened))",
            systemImage:
              isNightlyRunCurrent
              ? "clock.badge.checkmark.fill" : "clock.badge.exclamationmark.fill"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isNightlyRunCurrent ? RGTheme.cream : RGTheme.orange)

          if !isNightlyRunCurrent {
            Text(
              "The daily heartbeat is overdue. The automation may be disabled or missing."
            )
            .font(.caption)
            .foregroundStyle(RGTheme.orange)
          }
        } else {
          Label(
            "No automatic run recorded yet",
            systemImage: "clock.badge.exclamationmark.fill"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(RGTheme.orange)
        }

        if let lastBackgroundRefresh {
          Label(
            "Background safety check ran \(lastBackgroundRefresh.formatted(date: .abbreviated, time: .shortened))",
            systemImage: "arrow.clockwise.circle.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(RGTheme.mutedCream)
        } else {
          Label(
            "No background safety check recorded yet",
            systemImage: "arrow.clockwise.circle"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(RGTheme.mutedCream)
        }

        RGShortcutAutomationLinks()
          .frame(maxWidth: .infinity, alignment: .leading)

        if !automationAcknowledged {
          Button(action: acknowledgeAutomation) {
            Label("I SET IT UP", systemImage: "checkmark.seal.fill")
          }
          .buttonStyle(RGPrimaryButtonStyle())
        }

        Text(
          "iOS requires you to create Personal Automations yourself; apps cannot create or inspect them silently."
        )
        .font(.caption)
        .foregroundStyle(RGTheme.mutedCream)
      }
    }
  }

  private var alarmTestCard: some View {
    RGCard(accent: RGTheme.magenta) {
      VStack(alignment: .leading, spacing: 16) {
        RGSectionHeading(
          "Test the attack stack",
          eyebrow: "Live alarm test",
          detail:
            "The first alarm fires in one minute, then another every minute using your active sound pool. Your nightly barrage stays untouched."
        )

        Stepper(value: $testAlarmCount, in: 1...12) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("Test Alarm Count")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RGTheme.cream)
              Text("One-minute intervals")
                .font(.caption)
                .foregroundStyle(RGTheme.mutedCream)
            }
            Spacer()
            Text("\(testAlarmCount)")
              .font(.subheadline.monospacedDigit().weight(.bold))
              .foregroundStyle(RGTheme.gold)
          }
        }

        Button {
          run { await scheduleAlarmTest(testAlarmCount) }
        } label: {
          Label(testButtonTitle, systemImage: "alarm.waves.left.and.right.fill")
        }
        .buttonStyle(RGPrimaryButtonStyle())
        .disabled(isBusy)

        if !scheduledTestAlarms.isEmpty {
          Button {
            run(cancelAlarmTest)
          } label: {
            Label("Cancel Test Alarms", systemImage: "xmark.circle.fill")
          }
          .buttonStyle(RGSecondaryButtonStyle())
          .disabled(isBusy)
        }
      }
    }
  }

  private var wakeChallengeCard: some View {
    RGCard(accent: RGTheme.gold) {
      VStack(alignment: .leading, spacing: 16) {
        RGSectionHeading(
          "Squat Challenge",
          eyebrow: "Wake Up button consequence",
          detail:
            "Tap Wake Up, Loser! and complete this many phone-counted squats to cancel the remaining attacks. Calibration and challenges both use the same two-handed kettlebell hold."
        )

        Stepper(
          value: $wakeChallengeSquatCount,
          in: RiseAndGrindSettings.wakeChallengeSquatCountRange,
          step: 1
        ) {
          HStack(spacing: 12) {
            Image(systemName: "figure.strengthtraining.functional")
              .font(.headline.weight(.bold))
              .foregroundStyle(RGTheme.gold)
              .frame(width: 34, height: 34)
              .background(RGTheme.gold.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
              Text("Required Squats")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RGTheme.cream)
              Text("Used for your next squat challenge")
                .font(.caption)
                .foregroundStyle(RGTheme.mutedCream)
            }

            Spacer(minLength: 8)

            Text("\(wakeChallengeSquatCount)")
              .font(.title3.monospacedDigit().weight(.black))
              .foregroundStyle(RGTheme.gold)
          }
        }
        .accessibilityLabel("Required wake challenge squats")
        .accessibilityValue("\(wakeChallengeSquatCount) squats")
        .accessibilityHint("Adjusts in one-squat increments")

        Divider()
          .overlay(RGTheme.graphite)

        Button {
          isShowingSquatCalibration = true
        } label: {
          Label(
            model.settings.squatCalibration == nil
              ? "CALIBRATE MY SQUAT" : "RECALIBRATE MY SQUAT",
            systemImage: "scope"
          )
        }
        .buttonStyle(RGPrimaryButtonStyle())
        .disabled(isBusy)

        Button {
          beginSquatPractice()
        } label: {
          Label(
            "PRACTICE MY SQUAT",
            systemImage: "figure.strengthtraining.functional"
          )
        }
        .buttonStyle(RGSecondaryButtonStyle())
        .disabled(isBusy)

        if let squatCalibration = model.settings.squatCalibration {
          HStack {
            Label(
              squatCalibration.source == .estimatedFiveFootFour
                ? "5'4\" default" : "Calibrated",
              systemImage: "checkmark.seal.fill"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(RGTheme.mint)
            Spacer()
            Text(
              "\(Int((squatCalibration.observedVerticalDropMeters * 100).rounded())) cm · \(squatCalibration.calibratedAt.formatted(date: .abbreviated, time: .omitted))"
            )
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(RGTheme.mutedCream)
          }
        }

      }
    }
  }

  private var factoryResetCard: some View {
    RGCard(accent: RGTheme.danger) {
      VStack(alignment: .leading, spacing: 16) {
        RGSectionHeading(
          "Factory Reset",
          eyebrow: "Burn the playbook",
          detail:
            "Clear every Rise & Grind alarm and erase all app-owned settings and imported audio."
        )

        Button(role: .destructive) {
          isShowingFactoryResetConfirmation = true
        } label: {
          Label("FACTORY RESET", systemImage: "trash.fill")
        }
        .buttonStyle(RGSecondaryButtonStyle())
        .disabled(isBusy)

        Text(
          "iOS permission grants stay in Settings. Remove any existing Personal Automation separately in Shortcuts."
        )
        .font(.caption)
        .foregroundStyle(RGTheme.mutedCream)
      }
    }
  }

  private var testButtonTitle: String {
    testAlarmCount == 1 ? "ARM 1 TEST ALARM" : "ARM \(testAlarmCount) TEST ALARMS"
  }

  private var isNightlyRunCurrent: Bool {
    guard let lastNightlyRun else { return false }
    return lastNightlyRun > Date.now.addingTimeInterval(-36 * 60 * 60)
  }

  private var automationStatus: (text: String, color: Color, icon: String) {
    if isNightlyRunCurrent {
      return ("Recent run", RGTheme.mint, "checkmark.circle.fill")
    }
    if lastNightlyRun != nil {
      return ("Overdue", RGTheme.orange, "exclamationmark.circle.fill")
    }
    if automationAcknowledged {
      return ("Unverified", RGTheme.orange, "questionmark.circle.fill")
    }
    return ("Not confirmed", RGTheme.orange, "exclamationmark.circle.fill")
  }

  private func run(_ action: @escaping @MainActor () async -> RGActionResult?) {
    isAwaitingResult = true
    Task { @MainActor in
      actionResult = await action()
      isAwaitingResult = false
    }
  }

  private func beginSquatPractice() {
    let sourceAlarmID = UUID()
    squatPracticeRequest = WakeChallengeRequest(
      id: UUID(),
      sourceAlarmID: sourceAlarmID,
      setID: sourceAlarmID,
      sourceSound: .system,
      isCanonical: false,
      owner: .test,
      additionalOwner: nil,
      startedAt: .now,
      targetSquats: wakeChallengeSquatCount,
      suppressionUntil: nil,
      countingStartedAt: nil,
      expiresAt: .distantFuture
    )
  }

  private func performFactoryReset() {
    isAwaitingResult = true
    Task { @MainActor in
      let didReset = await model.factoryReset()
      isAwaitingResult = false
      guard !didReset else { return }

      let message =
        model.errorMessage
        ?? "Factory reset could not complete. Your local settings were not erased."
      model.clearError()
      actionResult = RGActionResult(
        eyebrow: "Factory reset stopped",
        title: "Reset did not complete",
        message: message,
        icon: "exclamationmark.triangle.fill",
        accent: RGTheme.danger
      )
    }
  }

}
