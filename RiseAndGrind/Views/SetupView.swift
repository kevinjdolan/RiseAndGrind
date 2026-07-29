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
  let requiredPermissionsReady: Bool
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
  @State private var isShowingSilenceConfirmation = false
  @State private var isShowingSquatCalibration = false
  @State private var squatPracticeRequest: WakeChallengeRequest?
  @State private var testAlarmCount = 3

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          appHealthCard
          wakeChallengeCard
          alarmTestCard
          dangerZone

          Text("RISE & GRIND")
            .font(.caption.weight(.black))
            .tracking(1.8)
            .foregroundStyle(RGTheme.gold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Rig")
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
    .sheet(isPresented: $isShowingSilenceConfirmation) {
      RGDangerSilenceSheet(
        isWorking: isBusy,
        setMute: model.setMute
      )
    }
    .alert(
      "Revert to Factory System Settings?",
      isPresented: $isShowingFactoryResetConfirmation
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Revert Everything", role: .destructive) {
        performFactoryReset()
      }
    } message: {
      Text(
        "This clears every app-owned alarm, alarm-history audit trail, imported sound, setting, mute, and squat challenge, then returns to onboarding. This cannot be undone."
      )
    }
  }

  private var isBusy: Bool {
    isWorking || isAwaitingResult
  }

  private var appHealthCard: some View {
    RGCard(accent: appHealthIsGood ? RGTheme.mint : RGTheme.orange) {
      if appHealthIsGood {
        HStack(spacing: 12) {
          Image(systemName: "heart.text.square.fill")
            .font(.title2.weight(.bold))
            .foregroundStyle(RGTheme.mint)
            .frame(width: 34, height: 34)
            .background(RGTheme.mint.opacity(0.13), in: Circle())

          VStack(alignment: .leading, spacing: 2) {
            Text("App Health")
              .font(.headline.weight(.black))
              .foregroundStyle(RGTheme.cream)
            Text("Access and calendar tracking are healthy")
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          RGStatusPill(text: "Healthy", color: RGTheme.mint, icon: "checkmark.circle.fill")
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("App Health")
        .accessibilityValue("Access and calendar tracking are healthy")
      } else {
        VStack(alignment: .leading, spacing: 16) {
          RGSectionHeading(
            "App Health",
            eyebrow: "Access & calendar tracking",
            detail:
              "Keep required access on and confirm Rise & Grind has checked your calendar recently."
          )

          if requiredPermissionsReady {
            healthStatusRow(
              title: "Required Access",
              detail: "Alarm, Calendar, Notifications, and Motion are ready.",
              icon: "checkmark.shield.fill",
              color: RGTheme.mint
            )
          } else {
            RGPermissionRow(icon: "alarm.fill", title: "AlarmKit", status: alarmAuthorization)
            RGPermissionRow(icon: "calendar", title: "Calendar", status: calendarAuthorization)
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

          Divider().overlay(RGTheme.cream.opacity(0.12))

          trackingRunRow("Last Automation Run", date: lastNightlyRun)
          trackingRunRow("Last Background Run", date: lastBackgroundRefresh)

          if !hasRecentCalendarTrackingRun {
            Label(
              "No Rise & Grind trigger has fired in the last 24 hours",
              systemImage: "clock.badge.exclamationmark.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RGTheme.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.70)
            .allowsTightening(true)

            RGShortcutAutomationLinks()
              .frame(maxWidth: .infinity, alignment: .leading)

            if !automationAcknowledged {
              Button(action: acknowledgeAutomation) {
                Label("I SET IT UP", systemImage: "checkmark.seal.fill")
              }
              .buttonStyle(RGPrimaryButtonStyle())
            }
          }
        }
      }
    }
  }

  private var appHealthIsGood: Bool {
    requiredPermissionsReady && hasRecentCalendarTrackingRun
  }

  private func healthStatusRow(
    title: String,
    detail: String,
    icon: String,
    color: Color
  ) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(RGTheme.cream)
        Text(detail)
          .font(.caption)
          .foregroundStyle(RGTheme.mutedCream)
      }
    } icon: {
      Image(systemName: icon)
        .foregroundStyle(color)
    }
  }

  private func trackingRunRow(_ title: String, date: Date?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(title):")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(RGTheme.cream)
        .lineLimit(1)

      Spacer(minLength: 8)

      Text(date?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(date == nil ? RGTheme.orange : RGTheme.mutedCream)
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .accessibilityElement(children: .combine)
  }

  private var alarmTestCard: some View {
    RGCard(accent: RGTheme.magenta) {
      VStack(alignment: .leading, spacing: 16) {
        RGSectionHeading(
          "Test Alarms at 1 Minute Intervals",
          eyebrow: "Live alarm test"
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
          eyebrow: "Wake Up button consequence"
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

        HStack(spacing: 10) {
          Button {
            isShowingSquatCalibration = true
          } label: {
            Label(
              model.settings.squatCalibration == nil
                ? "CALIBRATE" : "RECALIBRATE",
              systemImage: "scope"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.72)
          }
          .buttonStyle(
            RGConditionalAccentButtonStyle(
              isEmphasized: model.settings.squatCalibration == nil,
              tint: RGTheme.orange
            )
          )
          .disabled(isBusy)

          Button {
            beginSquatPractice()
          } label: {
            Label("PRACTICE", systemImage: "figure.strengthtraining.functional")
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }
          .buttonStyle(
            RGConditionalAccentButtonStyle(
              isEmphasized: model.settings.squatCalibration != nil,
              tint: RGTheme.orange
            )
          )
          .disabled(isBusy)
        }

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

  private var dangerZone: some View {
    RGCard(accent: RGTheme.danger) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          Text("BURN THE PLAYBOOK")
            .font(.caption.weight(.black))
            .tracking(1.8)
            .foregroundStyle(RGTheme.danger)

          Text("Danger Zone")
            .font(.title2.weight(.black))
            .foregroundStyle(RGTheme.cream)
        }

        Button(role: .destructive) {
          isShowingSilenceConfirmation = true
        } label: {
          Label(
            "Silence Me, You Weak Beta Loser",
            systemImage: "speaker.slash.fill"
          )
          .lineLimit(1)
          .minimumScaleFactor(0.68)
          .allowsTightening(true)
        }
        .buttonStyle(RGDangerButtonStyle())
        .disabled(isBusy)

        Button(role: .destructive) {
          isShowingFactoryResetConfirmation = true
        } label: {
          Label(
            "Revert to Factory System Settings",
            systemImage: "arrow.counterclockwise.circle.fill"
          )
          .lineLimit(1)
          .minimumScaleFactor(0.68)
          .allowsTightening(true)
        }
        .buttonStyle(RGDangerButtonStyle())
        .disabled(isBusy)
      }
    }
  }

  private var testButtonTitle: String {
    testAlarmCount == 1 ? "ARM 1 TEST ALARM" : "ARM \(testAlarmCount) TEST ALARMS"
  }

  private var hasRecentCalendarTrackingRun: Bool {
    let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
    return [lastNightlyRun, lastBackgroundRefresh]
      .compactMap { $0 }
      .contains { $0 >= cutoff }
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
        ?? "Factory reset could not complete every cleanup step. Review the remaining work and try again."
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

private struct RGDangerSilenceSheet: View {
  @Environment(\.dismiss) private var dismiss

  let isWorking: Bool
  let setMute: @MainActor (AlarmMuteChoice) async -> Void

  @State private var choice = AlarmMuteChoice.day
  @State private var isSubmitting = false
  @State private var referenceDate = Date.now

  var body: some View {
    NavigationStack {
      RGScreenBackground {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 8) {
            Text("CONFIRM RETREAT")
              .font(.caption.weight(.black))
              .tracking(1.8)
              .foregroundStyle(RGTheme.danger)

            Text("Silence Rise & Grind?")
              .font(.title2.weight(.black))
              .foregroundStyle(RGTheme.cream)

            Text(
              "The alarms will stop firing, but every muted alarm stays in Agenda and remains tracked as evidence of your shame."
            )
            .font(.subheadline)
            .foregroundStyle(RGTheme.mutedCream)
            .fixedSize(horizontal: false, vertical: true)
          }

          Picker("Mute duration", selection: $choice) {
            Text("Day").tag(AlarmMuteChoice.day)
            Text("Week").tag(AlarmMuteChoice.week)
            Text("Forever").tag(AlarmMuteChoice.indefinitely)
          }
          .pickerStyle(.segmented)

          Label(muteDetail, systemImage: "speaker.slash.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RGTheme.orange)
            .fixedSize(horizontal: false, vertical: true)

          Spacer(minLength: 0)

          Button(role: .destructive) {
            confirmSilence()
          } label: {
            if isSubmitting {
              ProgressView()
                .tint(RGTheme.cream)
            } else {
              Label("CONFIRM SILENCE", systemImage: "speaker.slash.fill")
            }
          }
          .buttonStyle(RGDangerButtonStyle())
          .disabled(isWorking || isSubmitting)

          Button("Keep the Alarms") {
            dismiss()
          }
          .buttonStyle(RGSecondaryButtonStyle())
          .disabled(isSubmitting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 16)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSubmitting)
        }
      }
    }
    .presentationDetents([.height(470)])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(28)
    .onAppear {
      referenceDate = .now
    }
  }

  private var muteDetail: String {
    guard
      let state = try? SchedulePlanner.muteState(
        for: choice,
        after: referenceDate,
        calendar: .autoupdatingCurrent
      )
    else {
      return "Upcoming alarms will be muted."
    }

    switch state {
    case .until(let expiration):
      return
        "Alarms stay silent until "
        + expiration.formatted(date: .abbreviated, time: .shortened)
        + "."
    case .indefinitely:
      return "Alarms stay silent until you explicitly resume Rise & Grind."
    }
  }

  private func confirmSilence() {
    isSubmitting = true
    Task { @MainActor in
      await setMute(choice)
      isSubmitting = false
      dismiss()
    }
  }
}

private struct RGDangerButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.black))
      .foregroundStyle(RGTheme.cream)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 12)
      .padding(.vertical, 13)
      .frame(minHeight: 54)
      .background(
        LinearGradient(
          colors: [
            RGTheme.danger.opacity(configuration.isPressed ? 0.72 : 0.92),
            RGTheme.magenta.opacity(configuration.isPressed ? 0.68 : 0.86),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .stroke(Color.white.opacity(0.14), lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed ? 0.975 : 1)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}
