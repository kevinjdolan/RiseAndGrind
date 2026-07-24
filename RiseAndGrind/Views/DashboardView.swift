// The primary Grind Time, event-buffer, and active-day configuration dashboard.

import Foundation
import RiseAndGrindCore
import SwiftUI

struct DashboardView: View {
  @Binding var settings: RiseAndGrindSettings
  let muteState: AlarmMuteState?
  let riseTime: Date?
  let isWorking: Bool
  let setMute: @MainActor (AlarmMuteChoice) async -> Void
  let clearMute: @MainActor () async -> Void

  @State private var presentsMuteSheet = false

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          grindTime
          grindDays

          if let muteState {
            muteStatus(muteState)
          }

          Button {
            presentsMuteSheet = true
          } label: {
            Label(
              "Silence Me, You Weak Beta Loser",
              systemImage: "speaker.slash.fill"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .allowsTightening(true)
          }
          .buttonStyle(RGSecondaryButtonStyle())
          .disabled(isWorking)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Rise & Grind")
    .rgInlineNavigationTitle()
    .sheet(isPresented: $presentsMuteSheet) {
      RGMuteSheet(
        muteState: muteState,
        isWorking: isWorking,
        setMute: { choice in
          await setMute(choice)
          presentsMuteSheet = false
        },
        clearMute: {
          await clearMute()
          presentsMuteSheet = false
        }
      )
    }
  }

  private var grindTime: some View {
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

        Divider().overlay(RGTheme.cream.opacity(0.12))

        RGReadOnlyTimeRow(
          title: "Rise Time",
          detail: "Target time based on current calendar",
          date: displayedRiseTime
        )
      }
    }
  }

  private var displayedRiseTime: Date? {
    riseTime
      ?? (try? SchedulePlanner.tomorrowTargetDate(
        hour: settings.grindHour,
        minute: settings.grindMinute,
        after: .now,
        calendar: .autoupdatingCurrent
      ))
  }

  private var grindDays: some View {
    RGCard(accent: RGTheme.orange) {
      VStack(alignment: .leading, spacing: 14) {
        RGSectionHeading(
          "Active Days",
          eyebrow: "Attack schedule",
          detail: "Choose which mornings are eligible for Grind Time."
        )

        HStack(spacing: 7) {
          ForEach(GrindDay.allCases, id: \.self) { day in
            Button {
              toggle(day)
            } label: {
              Text(day.shortLabel)
                .font(.subheadline.weight(.black))
                .foregroundStyle(
                  settings.enabledDays.contains(day) ? RGTheme.ink : RGTheme.mutedCream
                )
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                  Circle()
                    .fill(
                      settings.enabledDays.contains(day)
                        ? RGTheme.gold
                        : RGTheme.graphite.opacity(0.72)
                    )
                }
                .overlay {
                  Circle()
                    .stroke(
                      settings.enabledDays.contains(day)
                        ? RGTheme.orange.opacity(0.72)
                        : RGTheme.cream.opacity(0.12),
                      lineWidth: 1
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.fullName)
            .accessibilityValue(
              settings.enabledDays.contains(day) ? "Scheduled" : "Not scheduled"
            )
          }
        }

        Label(daySummary, systemImage: "calendar.badge.clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(RGTheme.mutedCream)
      }
    }
  }

  private var daySummary: String {
    if settings.enabledDays == GrindDay.everyDay {
      return "Every day is locked in"
    }
    if settings.enabledDays
      == Set([
        GrindDay.monday, .tuesday, .wednesday, .thursday, .friday,
      ])
    {
      return "Weekdays are locked in"
    }
    return "\(settings.enabledDays.count) days are locked in"
  }

  private func muteStatus(_ state: AlarmMuteState) -> some View {
    RGCard(accent: RGTheme.orange) {
      VStack(alignment: .leading, spacing: 12) {
        RGSectionHeading(
          "R&G is muted",
          eyebrow: "Attacks paused",
          detail: muteDescription(state)
        )

        Button {
          Task { await clearMute() }
        } label: {
          Label("RESUME NOW", systemImage: "speaker.wave.3.fill")
        }
        .buttonStyle(RGPrimaryButtonStyle())
        .disabled(isWorking)
      }
    }
  }

  private func muteDescription(_ state: AlarmMuteState) -> String {
    switch state {
    case .until(let date):
      return "Attacks resume " + date.formatted(date: .abbreviated, time: .shortened) + "."
    case .indefinitely:
      return "Attacks stay paused until you decide to lock back in."
    }
  }

  private func toggle(_ day: GrindDay) {
    if settings.enabledDays.contains(day) {
      guard settings.enabledDays.count > 1 else { return }
      settings.enabledDays.remove(day)
    } else {
      settings.enabledDays.insert(day)
    }
  }
}

private struct RGMuteSheet: View {
  let muteState: AlarmMuteState?
  let isWorking: Bool
  let setMute: @MainActor (AlarmMuteChoice) async -> Void
  let clearMute: @MainActor () async -> Void

  @State private var muteReferenceDate = Date.now

  var body: some View {
    RGScreenBackground {
      VStack(alignment: .leading, spacing: 16) {
        RGSectionHeading(
          "Mute Rise & Grind",
          eyebrow: "Stand down",
          detail: "Upcoming attacks will stay visible, but they will not fire while R&G is muted."
        )

        muteButton(
          "Tune out until \(formattedMuteDate(for: .day))",
          icon: "sun.horizon.fill",
          choice: .day
        )
        muteButton(
          "Sit on the bench until \(formattedMuteDate(for: .week))",
          icon: "calendar.badge.minus",
          choice: .week
        )
        muteButton(
          "Neutralize Yourself Until Further Notice",
          icon: "speaker.slash.fill",
          choice: .indefinitely
        )

        if muteState != nil {
          Divider().overlay(RGTheme.cream.opacity(0.12))

          Button {
            Task { await clearMute() }
          } label: {
            Label("Resume R&G now", systemImage: "speaker.wave.3.fill")
          }
          .buttonStyle(RGPrimaryButtonStyle())
          .disabled(isWorking)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 24)
      .padding(.bottom, 18)
    }
    .presentationDetents([muteState == nil ? .height(390) : .height(465)])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(28)
  }

  private func muteButton(
    _ title: String,
    icon: String,
    choice: AlarmMuteChoice
  ) -> some View {
    Button {
      Task { await setMute(choice) }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .frame(width: 24)
        Text(title)
          .lineLimit(1)
          .minimumScaleFactor(0.68)
          .allowsTightening(true)
          .layoutPriority(1)
        Spacer()
        Image(systemName: "speaker.slash.fill")
          .frame(width: 20)
      }
      .padding(.horizontal, 12)
    }
    .buttonStyle(RGSecondaryButtonStyle())
    .disabled(isWorking)
    .accessibilityLabel(title)
  }

  private func formattedMuteDate(for choice: AlarmMuteChoice) -> String {
    let state = try? SchedulePlanner.muteState(
      for: choice,
      after: muteReferenceDate,
      calendar: .autoupdatingCurrent
    )
    return state?.expirationDate?.formatted(
      .dateTime.month(.abbreviated).day().hour().minute()
    ) ?? "later"
  }
}
