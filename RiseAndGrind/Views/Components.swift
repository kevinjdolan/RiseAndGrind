// Reusable editors and status views shared across the app's configuration screens.

import Foundation
import RiseAndGrindCore
import SwiftUI

struct RGActionResult: Identifiable {
  let id = UUID()
  let eyebrow: String
  let title: String
  let message: String
  let icon: String
  let accent: Color
}

struct RGActionResultSheet: View {
  @Environment(\.dismiss) private var dismiss

  let result: RGActionResult

  var body: some View {
    RGScreenBackground {
      VStack(spacing: 16) {
        ScrollView {
          VStack(spacing: 12) {
            Image(systemName: result.icon)
              .font(.system(size: 34, weight: .black))
              .foregroundStyle(result.accent)
              .frame(width: 68, height: 68)
              .background(result.accent.opacity(0.13), in: Circle())
              .overlay {
                Circle().stroke(result.accent.opacity(0.3), lineWidth: 1)
              }

            Text(result.eyebrow.uppercased())
              .font(.caption.weight(.black))
              .tracking(1.7)
              .foregroundStyle(RGTheme.gold)

            Text(result.title)
              .font(.title2.weight(.black))
              .multilineTextAlignment(.center)
              .foregroundStyle(RGTheme.cream)

            Text(result.message)
              .font(.subheadline)
              .multilineTextAlignment(.center)
              .foregroundStyle(RGTheme.mutedCream)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity)
        }

        Button("DONE") {
          dismiss()
        }
        .buttonStyle(RGPrimaryButtonStyle())
      }
      .padding(.horizontal, 20)
      .padding(.top, 22)
      .padding(.bottom, 16)
    }
    .presentationDetents([.height(350)])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(28)
  }
}

struct RGTimePicker: View {
  let title: String
  let detail: String
  @Binding var hour: Int
  @Binding var minute: Int

  private var selection: Binding<Date> {
    Binding(
      get: {
        Calendar.autoupdatingCurrent.date(
          bySettingHour: hour,
          minute: minute,
          second: 0,
          of: .now
        ) ?? .now
      },
      set: { newValue in
        let components = Calendar.autoupdatingCurrent.dateComponents(
          [.hour, .minute],
          from: newValue
        )
        hour = components.hour ?? hour
        minute = components.minute ?? minute
      }
    )
  }

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline.weight(.bold))
          .foregroundStyle(RGTheme.cream)
        Text(detail)
          .font(.caption)
          .foregroundStyle(RGTheme.mutedCream)
          .lineLimit(2)
          .minimumScaleFactor(0.72)
          .allowsTightening(true)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      DatePicker(
        title,
        selection: selection,
        displayedComponents: .hourAndMinute
      )
      .labelsHidden()
      .datePickerStyle(.compact)
      .tint(RGTheme.gold)
      .accessibilityLabel(title)
    }
  }
}

struct RGDurationEditor: View {
  let title: String
  let detail: String
  @Binding var minutes: Int

  var body: some View {
    Stepper(
      value: $minutes,
      in: RiseAndGrindSettings.eventBufferMinutesRange,
      step: 5
    ) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline.weight(.bold))
            .foregroundStyle(RGTheme.cream)
          Text(detail)
            .font(.caption)
            .foregroundStyle(RGTheme.mutedCream)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
        }

        Spacer(minLength: 4)

        Text("\(minutes) min")
          .font(.subheadline.monospacedDigit().weight(.bold))
          .foregroundStyle(RGTheme.gold)
          .lineLimit(1)
          .contentTransition(.numericText())
      }
    }
    .accessibilityLabel(title)
    .accessibilityValue("\(minutes) minutes")
  }
}

struct RGReadOnlyTimeRow: View {
  let title: String
  let detail: String
  let date: Date?

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline.weight(.bold))
          .foregroundStyle(RGTheme.cream)
        Text(detail)
          .font(.caption)
          .foregroundStyle(RGTheme.mutedCream)
          .lineLimit(2)
          .minimumScaleFactor(0.72)
          .allowsTightening(true)
      }

      Spacer(minLength: 8)

      Text(date?.formatted(date: .omitted, time: .shortened) ?? "—")
        .font(.body.monospacedDigit().weight(.semibold))
        .foregroundStyle(RGTheme.cream)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(RGTheme.graphite.opacity(0.78), in: Capsule())
        .overlay {
          Capsule().stroke(RGTheme.cream.opacity(0.08), lineWidth: 1)
        }
        .accessibilityLabel(title)
        .accessibilityValue(
          date?.formatted(date: .complete, time: .shortened) ?? "Unavailable"
        )
    }
  }
}

struct RGLadderEditor: View {
  @Binding var count: Int
  @Binding var spacingMinutes: Int
  @Binding var finalWarningMinutes: Int

  private var finalWarning: Binding<Int> {
    Binding(
      get: { min(max(1, finalWarningMinutes), max(1, spacingMinutes)) },
      set: { finalWarningMinutes = min(max(1, $0), max(1, spacingMinutes)) }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Stepper(value: $count, in: 1...12) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Attack Count")
            Text("Number of alarms")
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
          }
          Spacer()
          Text("\(count)")
            .monospacedDigit()
            .foregroundStyle(RGTheme.gold)
        }
      }

      Divider().overlay(RGTheme.cream.opacity(0.12))

      Stepper(value: $spacingMinutes, in: 1...60) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Reload Time")
            Text("Minutes between attacks")
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
          }
          Spacer()
          Text("\(spacingMinutes) min")
            .monospacedDigit()
            .foregroundStyle(RGTheme.gold)
        }
      }

      Divider().overlay(RGTheme.cream.opacity(0.12))

      Stepper(value: finalWarning, in: 1...max(1, spacingMinutes)) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Final Warning")
            Text("Last call before Grind Time")
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
          }
          Spacer()
          Text("\(finalWarning.wrappedValue) min")
            .monospacedDigit()
            .foregroundStyle(RGTheme.gold)
        }
      }

    }
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(RGTheme.cream)
    .onChange(of: spacingMinutes) { _, newSpacing in
      finalWarningMinutes = min(finalWarningMinutes, max(1, newSpacing))
    }
  }
}

struct RGScenarioSimulator: View {
  let count: Int
  let spacingMinutes: Int
  let finalWarningMinutes: Int
  let grindHour: Int
  let grindMinute: Int
  let eventBufferMinutes: Int
  @State private var selectedMeeting: Date?

  private var grindTime: Date {
    let calendar = Calendar.autoupdatingCurrent
    return
      (try? SchedulePlanner.tomorrowTargetDate(
        hour: grindHour,
        minute: grindMinute,
        after: .now,
        calendar: calendar
      )) ?? .now
  }

  private var defaultMeeting: Date {
    Calendar.autoupdatingCurrent.date(
      byAdding: .minute,
      value: -30,
      to: grindTime
    ) ?? grindTime
  }

  private var meeting: Binding<Date> {
    Binding(
      get: { selectedMeeting ?? defaultMeeting },
      set: { selectedMeeting = $0 }
    )
  }

  private var attackTimes: (first: String, last: String) {
    let calendar = Calendar.autoupdatingCurrent
    let eventTarget =
      calendar.date(
        byAdding: .minute,
        value: -eventBufferMinutes,
        to: meeting.wrappedValue
      ) ?? meeting.wrappedValue
    guard
      let plan = try? SchedulePlanner.makePlan(
        targetDate: min(eventTarget, grindTime),
        alarmCount: count,
        spacingMinutes: spacingMinutes,
        finalWarningMinutes: min(max(1, finalWarningMinutes), max(1, spacingMinutes)),
        sounds: [.system],
        reason: .grindTime,
        calendar: calendar
      ),
      let first = plan.alarms.first?.fireDate,
      let last = plan.alarms.last?.fireDate
    else {
      return ("—", "—")
    }
    return (
      first.formatted(date: .omitted, time: .shortened),
      last.formatted(date: .omitted, time: .shortened)
    )
  }

  var body: some View {
    RGCard(accent: RGTheme.orange) {
      VStack(alignment: .leading, spacing: 12) {
        RGSectionHeading("Scenario Simulator")

        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 6, alignment: .center),
            GridItem(.flexible(), alignment: .center),
          ],
          spacing: 6
        ) {
          scenarioMetric(
            title: "Grind Time",
            value: grindTime.formatted(date: .omitted, time: .shortened),
            tint: RGTheme.gold
          )

          VStack(spacing: 5) {
            Text("FIRST MEETING")
              .font(.system(size: 9, weight: .black))
              .tracking(0.6)
              .foregroundStyle(RGTheme.orange)
            DatePicker(
              "First Meeting",
              selection: meeting,
              displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .controlSize(.mini)
            .tint(RGTheme.orange)
            .scaleEffect(0.88)
            .frame(height: 28)
            .accessibilityLabel("Scenario first meeting")
          }
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)

          scenarioMetric(
            title: "First Attack",
            value: attackTimes.first,
            tint: RGTheme.magenta
          )
          scenarioMetric(
            title: "Final Warning",
            value: attackTimes.last,
            tint: RGTheme.gold
          )
        }
      }
    }
    .onChange(of: grindHour) { _, _ in
      selectedMeeting = nil
    }
    .onChange(of: grindMinute) { _, _ in
      selectedMeeting = nil
    }
  }

  private func scenarioMetric(title: String, value: String, tint: Color) -> some View {
    VStack(spacing: 5) {
      Text(title.uppercased())
        .font(.system(size: 9, weight: .black))
        .tracking(0.6)
        .foregroundStyle(tint)
      Text(value)
        .font(.title3.monospacedDigit().weight(.black))
        .foregroundStyle(RGTheme.cream)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 28)
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
  }
}

struct RGScheduledAlarmList: View {
  let alarms: [ScheduledAlarmRecord]
  let mutedAlarms: [ScheduledAlarmRecord]
  let muteState: AlarmMuteState?

  var body: some View {
    RGCard(accent: cardAccent) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("UPCOMING ATTACKS")
            .font(.caption.weight(.black))
            .tracking(1.5)
            .foregroundStyle(RGTheme.gold)
          Spacer()
          RGStatusPill(
            text: statusText,
            color: statusColor,
            icon: statusIcon
          )
        }

        if let muteDetail {
          Label(muteDetail, systemImage: "speaker.slash.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(RGTheme.orange)
        }

        if displayedAlarms.isEmpty {
          Text("No active nightly or test alarms.")
            .font(.subheadline)
            .foregroundStyle(RGTheme.mutedCream)
        } else {
          ForEach(displayedAlarms) { item in
            HStack(spacing: 12) {
              Image(
                systemName: item.isMuted
                  ? "speaker.slash.fill" : "alarm.waves.left.and.right.fill"
              )
              .foregroundStyle(item.isMuted ? RGTheme.orange : RGTheme.gold)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.alarm.fireDate.formatted(date: .abbreviated, time: .shortened))
                  .font(.subheadline.monospacedDigit().weight(.bold))
                  .foregroundStyle(item.isMuted ? RGTheme.mutedCream : RGTheme.cream)
                  .strikethrough(item.isMuted, color: RGTheme.orange)
                Text(item.alarm.title)
                  .font(.caption)
                  .foregroundStyle(RGTheme.mutedCream)
                  .lineLimit(1)
                  .strikethrough(item.isMuted, color: RGTheme.orange)
              }
              Spacer()

              if item.isMuted {
                Text("MUTED")
                  .font(.system(size: 9, weight: .black))
                  .tracking(0.7)
                  .foregroundStyle(RGTheme.orange)
              }
            }
          }
        }
      }
    }
  }

  private var displayedAlarms: [RGDisplayedAlarm] {
    (alarms.map { RGDisplayedAlarm(alarm: $0, isMuted: false) }
      + mutedAlarms.map { RGDisplayedAlarm(alarm: $0, isMuted: true) })
      .sorted { $0.alarm.fireDate < $1.alarm.fireDate }
  }

  private var cardAccent: Color {
    if mutedAlarms.isEmpty == false { return RGTheme.orange }
    return alarms.isEmpty ? RGTheme.graphite : RGTheme.mint
  }

  private var statusText: String {
    switch (alarms.count, mutedAlarms.count) {
    case (0, 0): "0 armed"
    case (0, let muted): "\(muted) muted"
    case (let armed, 0): "\(armed) armed"
    case (let armed, let muted): "\(armed) armed / \(muted) muted"
    }
  }

  private var statusColor: Color {
    if mutedAlarms.isEmpty == false { return RGTheme.orange }
    return alarms.isEmpty ? RGTheme.mutedCream : RGTheme.mint
  }

  private var statusIcon: String {
    if mutedAlarms.isEmpty == false { return "speaker.slash.fill" }
    return alarms.isEmpty ? "moon.zzz.fill" : "alarm.fill"
  }

  private var muteDetail: String? {
    guard mutedAlarms.isEmpty == false, let muteState else { return nil }
    switch muteState {
    case .until(let date):
      return "Muted until " + date.formatted(date: .abbreviated, time: .shortened)
    case .indefinitely:
      return "Muted until you resume R&G"
    }
  }
}

private struct RGDisplayedAlarm: Identifiable {
  let alarm: ScheduledAlarmRecord
  let isMuted: Bool

  var id: String {
    alarm.id.uuidString + (isMuted ? "-muted" : "-armed")
  }
}

struct RGPermissionRow: View {
  let icon: String
  let title: String
  let status: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(RGTheme.gold)
        .frame(width: 24)
      Text(title)
        .font(.subheadline.weight(.bold))
        .foregroundStyle(RGTheme.cream)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .layoutPriority(1)
      Spacer(minLength: 8)
      RGStatusPill(text: compactStatus, color: statusColor)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var compactStatus: String {
    let normalized = status.lowercased()
    if normalized == "authorized" || normalized.contains("full access") {
      return "Ready"
    }
    if normalized.contains("not requested") || normalized.contains("not determined") {
      return "Not set"
    }
    if normalized.contains("restricted") {
      return "Blocked"
    }
    if normalized.contains("write only") {
      return "Limited"
    }
    if normalized.contains("checking") {
      return "Checking"
    }
    return status
  }

  private var statusColor: Color {
    let normalized = status.lowercased()
    if normalized == "authorized" || normalized.contains("full access") {
      return RGTheme.mint
    }
    if normalized.contains("denied") || normalized.contains("restricted") {
      return RGTheme.danger
    }
    return RGTheme.orange
  }
}

struct RGAutomationStep: View {
  let number: Int
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.caption.monospacedDigit().weight(.black))
        .foregroundStyle(RGTheme.ink)
        .frame(width: 25, height: 25)
        .background(RGTheme.mint, in: Circle())
      Text(text)
        .font(.subheadline)
        .foregroundStyle(RGTheme.cream)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
