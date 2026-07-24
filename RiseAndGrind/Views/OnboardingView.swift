// Required first-run explanation, configuration, permissions, and automation handoff.

import AppIntents
import RiseAndGrindCore
import SwiftUI

struct OnboardingView: View {
  @Binding var settings: RiseAndGrindSettings
  let alarmAuthorization: String
  let calendarAuthorization: String
  let notificationAuthorization: String
  let motionAuthorization: String
  let requiredPermissionsReady: Bool
  let automationAcknowledged: Bool
  let onboardingCompleted: Bool
  let isWorking: Bool
  let requestPermissions: () -> Void
  let acknowledgeAutomation: () -> Void
  let complete: () -> Void
  let openSettings: () -> Void

  @State private var step = 0
  @State private var isShowingSquatCalibration = false

  var body: some View {
    RGScreenBackground {
      VStack(spacing: 0) {
        progressHeader

        ScrollView {
          VStack(spacing: 18) {
            switch step {
            case 0:
              welcomeStep
            case 1:
              policyStep
            case 2:
              permissionsStep
            case 3:
              squatCalibrationStep
            default:
              automationStep
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 18)
          .padding(.bottom, 34)
        }
      }
    }
    .onAppear {
      if onboardingCompleted, !requiredPermissionsReady {
        step = 2
      } else if onboardingCompleted, settings.squatCalibration?.isUsable != true {
        step = 3
      } else if onboardingCompleted, !automationAcknowledged {
        step = 4
      }
    }
    .fullScreenCover(isPresented: $isShowingSquatCalibration) {
      SquatCalibrationView { profile in
        settings.squatCalibration = profile
      }
    }
  }

  private var progressHeader: some View {
    HStack(spacing: 8) {
      ForEach(0..<5, id: \.self) { index in
        Capsule()
          .fill(index <= step ? RGTheme.gold : RGTheme.graphite)
          .frame(height: 5)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Onboarding step \(step + 1) of 5")
  }

  private var welcomeStep: some View {
    VStack(spacing: 18) {
      Image("BrandHero")
        .resizable()
        .scaledToFit()
        .frame(width: 190, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Rise & Grind")
          .font(.largeTitle.weight(.black))
          .tracking(1.3)
          .foregroundStyle(RGTheme.brandGradient)
        Text("Sleep is for the Weak\nLevel Up and Outwork Everyone")
          .font(.title3.weight(.heavy))
          .foregroundStyle(RGTheme.cream)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.8)

        VStack(spacing: 2) {
          Text("You're no Lazy NPC")
            .font(.title3.weight(.regular))
            .foregroundStyle(RGTheme.cream)
          Text("Amp yourself up to Beast Mode every")
            .font(.body)
            .foregroundStyle(RGTheme.mutedCream)
          Text("morning with an Alpha-Optimized Sonic Assault")
            .font(.body)
            .foregroundStyle(RGTheme.mutedCream)
        }
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
      }

      RGCard(accent: RGTheme.magenta) {
        VStack(alignment: .leading, spacing: 12) {
          RGLimitRow(
            icon: "calendar.badge.clock",
            title: "Calendarmaxxed:",
            detail:
              "Never miss an early meeting after a night of working hard and playing hard by syncing your calendar; Rise & Grind’s got you covered Bro."
          )
          RGLimitRow(
            icon: "alarm.waves.left.and.right.fill",
            title: "Unrelenting Barrage of Entrepreneurial Energy",
            detail:
              "Snooze is for Betas. Rise & Grind is not your Weak father's Weak alarm clock; it's a Relentless Megadose of Discipline Charged Power Brahski."
          )
          RGLimitRow(
            icon: "shuffle",
            title: "Never Let ’Em Know Your Next Move:",
            detail:
              "Curate a pool of high-adrenaline sounds to keep it unpredictably spicy in the bedroom my Sweet Brother in Christ Almighty. 🙏"
          )
        }
      }

      nextButton("LET’S GET THAT BREAD") {
        withAnimation { step = 1 }
      }
    }
  }

  private var policyStep: some View {
    VStack(spacing: 18) {
      RGSectionHeading(
        "Grind Time Configuration",
        eyebrow: "Step 2 · Grind Time"
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      RGCard(accent: RGTheme.gold) {
        VStack(alignment: .leading, spacing: 16) {
          RGTimePicker(
            title: "Grind Time",
            detail: "Target wake-up time",
            hour: $settings.grindHour,
            minute: $settings.grindMinute
          )

          Divider().overlay(RGTheme.cream.opacity(0.12))

          RGDurationEditor(
            title: "Event Buffer",
            detail: "Time before earliest event to target wake-up",
            minutes: $settings.eventBufferMinutes
          )
        }
      }

      RGCard(accent: RGTheme.magenta) {
        VStack(alignment: .leading, spacing: 15) {
          RGSectionHeading("Attack Stack Configuration")
          RGLadderEditor(
            count: $settings.barrage.alarmCount,
            spacingMinutes: $settings.barrage.spacingMinutes,
            finalWarningMinutes: $settings.barrage.finalWarningMinutes
          )
        }
      }

      RGScenarioSimulator(
        count: settings.barrage.alarmCount,
        spacingMinutes: settings.barrage.spacingMinutes,
        finalWarningMinutes: settings.barrage.finalWarningMinutes,
        grindHour: settings.grindHour,
        grindMinute: settings.grindMinute,
        eventBufferMinutes: settings.eventBufferMinutes
      )

      navigationButtons(nextTitle: "HUSTLE") {
        withAnimation { step = 2 }
      }
    }
  }

  private var permissionsStep: some View {
    VStack(spacing: 18) {
      RGSectionHeading(
        onboardingCompleted ? "Access needs attention" : "Grant the required access",
        eyebrow: "Step 3 · System permissions",
        detail:
          "The app stays locked until all required access is available. Rise & Grind does not need broad Photos access."
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      RGCard(accent: requiredPermissionsReady ? RGTheme.mint : RGTheme.orange) {
        VStack(alignment: .leading, spacing: 16) {
          RGPermissionRow(icon: "alarm.fill", title: "Alarms", status: alarmAuthorization)
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

          Button(action: requestPermissions) {
            HStack {
              if isWorking {
                ProgressView().tint(RGTheme.ink)
              } else {
                Image(systemName: "checkmark.shield.fill")
              }
              Text(requiredPermissionsReady ? "ACCESS READY" : "GRANT REQUIRED ACCESS")
            }
          }
          .buttonStyle(RGPrimaryButtonStyle())
          .disabled(isWorking || requiredPermissionsReady)

          if !requiredPermissionsReady {
            Button(action: openSettings) {
              Label("Open iPhone Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(RGSecondaryButtonStyle())
          }
        }
      }

      navigationButtons(nextTitle: "CALIBRATE", nextDisabled: !requiredPermissionsReady) {
        withAnimation { step = 3 }
      }
    }
  }

  private var squatCalibrationStep: some View {
    VStack(spacing: 18) {
      RGSectionHeading(
        "Teach us your squat",
        eyebrow: "Step 4 · Personal calibration",
        detail:
          "One guided squat teaches Rise & Grind how your phone moves in a two-handed kettlebell hold, so a bow will not count and your real squat will."
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      RGCard(
        accent: settings.squatCalibration?.isUsable == true
          ? RGTheme.mint : RGTheme.orange
      ) {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 13) {
            Image(systemName: "figure.strengthtraining.functional")
              .font(.title2.weight(.bold))
              .foregroundStyle(RGTheme.gold)
              .frame(width: 42, height: 42)
              .background(RGTheme.gold.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
              Text("Three poses, three taps")
                .font(.headline.weight(.black))
                .foregroundStyle(RGTheme.cream)
              Text(
                "Hold the iPhone in both hands in front of your chest like a kettlebell, with the screen facing you. Tap once while standing, once at squat depth, and once after you return upright."
              )
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
              .fixedSize(horizontal: false, vertical: true)
            }
          }

          if let profile = settings.squatCalibration, profile.isUsable {
            HStack {
              Label(
                profile.source == .estimatedFiveFootFour
                  ? "5'4\" DEFAULT" : "CALIBRATED",
                systemImage: "checkmark.seal.fill"
              )
              .font(.caption.weight(.black))
              .tracking(1)
              .foregroundStyle(RGTheme.mint)
              Spacer()
              Text(
                "\(Int((profile.observedVerticalDropMeters * 100).rounded())) cm profile"
              )
              .font(.caption.monospacedDigit().weight(.bold))
              .foregroundStyle(RGTheme.cream)
            }
          }

          Button {
            isShowingSquatCalibration = true
          } label: {
            Label(
              settings.squatCalibration?.isUsable == true
                ? "RECALIBRATE MY SQUAT" : "CALIBRATE MY SQUAT",
              systemImage: "scope"
            )
          }
          .buttonStyle(RGPrimaryButtonStyle())

          if settings.squatCalibration?.isUsable != true {
            Button {
              settings.squatCalibration = .estimatedFiveFootFour()
              withAnimation { step = 4 }
            } label: {
              Label("Do This Later", systemImage: "figure.walk")
            }
            .buttonStyle(RGSecondaryButtonStyle())

            Text(
              "We'll use a conservative 5'4\" handheld-squat profile. Recalibrate anytime in Setup for a more personal fit."
            )
            .font(.caption)
            .foregroundStyle(RGTheme.mutedCream)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      navigationButtons(
        nextTitle: "AUTOMATE",
        nextDisabled: settings.squatCalibration?.isUsable != true
      ) {
        withAnimation { step = 4 }
      }
    }
  }

  private var automationStep: some View {
    VStack(spacing: 18) {
      RGSectionHeading(
        "Schedule the nightly check",
        eyebrow: "Step 5 · Shortcuts",
        detail:
          "This one piece is user-confirmed because iOS does not let apps create or inspect Personal Automations."
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      RGCard(accent: RGTheme.mint) {
        VStack(alignment: .leading, spacing: 14) {
          RGAutomationStep(number: 1, text: "Open Shortcuts below, then tap Automation → +.")
          RGAutomationStep(
            number: 2, text: "Choose Time of Day, 9:00 PM, Daily, and Run Immediately.")
          RGAutomationStep(
            number: 3, text: "Add the Rise & Grind action “Prepare Tomorrow’s Barrage.”")

          RGShortcutAutomationLinks()
            .frame(maxWidth: .infinity, alignment: .leading)

          if automationAcknowledged {
            Label("NIGHTLY AUTOMATION CONFIRMED", systemImage: "checkmark.seal.fill")
              .font(.headline.weight(.black))
              .foregroundStyle(RGTheme.mint)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 13)
              .background(RGTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
          } else {
            Button(action: acknowledgeAutomation) {
              Label("I SET IT UP", systemImage: "square.dashed.inset.filled")
            }
            .buttonStyle(RGPrimaryButtonStyle())
          }
        }
      }

      navigationButtons(nextTitle: "GRIND", nextDisabled: !automationAcknowledged) {
        complete()
      }
    }
  }

  private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: "arrow.right")
    }
    .buttonStyle(RGPrimaryButtonStyle())
  }

  private func navigationButtons(
    nextTitle: String,
    nextDisabled: Bool = false,
    next: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 10) {
      Button {
        withAnimation { step = max(0, step - 1) }
      } label: {
        Image(systemName: "arrow.left")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(RGSecondaryButtonStyle())

      Button(action: next) {
        Label(nextTitle, systemImage: "arrow.right")
      }
      .buttonStyle(RGPrimaryButtonStyle())
      .disabled(nextDisabled)
      .opacity(nextDisabled ? 0.45 : 1)
    }
  }
}
