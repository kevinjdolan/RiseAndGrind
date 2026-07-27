// The primary Grind Time, event-buffer, and active-day configuration dashboard.

import Foundation
import RiseAndGrindCore
import SwiftUI

struct DashboardView: View {
  @Binding var settings: RiseAndGrindSettings
  let muteState: AlarmMuteState?
  let riseTime: Date?
  let scheduledPowerNaps: [ScheduledAlarmRecord]
  let isWorking: Bool
  let schedulePowerNap: @MainActor (Date) async -> Bool
  let setMute: @MainActor (AlarmMuteChoice) async -> Void
  let clearMute: @MainActor () async -> Void

  @State private var presentsMuteSheet = false
  @State private var presentsPowerNapSheet = false
  @State private var powerNapTime = Date.now.addingTimeInterval(20 * 60)

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          grindTime
          grindDays

          powerNapButton
            .buttonStyle(RGSecondaryButtonStyle())
            .disabled(isWorking)

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
    .navigationTitle("Regimen")
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
    .sheet(isPresented: $presentsPowerNapSheet) {
      RGPowerNapSheet(
        fireDate: $powerNapTime,
        isWorking: isWorking,
        schedule: schedulePowerNap
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

  private var activePowerNap: ScheduledAlarmRecord? {
    scheduledPowerNaps
      .filter { $0.fireDate > .now }
      .sorted { $0.fireDate < $1.fireDate }
      .first
  }

  private var powerNapButton: some View {
    Button {
      powerNapTime = activePowerNap?.fireDate ?? Date.now.addingTimeInterval(20 * 60)
      presentsPowerNapSheet = true
    } label: {
      HStack(spacing: 10) {
        Image(systemName: activePowerNap == nil ? "bed.double.fill" : "bed.double.circle.fill")
          .font(.headline.weight(.bold))

        VStack(alignment: .leading, spacing: 2) {
          Text(activePowerNap == nil ? "Power Nap" : "Power Nap Armed")
            .lineLimit(1)

          if let activePowerNap {
            Text(activePowerNap.fireDate.formatted(date: .omitted, time: .shortened))
              .font(.caption.monospacedDigit().weight(.bold))
              .foregroundStyle(RGTheme.gold)
          }
        }

        Spacer(minLength: 8)

        if activePowerNap != nil {
          Text("ARMED")
            .font(.caption2.weight(.black))
            .tracking(0.8)
            .foregroundStyle(RGTheme.gold)
        }
      }
    }
    .accessibilityLabel(
      activePowerNap == nil ? "Set Power Nap" : "Power Nap armed"
    )
    .accessibilityValue(
      activePowerNap?.fireDate.formatted(date: .omitted, time: .shortened) ?? "Not armed"
    )
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

private struct RGPowerNapSheet: View {
  @Environment(\.dismiss) private var dismiss

  @Binding var fireDate: Date
  let isWorking: Bool
  let schedule: @MainActor (Date) async -> Bool

  @State private var minimumFireDate = Date.now

  var body: some View {
    NavigationStack {
      Form {
        Section {
          DatePicker(
            "Power Nap alarm time",
            selection: $fireDate,
            in: minimumFireDate...,
            displayedComponents: .hourAndMinute
          )
          .datePickerStyle(.wheel)
          .labelsHidden()
          .frame(maxWidth: .infinity)
          .accessibilityLabel("Power Nap alarm time")
        } header: {
          Text("Wake me at")
        } footer: {
          Text("There is no snooze. Completing your configured wake challenge is required.")
        }
      }
      .navigationTitle("Power Nap")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        Button {
          Task {
            guard await schedule(fireDate) else { return }
            dismiss()
          }
        } label: {
          if isWorking {
            ProgressView()
              .tint(RGTheme.ink)
          } else {
            Text("A Little Rest to Beat the Rest!")
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }
        }
        .buttonStyle(RGPrimaryButtonStyle())
        .disabled(isWorking || fireDate <= minimumFireDate)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isWorking)
        }
      }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
    .onAppear {
      minimumFireDate = .now
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
