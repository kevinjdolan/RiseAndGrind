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
  @State private var isShowingAutomationDeferralWarning = false
  @State private var accessCelebrationProgress: CGFloat = 0
  @State private var celebrationButtonGlow: CGFloat = 0

  var body: some View {
    Group {
      if step == 0 {
        IntroPitchView {
          advance()
        }
      } else {
        RGScreenBackground {
          VStack(spacing: 0) {
            progressHeader

            ScrollView {
              VStack(spacing: 18) {
                switch step {
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
              .padding(.bottom, 12)
            }
            .simultaneousGesture(swipeGesture)

            footer
              .padding(.horizontal, 20)
              .padding(.top, 10)
              .padding(.bottom, 14)
          }
        }
      }
    }
    .onAppear {
      if onboardingCompleted, !requiredPermissionsReady {
        step = 2
      } else if onboardingCompleted, settings.squatCalibration?.isUsable != true {
        step = 3
      }
    }
    .fullScreenCover(isPresented: $isShowingSquatCalibration) {
      SquatCalibrationView { profile in
        settings.squatCalibration = profile
      }
    }
    .alert(
      "Set Up the Automation Later?",
      isPresented: $isShowingAutomationDeferralWarning
    ) {
      Button("Go Back", role: .cancel) {}
      Button("Continue Anyway", role: .destructive) {
        complete()
      }
    } message: {
      Text(
        "Without the nightly automation, Rise & Grind cannot reliably re-check tomorrow’s calendar while the app is closed. Open the app before bed or alarms may miss late calendar changes."
      )
    }
  }

  private var progressHeader: some View {
    OnboardingProgressHeader(currentStep: step)
  }

  /// Non-zero only while the access celebration is on screen, so every other
  /// step's footer keeps a plain unlit button.
  private var celebrationGlow: CGFloat {
    guard step == 2, requiredPermissionsReady else { return 0 }
    return celebrationButtonGlow
  }

  private var isNextEnabled: Bool {
    switch step {
    case 2:
      requiredPermissionsReady
    case 4:
      automationAcknowledged
    default:
      true
    }
  }

  private func advance() {
    guard isNextEnabled else { return }
    withAnimation {
      if step == 3, settings.squatCalibration?.isUsable != true {
        settings.squatCalibration = .estimatedFiveFootFour()
      }
      if step >= 4 {
        complete()
      } else {
        step += 1
      }
    }
  }

  private func goBack() {
    withAnimation { step = max(0, step - 1) }
  }

  private var swipeGesture: some Gesture {
    DragGesture(minimumDistance: 40)
      .onEnded { value in
        let horizontal = value.translation.width
        let vertical = value.translation.height
        guard abs(horizontal) > abs(vertical) * 1.5, abs(horizontal) > 60 else { return }
        if horizontal < 0 {
          advance()
        } else if step > 0 {
          goBack()
        }
      }
  }

  @ViewBuilder
  private var footer: some View {
    switch step {
    case 3:
      navigationButtons(
        nextTitle: settings.squatCalibration?.isUsable == true
          ? "Onward and Upward" : "Do this Later"
      ) { advance() }
    case 4 where !automationAcknowledged:
      // Until the automation is confirmed, deferring is the only way forward, so
      // it takes the primary slot instead of a dead disabled button.
      navigationButtons(
        nextTitle: "Later",
        nextIcon: "clock.badge.questionmark"
      ) {
        isShowingAutomationDeferralWarning = true
      }
    default:
      navigationButtons(nextDisabled: !isNextEnabled) { advance() }
    }
  }

  private var policyStep: some View {
    VStack(spacing: 18) {
      RGAlarmConfigurationCard(
        settings: $settings,
        eyebrow: "Step 1: Regimen Setup",
        boxed: false
      )
    }
  }

  @ViewBuilder
  private var permissionsStep: some View {
    if requiredPermissionsReady {
      // Claim the whole scroll viewport so the celebration can centre itself in
      // what is left under the heading rather than hugging it. The inset matches
      // the scroll content's own vertical padding, so nothing starts scrolling.
      VStack(spacing: 18) {
        permissionsHeading
        accessConfirmedCelebration
      }
      .containerRelativeFrame(.vertical, alignment: .top) { height, _ in
        max(height - 30, 240)
      }
    } else {
      VStack(spacing: 18) {
        permissionsHeading
        permissionsContent
      }
    }
  }

  private var permissionsHeading: some View {
    RGSectionHeading(
      "Grant required permissions",
      eyebrow: "Step 3 · System permissions",
      detail:
        "Certain permissions are required to function, but Shad guarantees not to abuse it."
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var permissionsContent: some View {
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
          Text("GRANT REQUIRED ACCESS")
        }
      }
      .buttonStyle(RGPrimaryButtonStyle())
      .disabled(isWorking)

      Button(action: openSettings) {
        Label("Open iPhone Settings", systemImage: "gearshape.fill")
      }
      .buttonStyle(RGSecondaryButtonStyle())
    }
  }

  private static let celebrationCoinDiameter: CGFloat = 240

  private var accessConfirmedCelebration: some View {
    VStack(spacing: 26) {
      Text("ACCESS CONFIRMED")
        .font(.title.weight(.black))
        .foregroundStyle(RGTheme.mint)

      ZStack {
        // Blooms wider than the phone so the light runs off both edges. Every
        // value here rises with progress: SwiftUI interpolates the computed
        // result, so a non-monotonic curve would animate between its endpoints
        // and never actually be seen.
        Circle()
          .fill(RGTheme.mint)
          .frame(
            width: Self.celebrationCoinDiameter,
            height: Self.celebrationCoinDiameter
          )
          .scaleEffect(1.25 + (accessCelebrationProgress * 0.9))
          .blur(radius: 60 + (accessCelebrationProgress * 50))
          .opacity(0.25 + (accessCelebrationProgress * 0.5))

        RGSquatCoinAttentionGlow(
          diameter: Self.celebrationCoinDiameter * 1.15,
          progress: accessCelebrationProgress,
          isActive: true
        )
        RGSquatCoinFace(
          imageName: "SquatCoinUp",
          diameter: Self.celebrationCoinDiameter,
          accent: RGTheme.mint
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      accessCelebrationProgress = 0
      celebrationButtonGlow = 0
      withAnimation(.easeInOut(duration: 2.6)) {
        accessCelebrationProgress = 1
      }
      // A hard flash that settles back to a steady halo, pointing at the button
      // the celebration is about to hand off to.
      withAnimation(.easeOut(duration: 0.5)) {
        celebrationButtonGlow = 1
      }
      withAnimation(.easeInOut(duration: 1.5).delay(0.6)) {
        celebrationButtonGlow = 0.45
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard step == 2 else { return }
        advance()
      }
    }
  }

  private var squatCalibrationStep: some View {
    VStack(spacing: 18) {
      RGSectionHeading(
        "Calibrate your squat (optional)",
        eyebrow: "Step 4 · Personal calibration",
        detail:
          "Every body is different, so Rise & Grind works best if you do this quick 3-step calibration."
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      RGCard(
        accent: settings.squatCalibration?.isUsable == true
          ? RGTheme.mint : RGTheme.orange
      ) {
        VStack(spacing: 20) {
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

          squatCoinSequence
        }
      }
    }
  }

  private var squatCoinSequence: some View {
    VStack(spacing: 10) {
      RGSquatCoinFace(imageName: "SquatCoinUp", diameter: 84, accent: RGTheme.gold)
      Image(systemName: "arrow.down")
        .font(.headline.weight(.black))
        .foregroundStyle(RGTheme.mutedCream)
      RGSquatCoinFace(imageName: "SquatCoinDown", diameter: 84, accent: RGTheme.gold)
      Image(systemName: "arrow.down")
        .font(.headline.weight(.black))
        .foregroundStyle(RGTheme.mutedCream)
      RGSquatCoinFace(imageName: "SquatCoinUp", diameter: 84, accent: RGTheme.gold)
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

          // Confirming is folded into the Add Shortcut button once the user comes
          // back from Shortcuts; deferring lives in the footer.
          RGShortcutAutomationLinks(onConfirmSetup: acknowledgeAutomation)
            .frame(maxWidth: .infinity, alignment: .leading)

          if automationAcknowledged {
            Label("NIGHTLY AUTOMATION CONFIRMED", systemImage: "checkmark.seal.fill")
              .font(.headline.weight(.black))
              .foregroundStyle(RGTheme.mint)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 13)
              .background(RGTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
          }
        }
      }
    }
  }

  private func navigationButtons(
    nextTitle: String = "Onward and Upward",
    nextIcon: String = "arrow.right",
    nextDisabled: Bool = false,
    next: @escaping () -> Void
  ) -> some View {
    GeometryReader { geometry in
      HStack(spacing: 10) {
        Button(action: goBack) {
          Image(systemName: "arrow.left")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RGSecondaryButtonStyle())
        .frame(width: geometry.size.width * 0.25)

        Button(action: next) {
          Label(nextTitle, systemImage: nextIcon)
        }
        .buttonStyle(RGPrimaryButtonStyle())
        .disabled(nextDisabled)
        .opacity(nextDisabled ? 0.45 : 1)
        .shadow(
          color: RGTheme.mint.opacity(0.95 * celebrationGlow),
          radius: 20 * celebrationGlow
        )
        .shadow(
          color: RGTheme.mint.opacity(0.55 * celebrationGlow),
          radius: 48 * celebrationGlow
        )
      }
    }
    .frame(height: 54)
  }
}

/// The five-capsule onboarding progress indicator, reused wherever a step needs to be previewed.
struct OnboardingProgressHeader: View {
  let currentStep: Int

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0..<5, id: \.self) { index in
        Capsule()
          .fill(index <= currentStep ? RGTheme.gold : RGTheme.graphite)
          .frame(height: 5)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Onboarding step \(currentStep + 1) of 5")
  }
}

/// Onboarding step 1's welcome pitch, factored out so it can also be used as the backdrop
/// for the intro pitch's "incoming call" moment.
struct OnboardingWelcomeStepView: View {
  let onContinue: () -> Void

  private var swipeGesture: some Gesture {
    DragGesture(minimumDistance: 40)
      .onEnded { value in
        let horizontal = value.translation.width
        let vertical = value.translation.height
        guard abs(horizontal) > abs(vertical) * 1.5, horizontal < -60 else { return }
        onContinue()
      }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
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
            Text("Level Up and Outperform")
              .font(.title3.weight(.heavy))
              .foregroundStyle(RGTheme.cream)
              .multilineTextAlignment(.center)
              .lineLimit(2)
              .minimumScaleFactor(0.8)

            Text(
              "The Alarm Clock App that just won’t quit,\nlike you once you reach your full potential."
            )
            .font(.body)
            .foregroundStyle(RGTheme.mutedCream)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          }

          RGCard(accent: RGTheme.magenta) {
            VStack(alignment: .leading, spacing: 14) {
              RGLimitRow(
                icon: "calendar.badge.clock",
                title: "Calendarmaxxing™",
                detail:
                  "Sync your calendar so that you’ll never be caught off-guard and miss an early morning meeting"
              )
              RGLimitRow(
                icon: "alarm.waves.left.and.right.fill",
                title: "Gentlemen Make Their Own Luck",
                detail:
                  "Schedule nudges before your target wake up time, gradually increasing in intensity"
              )
              RGLimitRow(
                icon: "figure.strengthtraining.functional",
                title: "Discipline When You Need It",
                detail:
                  "When it’s truly time to wake up, R&G will not relent until you’ve proven you’re up by passing the Grind Time Challenge™"
              )
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
      }
      .simultaneousGesture(swipeGesture)

      Button(action: onContinue) {
        Label("Design Your Own Destiny", systemImage: "arrow.right")
      }
      .buttonStyle(RGPrimaryButtonStyle())
      .padding(.horizontal, 20)
      .padding(.top, 10)
      .padding(.bottom, 14)
    }
  }
}
