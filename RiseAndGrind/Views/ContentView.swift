// Gates the app behind onboarding and bridges AppModel into the five-tab shell.

import RiseAndGrindCore
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedTab = AppTab.grind
  @State private var wakeChallenge = WakeChallengeCoordinator.shared
  @State private var isShowingCannotRightNowOverlay = false

  var body: some View {
    @Bindable var model = model

    ZStack {
      Group {
        if let request = wakeChallenge.pending {
          WakeChallengeView(
            request: request,
            coordinator: wakeChallenge,
            calibrationProfile: model.settings.squatCalibration,
            openSettings: model.openSystemSettings,
            showCannotRightNowOverlay: {
              withAnimation(.easeOut(duration: 0.2)) {
                isShowingCannotRightNowOverlay = true
              }
            }
          )
          .id(request.id)
        } else if model.isAppReady {
          appTabs(model: model)
        } else {
          OnboardingView(
            settings: $model.settings,
            alarmAuthorization: model.alarmAuthorization,
            calendarAuthorization: model.calendarAuthorization,
            notificationAuthorization: model.notificationAuthorization,
            motionAuthorization: model.motionAuthorization,
            requiredPermissionsReady: model.requiredPermissionsReady,
            automationAcknowledged: model.automationAcknowledged,
            onboardingCompleted: model.onboardingCompleted,
            isWorking: model.isWorking,
            requestPermissions: {
              Task { await model.requestRequiredPermissions() }
            },
            acknowledgeAutomation: model.acknowledgeAutomation,
            complete: model.completeOnboarding,
            openSettings: model.openSystemSettings
          )
          // A factory reset mints a new run so onboarding restarts at the intro
          // pitch instead of holding the step the last run ended on.
          .id(model.onboardingRunID)
        }
      }
      .allowsHitTesting(!isShowingCannotRightNowOverlay)
      .accessibilityHidden(isShowingCannotRightNowOverlay)

      if isShowingCannotRightNowOverlay {
        CannotRightNowOverlay {
          withAnimation(.easeOut(duration: 0.18)) {
            isShowingCannotRightNowOverlay = false
          }
        }
        .transition(.opacity)
        .zIndex(10)
      }
    }
    .tint(RGTheme.gold)
    .onChange(of: wakeChallenge.pending?.id) { oldValue, newValue in
      if oldValue == nil, newValue != nil {
        isShowingCannotRightNowOverlay = false
        model.stopSoundPreview()
      } else if oldValue != nil, newValue == nil {
        Task { await model.refresh(reportErrors: false) }
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase != .active {
        isShowingCannotRightNowOverlay = false
      }
    }
    .alert(
      "Boardroom incident",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { isPresented in
          if !isPresented { model.clearError() }
        }
      )
    ) {
      Button("Acknowledge") {
        model.clearError()
      }
    } message: {
      Text(model.errorMessage ?? "An unknown operational headwind occurred.")
    }
  }

  private func appTabs(model: AppModel) -> some View {
    @Bindable var model = model

    return TabView(selection: $selectedTab) {
      NavigationStack {
        DashboardView(
          settings: $model.settings,
          muteState: model.muteState,
          scheduledPowerNaps: model.scheduledPowerNaps,
          isWorking: model.isWorking,
          schedulePowerNap: { fireDate in
            await model.schedulePowerNap(at: fireDate) != nil
          },
          clearMute: model.clearMute
        )
      }
      .tag(AppTab.grind)
      .tabItem {
        Label("Regimen", systemImage: "alarm.waves.left.and.right.fill")
      }

      NavigationStack {
        BarrageView(
          alarmLedger: model.alarmLedger,
          calendarInfluences: model.calendarInfluences,
          setCalendarInfluenceIgnored: { influence, isIgnored in
            await model.setCalendarInfluenceIgnored(
              influence,
              isIgnored: isIgnored
            )
          },
          setAlarmUserOverride: { alarmID, userOverride in
            await model.setAlarmUserOverride(
              userOverride,
              for: alarmID
            )
          }
        )
      }
      .tag(AppTab.agenda)
      .tabItem {
        Label("Agenda", systemImage: "calendar.badge.clock")
      }

      NavigationStack {
        AlarmSoundsView(
          selectedSoundIDs: $model.settings.selectedSoundIDs,
          sounds: model.availableSounds,
          isImporting: model.isImporting,
          previewingSoundID: model.previewingSoundID,
          preview: model.preview,
          toggle: model.toggleSound,
          importAudio: model.importAudio,
          importVideo: model.importVideo,
          editImportedVideo: model.editImportedVideo,
          reportError: model.reportError
        )
      }
      .tag(AppTab.sounds)
      .tabItem {
        Label("Arsenal", systemImage: "music.note.list")
      }

      NavigationStack {
        SetupView(
          wakeChallengeSquatCount: $model.settings.wakeChallengeSquatCount,
          alarmAuthorization: model.alarmAuthorization,
          calendarAuthorization: model.calendarAuthorization,
          notificationAuthorization: model.notificationAuthorization,
          motionAuthorization: model.motionAuthorization,
          requiredPermissionsReady: model.requiredPermissionsReady,
          automationAcknowledged: model.automationAcknowledged,
          lastNightlyRun: model.lastNightlyRun,
          lastBackgroundRefresh: model.lastBackgroundRefresh,
          scheduledTestAlarms: model.scheduledTestAlarms,
          isWorking: model.isWorking,
          requestPermissions: {
            await model.requestRequiredPermissions()
            return accessCheckResult(from: model)
          },
          scheduleAlarmTest: { count in
            guard let records = await model.scheduleAlarmTest(count: count) else {
              return nil
            }
            return alarmTestResult(records: records)
          },
          cancelAlarmTest: {
            guard await model.cancelAlarmTest() else { return nil }
            return RGActionResult(
              eyebrow: "Live alarm test",
              title: "Test alarms cancelled",
              message: "Your normal nightly barrage was not changed.",
              icon: "checkmark.circle.fill",
              accent: RGTheme.mint
            )
          },
          acknowledgeAutomation: model.acknowledgeAutomation,
          openSettings: model.openSystemSettings
        )
      }
      .tag(AppTab.setup)
      .tabItem {
        Label("Rig", systemImage: "box.truck.fill")
      }
    }
    .rgTabBarAppearance()
    .overlay(alignment: .bottom) {
      if let sound = nowPlayingSound(in: model) {
        RGNowPlayingPill(sound: sound) {
          model.stopSoundPreview()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 70)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy(duration: 0.24), value: model.previewingSoundID)
    .onChange(of: selectedTab) { _, _ in
      model.stopSoundPreview()
    }
  }

  private func nowPlayingSound(in model: AppModel) -> AlarmSoundChoice? {
    guard let previewingSoundID = model.previewingSoundID else { return nil }
    return model.availableSounds.first { $0.id == previewingSoundID }
  }

  private func accessCheckResult(from model: AppModel) -> RGActionResult? {
    guard model.errorMessage == nil else { return nil }

    let accessIsReady = model.requiredPermissionsReady
    return RGActionResult(
      eyebrow: "Permission portfolio",
      title: accessIsReady ? "Access confirmed" : "Access needs attention",
      message:
        "AlarmKit: \(model.alarmAuthorization). Calendar: \(model.calendarAuthorization). Notifications: \(model.notificationAuthorization). Motion: \(model.motionAuthorization).",
      icon: accessIsReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
      accent: accessIsReady ? RGTheme.mint : RGTheme.orange
    )
  }

  private func alarmTestResult(records: [ScheduledAlarmRecord]) -> RGActionResult {
    let first = records.first?.fireDate.formatted(date: .omitted, time: .shortened) ?? "—"
    let last = records.last?.fireDate.formatted(date: .omitted, time: .shortened) ?? "—"
    let title = records.count == 1 ? "1 test alarm armed" : "\(records.count) test alarms armed"
    let timing = records.count == 1 ? "at \(first)" : "from \(first) through \(last)"
    return RGActionResult(
      eyebrow: "Live alarm test",
      title: title,
      message:
        "Your test is queued \(timing), at one-minute intervals. It rotates through your active sounds without changing the nightly barrage.",
      icon: "alarm.waves.left.and.right.fill",
      accent: RGTheme.mint
    )
  }
}

private struct CannotRightNowOverlay: View {
  let dismiss: () -> Void

  var body: some View {
    Button(action: dismiss) {
      GeometryReader { proxy in
        ZStack {
          Image("CantRightNowOverlay")
            .resizable()
            .scaledToFill()
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .accessibilityHidden(true)

          LinearGradient(
            colors: [
              RGTheme.ink.opacity(0.80),
              RGTheme.ink.opacity(0.12),
              RGTheme.ink.opacity(0.18),
              RGTheme.ink.opacity(0.72),
            ],
            startPoint: .top,
            endPoint: .bottom
          )

          VStack(spacing: 12) {
            Label("STRATEGIC RETREAT", systemImage: "bed.double.fill")
              .font(.caption.weight(.black))
              .tracking(1.7)
              .foregroundStyle(RGTheme.gold)

            Text("NOT THIS ONE.")
              .font(.system(size: 38, weight: .black, design: .rounded))
              .tracking(0.5)
              .foregroundStyle(RGTheme.cream)

            Text("This attack is over. The rest of the stack stays armed.")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(RGTheme.mutedCream)
              .multilineTextAlignment(.center)

            Spacer()

            Label("TAP ANYWHERE TO DISMISS", systemImage: "hand.tap.fill")
              .font(.caption2.weight(.black))
              .tracking(1)
              .foregroundStyle(RGTheme.cream)
              .padding(.horizontal, 16)
              .padding(.vertical, 11)
              .background(.ultraThinMaterial, in: Capsule())
          }
          .padding(.horizontal, 30)
          .padding(.top, max(proxy.safeAreaInsets.top + 26, 72))
          .padding(.bottom, max(proxy.safeAreaInsets.bottom + 26, 32))
        }
        .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .ignoresSafeArea()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("This wake challenge is over.")
    .accessibilityHint("Double-tap to dismiss the image.")
  }
}

private struct RGNowPlayingPill: View {
  let sound: AlarmSoundChoice
  let stop: () -> Void

  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: "waveform")
        .font(.headline.weight(.black))
        .foregroundStyle(RGTheme.orange)
        .frame(width: 32, height: 32)
        .background(RGTheme.orange.opacity(0.16), in: Circle())

      VStack(alignment: .leading, spacing: 1) {
        Text(sound.displayName)
          .font(.subheadline.weight(.black))
          .foregroundStyle(RGTheme.cream)
          .lineLimit(1)

        Text(nowPlayingMetadata)
          .font(.caption2.weight(.bold))
          .foregroundStyle(RGTheme.mutedCream)
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      Button(action: stop) {
        Label("STOP", systemImage: "stop.fill")
          .font(.caption.weight(.black))
          .foregroundStyle(RGTheme.ink)
          .padding(.horizontal, 12)
          .frame(height: 34)
          .background(RGTheme.gold, in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop preview of \(sound.displayName)")
    }
    .padding(.leading, 10)
    .padding(.trailing, 8)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial, in: Capsule())
    .background(RGTheme.elevatedInk.opacity(0.9), in: Capsule())
    .overlay {
      Capsule().stroke(RGTheme.orange.opacity(0.72), lineWidth: 1)
    }
    .shadow(color: RGTheme.ink.opacity(0.72), radius: 18, y: 8)
  }

  private var nowPlayingMetadata: String {
    let metadata = [sound.artistName, sound.genreName]
      .compactMap { $0 }
      .joined(separator: " · ")
    return metadata.isEmpty ? "Imported sound" : metadata
  }
}

private enum AppTab: Hashable {
  case grind
  case agenda
  case sounds
  case setup
}
