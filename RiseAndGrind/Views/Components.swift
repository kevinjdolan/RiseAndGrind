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
      Stepper(value: $count, in: 0...12) {
        label(
          title: "Nudge Count",
          detail: "Number of optional alarms before the Grind Time Challenge™",
          value: "\(count)"
        )
      }

      Divider().overlay(RGTheme.cream.opacity(0.12))

      Stepper(value: $spacingMinutes, in: 1...60) {
        label(
          title: "Nudge Snooze Duration",
          detail: "Delay time when you Snooze a Nudge",
          value: "\(spacingMinutes) min"
        )
      }

      Divider().overlay(RGTheme.cream.opacity(0.12))

      Stepper(value: finalWarning, in: 1...max(1, spacingMinutes)) {
        label(
          title: "Final Warning",
          detail: "Minutes before Grind Time for the final Nudge",
          value: "\(finalWarning.wrappedValue) min"
        )
      }

    }
    .onChange(of: spacingMinutes) { _, newSpacing in
      finalWarningMinutes = min(finalWarningMinutes, max(1, newSpacing))
    }
  }

  /// Typographically identical to RGTimePicker and RGDurationEditor so every row
  /// of the alarm configuration card reads as one list.
  private func label(title: String, detail: String, value: String) -> some View {
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

      Text(value)
        .font(.subheadline.monospacedDigit().weight(.bold))
        .foregroundStyle(RGTheme.gold)
        .lineLimit(1)
        .contentTransition(.numericText())
    }
  }
}

struct RGAlarmConfigurationCard: View {
  @Binding var settings: RiseAndGrindSettings
  var eyebrow: String = "Regimen"
  var boxed: Bool = true

  var body: some View {
    Group {
      if boxed {
        RGCard(accent: RGTheme.gold) { content }
      } else {
        content
      }
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 16) {
      RGSectionHeading(
        "Alarm Configuration",
        eyebrow: eyebrow
      )

      Divider().overlay(RGTheme.cream.opacity(0.12))

      RGTimePicker(
        title: "Grind Time",
        detail: "Default Time for the Grind Time Challenge™",
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

      RGLadderEditor(
        count: $settings.barrage.alarmCount,
        spacingMinutes: $settings.barrage.spacingMinutes,
        finalWarningMinutes: $settings.barrage.finalWarningMinutes
      )

      Divider().overlay(RGTheme.cream.opacity(0.12))

      VStack(alignment: .leading, spacing: 12) {
        Text("ACTIVE DAYS")
          .font(.caption.weight(.black))
          .tracking(1.5)
          .foregroundStyle(RGTheme.orange)

        dayPicker

        Label(daySummary, systemImage: "calendar.badge.clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(RGTheme.mutedCream)
      }
    }
  }

  private var dayPicker: some View {
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

  private func toggle(_ day: GrindDay) {
    if settings.enabledDays.contains(day) {
      guard settings.enabledDays.count > 1 else { return }
      settings.enabledDays.remove(day)
    } else {
      settings.enabledDays.insert(day)
    }
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
          Text("UPCOMING ALARMS")
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

struct RGSquatCoinFace: View {
  let imageName: String
  let diameter: CGFloat
  let accent: Color
  var isReady = true

  var body: some View {
    Image(imageName)
      .resizable()
      .interpolation(.high)
      .scaledToFill()
      .frame(width: diameter, height: diameter)
      .clipShape(Circle())
      .saturation(isReady ? 1 : 0.50)
      .brightness(isReady ? 0 : -0.10)
      .opacity(isReady ? 1 : 0.68)
      .overlay {
        Circle()
          .stroke(
            LinearGradient(
              colors: [
                Color.white.opacity(isReady ? 0.72 : 0.34),
                accent.opacity(isReady ? 0.64 : 0.26),
                RGTheme.ink.opacity(0.82),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: max(2, diameter * 0.018)
          )
      }
      .shadow(
        color: RGTheme.ink.opacity(0.90),
        radius: 3,
        y: max(4, diameter * 0.055)
      )
      .shadow(
        color: isReady ? accent.opacity(0.38) : Color.clear,
        radius: 15
      )
      .contentShape(Circle())
  }
}

struct RGSquatCoinAttentionGlow: View {
  let diameter: CGFloat
  let progress: CGFloat
  let isActive: Bool

  var body: some View {
    if isActive {
      ZStack {
        Circle()
          .fill(RGTheme.gold.opacity(0.24 + (progress * 0.22)))
          .frame(width: diameter, height: diameter)
          .scaleEffect(1.10 + (progress * 0.24))
          .blur(radius: 16 + (progress * 16))

        Circle()
          .stroke(
            LinearGradient(
              colors: [Color.white, RGTheme.gold, RGTheme.orange],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: max(5, diameter * 0.032)
          )
          .frame(width: diameter, height: diameter)
          .scaleEffect(1.03 + (progress * 0.13))
          .blur(radius: 1 + (progress * 4))
          .shadow(color: RGTheme.gold, radius: 18 + (progress * 16))
          .opacity(1 - (progress * 0.16))

        Circle()
          .stroke(Color.white.opacity(0.88), lineWidth: 2)
          .frame(width: diameter, height: diameter)
          .scaleEffect(1.01 + (progress * 0.08))
          .blur(radius: progress * 2)
          .opacity(0.90 - (progress * 0.35))
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}

struct RGSquatCoinButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(
        x: configuration.isPressed ? 0.975 : 1,
        y: configuration.isPressed ? 0.91 : 1
      )
      .rotation3DEffect(
        .degrees(configuration.isPressed ? 4 : 0),
        axis: (x: 1, y: 0, z: 0),
        perspective: 0.55
      )
      .offset(y: configuration.isPressed ? 9 : 0)
      .brightness(configuration.isPressed ? -0.09 : 0)
      .animation(
        .spring(duration: 0.18, bounce: 0.22),
        value: configuration.isPressed
      )
  }
}

struct RGSquatCoinHoldButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.996 : 1)
      .brightness(configuration.isPressed ? 0.015 : 0)
      .animation(
        .easeOut(duration: 0.08),
        value: configuration.isPressed
      )
  }
}
