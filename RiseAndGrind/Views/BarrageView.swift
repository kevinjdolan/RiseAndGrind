// Presents the durable alarm agenda and the calendar events that influence it.

import Foundation
import RiseAndGrindCore
import SwiftUI

/// A calendar event that may move the next Grind Time earlier.
struct AlarmCalendarInfluence: Identifiable, Equatable, Sendable {
  let id: CalendarEventOccurrenceID
  let title: String
  let startDate: Date
  let calendarTitle: String
  let isIgnored: Bool
  let affectsRiseTime: Bool

  init(candidate: CalendarEventCandidate, affectsRiseTime: Bool) {
    id = candidate.id
    title = candidate.title
    startDate = candidate.startDate
    calendarTitle = candidate.calendarTitle
    isIgnored = candidate.isIgnored
    self.affectsRiseTime = affectsRiseTime
  }
}

struct BarrageView: View {
  let alarmLedger: AlarmLedger
  let calendarInfluences: [AlarmCalendarInfluence]
  let setCalendarInfluenceIgnored: @MainActor (AlarmCalendarInfluence, Bool) async -> Void
  let setAlarmUserOverride: @MainActor (UUID, AlarmUserOverride) async -> Void

  @State private var selectedAlarm: AlarmLedgerAlarm?
  @State private var editingAlarm: AlarmLedgerAlarm?

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          agendaSummary

          AlarmAgendaSection(
            title: "UPCOMING",
            detail: "The next 24 hours",
            icon: "arrow.up.forward.circle.fill",
            accent: RGTheme.mint,
            alarms: upcomingAlarms,
            events: alarmLedger.events,
            disarmedAlarmIDs: disarmedAlarmIDs,
            chronological: true,
            emptyMessage: "No alarms are currently planned for the next 24 hours.",
            select: { selectedAlarm = $0 },
            edit: { editingAlarm = $0 }
          )

          AlarmAgendaSection(
            title: "HISTORY",
            detail: "The previous seven days",
            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            accent: RGTheme.coolBlue,
            alarms: pastAlarms,
            events: alarmLedger.events,
            disarmedAlarmIDs: disarmedAlarmIDs,
            chronological: false,
            emptyMessage: "No retained alarm history yet.",
            select: { selectedAlarm = $0 },
            edit: { editingAlarm = $0 }
          )

          AlarmCalendarInfluenceCard(
            influences: calendarInfluences,
            setIgnored: setCalendarInfluenceIgnored
          )
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Agenda")
    .rgInlineNavigationTitle()
    .sheet(item: $selectedAlarm) { alarm in
      AlarmHistoryDetailSheet(
        alarm: alarm,
        events: events(for: alarm)
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(28)
    }
    .sheet(item: $editingAlarm) { alarm in
      AlarmOverrideEditSheet(
        alarm: alarm,
        save: setAlarmUserOverride
      )
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(28)
    }
  }

  private var agendaSummary: some View {
    RGCard(accent: RGTheme.gold) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 12) {
          RGSectionHeading(
            "Alarm Agenda",
            eyebrow: "Persistent record",
            detail:
              "Every alarm keeps its identity when timing or configuration changes. Tap for history; hold to edit."
          )

          Spacer(minLength: 4)

          RGStatusPill(
            text: "\(activeAlarmCount) live",
            color: activeAlarmCount == 0 ? RGTheme.mutedCream : RGTheme.orange,
            icon: activeAlarmCount == 0 ? "moon.zzz.fill" : "waveform.path"
          )
          .fixedSize()
        }

        HStack(spacing: 10) {
          RGMetric(
            value: "\(upcomingAlarms.count)",
            label: "Ahead",
            tint: RGTheme.mint
          )
          RGMetric(
            value: "\(pastAlarms.count)",
            label: "Past",
            tint: RGTheme.coolBlue
          )
          RGMetric(
            value: "\(deprecatedAlarmCount)",
            label: "Retired",
            tint: RGTheme.orange
          )
        }
      }
    }
  }

  private var visibleAlarms: [AlarmLedgerAlarm] {
    let horizon = upcomingHorizon
    let start = historyStart
    return alarmLedger.alarms.filter { alarm in
      // Follow-up coverage is an implementation detail of the alarm it
      // supports. Ledgers written before that was true can still hold
      // standalone entries for it.
      guard alarm.slot.relayOrdinal == nil else { return false }
      let fireDate = alarm.current.fireDate
      guard fireDate <= horizon else { return false }
      return fireDate >= start || alarm.current.lifecycle.isActive
    }
  }

  private var upcomingAlarms: [AlarmLedgerAlarm] {
    visibleAlarms
      .filter { $0.current.fireDate >= .now }
      .sorted(by: Self.alarmAscending)
  }

  private var pastAlarms: [AlarmLedgerAlarm] {
    visibleAlarms
      .filter { $0.current.fireDate < .now }
      .sorted { Self.alarmAscending($1, $0) }
  }

  /// Completing a challenge cancels the rest of its stack — see
  /// `NightlyCoordinator.completeWakeChallenge`, which calls `cancelAlarmSet`.
  /// Anything still pending in that set afterwards will never sound, so the
  /// agenda shows it stood down rather than armed. Derived from the whole ledger
  /// because the completed alarm and the alarms it disarmed usually land in
  /// different sections.
  private var disarmedAlarmIDs: Set<UUID> {
    let completionBySet = Dictionary(
      alarmLedger.alarms.compactMap { alarm -> (UUID, Date)? in
        guard alarm.current.lifecycle == .challengeCompleted else { return nil }
        return (alarm.setID, alarm.current.fireDate)
      },
      uniquingKeysWith: min
    )
    guard !completionBySet.isEmpty else { return [] }
    return Set(
      alarmLedger.alarms
        .filter { alarm in
          guard let completedAt = completionBySet[alarm.setID] else { return false }
          guard !alarm.current.lifecycle.isTerminal else { return false }
          return alarm.current.fireDate > completedAt
        }
        .map(\.id)
    )
  }

  private var activeAlarmCount: Int {
    visibleAlarms.count { $0.current.lifecycle.isActive }
  }

  private var deprecatedAlarmCount: Int {
    visibleAlarms.count { $0.current.lifecycle == .deprecated }
  }

  /// The agenda never looks further ahead than a day, even for alarms that are
  /// already armed further out.
  private var upcomingHorizon: Date {
    Date.now.addingTimeInterval(24 * 60 * 60)
  }

  private var historyStart: Date {
    let calendar = Calendar.autoupdatingCurrent
    let today = calendar.startOfDay(for: .now)
    return calendar.date(byAdding: .day, value: -7, to: today) ?? today
  }

  private func events(for alarm: AlarmLedgerAlarm) -> [AlarmLedgerEvent] {
    alarmLedger.events
      .filter { $0.alarmID == alarm.id }
      .sorted {
        if $0.timestamp == $1.timestamp {
          return $0.id.uuidString > $1.id.uuidString
        }
        return $0.timestamp > $1.timestamp
      }
  }

  private static func alarmAscending(
    _ lhs: AlarmLedgerAlarm,
    _ rhs: AlarmLedgerAlarm
  ) -> Bool {
    if lhs.current.fireDate == rhs.current.fireDate {
      return lhs.id.uuidString < rhs.id.uuidString
    }
    return lhs.current.fireDate < rhs.current.fireDate
  }
}

private struct AlarmAgendaSection: View {
  let title: String
  let detail: String
  let icon: String
  let accent: Color
  let alarms: [AlarmLedgerAlarm]
  let events: [AlarmLedgerEvent]
  let disarmedAlarmIDs: Set<UUID>
  let chronological: Bool
  let emptyMessage: String
  let select: (AlarmLedgerAlarm) -> Void
  let edit: (AlarmLedgerAlarm) -> Void

  var body: some View {
    RGCard(accent: accent) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          Label(title, systemImage: icon)
            .font(.caption.weight(.black))
            .tracking(1.4)
            .foregroundStyle(accent)

          Spacer()

          Text(detail)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(RGTheme.mutedCream)
        }

        if alarms.isEmpty {
          Label(emptyMessage, systemImage: "calendar.badge.clock")
            .font(.subheadline)
            .foregroundStyle(RGTheme.mutedCream)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
        } else {
          ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            if index > 0 {
              Divider().overlay(RGTheme.cream.opacity(0.10))
                .padding(.vertical, 2)
            }

            Text(dayLabel(group.day).uppercased())
              .font(.system(size: 10, weight: .black))
              .tracking(1.1)
              .foregroundStyle(RGTheme.mutedCream)

            ForEach(group.alarms) { alarm in
              AlarmAgendaRow(
                alarm: alarm,
                eventCount: events.count { $0.alarmID == alarm.id },
                isDisarmed: disarmedAlarmIDs.contains(alarm.id),
                accent: accent,
                select: { select(alarm) },
                edit: { edit(alarm) }
              )
            }
          }
        }
      }
    }
  }

  private var groups: [AlarmAgendaDayGroup] {
    let calendar = Calendar.autoupdatingCurrent
    let grouped = Dictionary(grouping: alarms) {
      calendar.startOfDay(for: $0.current.fireDate)
    }
    return
      grouped
      .map { day, alarms in
        AlarmAgendaDayGroup(
          day: day,
          alarms: alarms.sorted {
            if $0.current.fireDate == $1.current.fireDate {
              return $0.id.uuidString < $1.id.uuidString
            }
            return chronological
              ? $0.current.fireDate < $1.current.fireDate
              : $0.current.fireDate > $1.current.fireDate
          }
        )
      }
      .sorted { chronological ? $0.day < $1.day : $0.day > $1.day }
  }

  private func dayLabel(_ date: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
  }
}

private struct AlarmAgendaDayGroup: Identifiable {
  let day: Date
  let alarms: [AlarmLedgerAlarm]

  var id: Date { day }
}

private struct AlarmAgendaRow: View {
  let alarm: AlarmLedgerAlarm
  let eventCount: Int
  let isDisarmed: Bool
  let accent: Color
  let select: () -> Void
  let edit: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: displayedIcon)
        .font(.subheadline.weight(.black))
        .foregroundStyle(displayedColor)
        .frame(width: 34, height: 34)
        .background(
          displayedColor.opacity(0.12),
          in: Circle()
        )

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(alarm.current.fireDate.formatted(date: .omitted, time: .shortened))
            .font(.subheadline.monospacedDigit().weight(.black))
            .foregroundStyle(
              alarm.isDeprecated ? RGTheme.mutedCream : RGTheme.cream
            )
            .strikethrough(alarm.isDeprecated, color: RGTheme.orange)

          Text(displayedStateLabel.uppercased())
            .font(.system(size: 8, weight: .black))
            .tracking(0.65)
            .foregroundStyle(displayedColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
              displayedColor.opacity(0.11),
              in: Capsule()
            )
        }

        Text(alarm.current.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(RGTheme.mutedCream)
          .lineLimit(1)
          .strikethrough(alarm.isDeprecated, color: RGTheme.orange)

        HStack(spacing: 8) {
          // The slot label used to sit here too, but the title now carries the
          // same "Nudge 3/6" wording.
          Text(alarm.owner.agendaLabel)

          if hasCustomOverride {
            Text("•")
            Label("Custom", systemImage: "slider.horizontal.3")
              .labelStyle(.titleAndIcon)
              .foregroundStyle(RGTheme.gold)
          } else if eventCount > 1 {
            Text("•")
            Label("\(eventCount) events", systemImage: "arrow.triangle.2.circlepath")
              .labelStyle(.titleAndIcon)
          }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(RGTheme.mutedCream.opacity(0.82))
      }

      Spacer(minLength: 6)

      Image(systemName: "chevron.right")
        .font(.caption2.weight(.black))
        .foregroundStyle(accent.opacity(0.72))
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(
          alarm.current.lifecycle.isActive
            ? displayedColor.opacity(0.08)
            : Color.clear
        )
    }
    .contentShape(Rectangle())
    .opacity(alarm.isDeprecated ? 0.62 : 1)
    .gesture(
      LongPressGesture(minimumDuration: 0.55)
        .exclusively(before: TapGesture())
        .onEnded { result in
          switch result {
          case .first(let completed):
            if completed { edit() }
          case .second:
            select()
          }
        }
    )
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(
      "\(alarm.current.title), \(alarm.current.fireDate.formatted(date: .complete, time: .shortened)), \(displayedStateLabel)"
    )
    .accessibilityHint("Double-tap for history. Use the Edit alarm action to change overrides.")
    .accessibilityAction(named: "Show history", select)
    .accessibilityAction(named: "Edit alarm", edit)
  }

  private var hasCustomOverride: Bool {
    let defaultOverride = AlarmUserOverride.defaults(
      isFinal: alarm.current.isCanonical,
      ordinal: alarm.current.ordinal,
      total: alarm.current.total
    )
    return alarm.current.userOverride != defaultOverride
  }

  private var isMuted: Bool {
    alarm.current.userOverride.isMuted
      || alarm.current.lifecycle == .silenced
  }

  /// The stack's nudges — everything leading up to the Grind Time alarm.
  private var isNudge: Bool {
    !alarm.current.isCanonical
  }

  /// True while this alarm is still waiting to fire, as opposed to one that has
  /// already run, been snoozed, or been retired.
  private var isPending: Bool {
    alarm.current.lifecycle == .planned || alarm.current.lifecycle == .scheduled
  }

  private var displayedStateLabel: String {
    if isDisarmed {
      return "Disarmed"
    }
    return isMuted ? "Muted" : alarm.current.lifecycle.agendaLabel
  }

  private var displayedIcon: String {
    if isDisarmed {
      return "bell.slash.fill"
    }
    if isMuted {
      return "speaker.slash.fill"
    }
    // A pending nudge is a gentle poke, not the alarm clock it builds toward.
    if isNudge, alarm.current.lifecycle == .scheduled {
      return "bell.fill"
    }
    return alarm.current.lifecycle.agendaIcon
  }

  private var displayedColor: Color {
    if isDisarmed {
      return RGTheme.pastelMint
    }
    if isMuted {
      return RGTheme.orange
    }
    // Pending nudges stay quiet; the alarm they lead up to does not.
    if isPending {
      return isNudge ? RGTheme.pastelBlue : RGTheme.purple
    }
    return alarm.current.lifecycle.agendaColor
  }
}

private struct AlarmOverrideEditSheet: View {
  @Environment(\.dismiss) private var dismiss

  let alarm: AlarmLedgerAlarm
  let save: @MainActor (UUID, AlarmUserOverride) async -> Void

  @State private var draft: AlarmUserOverride
  @State private var isSaving = false

  private let supportsPerAlarmVolumeControl = false

  init(
    alarm: AlarmLedgerAlarm,
    save: @escaping @MainActor (UUID, AlarmUserOverride) async -> Void
  ) {
    self.alarm = alarm
    self.save = save
    _draft = State(initialValue: alarm.current.userOverride)
  }

  var body: some View {
    NavigationStack {
      RGScreenBackground {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            RGCard(accent: RGTheme.gold) {
              VStack(alignment: .leading, spacing: 5) {
                Text("ALARM OVERRIDES")
                  .font(.caption.weight(.black))
                  .tracking(1.6)
                  .foregroundStyle(RGTheme.gold)

                Text(alarm.current.fireDate.formatted(date: .complete, time: .shortened))
                  .font(.title3.monospacedDigit().weight(.black))
                  .foregroundStyle(RGTheme.cream)

                Text(alarm.current.title)
                  .font(.subheadline)
                  .foregroundStyle(RGTheme.mutedCream)
                  .lineLimit(2)
              }
            }

            if alarm.current.fireDate <= .now {
              RGCard(accent: RGTheme.mutedCream) {
                Label {
                  Text(
                    alarm.current.lifecycle.isActive
                      ? "This delivery is already active. Changes are audited here, but iOS cannot reconfigure an AlarmKit alert already in progress."
                      : "This delivery has already fired. Changes remain in its audit history and apply if this logical alarm is restored later."
                  )
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(RGTheme.mutedCream)
                } icon: {
                  Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(RGTheme.gold)
                }
              }
            }

            RGCard(accent: RGTheme.orange) {
              VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $draft.requiresChallenge) {
                  overrideLabel(
                    title: "Require Challenge",
                    detail: "Stopping this alarm launches the squat challenge.",
                    icon: "figure.strengthtraining.traditional",
                    color: RGTheme.orange
                  )
                }
                .tint(RGTheme.orange)

                Divider().overlay(RGTheme.cream.opacity(0.10))

                Toggle(isOn: $draft.isMuted) {
                  overrideLabel(
                    title: "Mute This Alarm",
                    detail: "Keep it in Agenda without scheduling audible delivery.",
                    icon: "speaker.slash.fill",
                    color: RGTheme.danger
                  )
                }
                .tint(RGTheme.danger)
              }
            }

            volumeCard
            intensityCard
          }
          .padding(.horizontal, 18)
          .padding(.top, 14)
          .padding(.bottom, 110)
        }
        .safeAreaInset(edge: .bottom) {
          Button {
            persist()
          } label: {
            if isSaving {
              ProgressView()
                .tint(RGTheme.ink)
            } else {
              Label("SAVE ALARM OVERRIDES", systemImage: "checkmark.circle.fill")
            }
          }
          .buttonStyle(RGPrimaryButtonStyle())
          .disabled(isSaving || draft == alarm.current.userOverride)
          .padding(.horizontal, 18)
          .padding(.vertical, 12)
          .background(.bar)
        }
      }
      .navigationTitle("Edit Alarm")
      .rgInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
      }
    }
  }

  private var volumeCard: some View {
    RGCard(accent: RGTheme.graphite) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("VOLUME • 1–10")
            .font(.caption.weight(.black))
            .tracking(1.3)
            .foregroundStyle(RGTheme.mutedCream)

          Spacer()

          RGStatusPill(
            text: "Unavailable",
            color: RGTheme.mutedCream,
            icon: "lock.fill"
          )
        }

        HStack(spacing: 12) {
          Image(systemName: "speaker.wave.1.fill")
          Slider(
            value: volumeBinding,
            in: Double(
              AlarmUserOverride.requestedVolumeRange.lowerBound)...Double(
                AlarmUserOverride.requestedVolumeRange.upperBound),
            step: 1
          )
          Image(systemName: "speaker.wave.3.fill")
          Text("\(draft.requestedVolume ?? 10)")
            .font(.subheadline.monospacedDigit().weight(.black))
            .frame(width: 22)
        }
        .foregroundStyle(RGTheme.mutedCream)
        .disabled(!supportsPerAlarmVolumeControl)
        .opacity(supportsPerAlarmVolumeControl ? 1 : 0.46)

        Text(
          "iOS AlarmKit controls actual playback volume. It does not currently expose per-alarm volume control to Rise & Grind."
        )
        .font(.caption)
        .foregroundStyle(RGTheme.mutedCream)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var intensityCard: some View {
    RGCard(accent: draft.musicIntensity.agendaColor) {
      VStack(alignment: .leading, spacing: 12) {
        Text("MUSIC INTENSITY")
          .font(.caption.weight(.black))
          .tracking(1.3)
          .foregroundStyle(draft.musicIntensity.agendaColor)

        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(AlarmIntensityTier.allCases) { tier in
              Button {
                draft.musicIntensity = tier
              } label: {
                VStack(spacing: 5) {
                  Image(systemName: tier.agendaIcon)
                    .font(.subheadline.weight(.black))
                  Text(tier.displayName)
                    .font(.caption2.weight(.black))
                }
                .foregroundStyle(
                  draft.musicIntensity == tier ? RGTheme.ink : tier.agendaColor
                )
                .padding(.horizontal, 12)
                .frame(height: 54)
                .background(
                  draft.musicIntensity == tier
                    ? tier.agendaColor
                    : tier.agendaColor.opacity(0.10),
                  in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(tier.agendaColor.opacity(0.30), lineWidth: 1)
                }
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(tier.displayName) music intensity")
              .accessibilityValue(
                draft.musicIntensity == tier ? "Selected" : "Not selected"
              )
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  private var volumeBinding: Binding<Double> {
    Binding(
      get: { Double(draft.requestedVolume ?? 10) },
      set: { draft.requestedVolume = Int($0.rounded()) }
    )
  }

  private func overrideLabel(
    title: String,
    detail: String,
    icon: String,
    color: Color
  ) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(RGTheme.cream)
        Text(detail)
          .font(.caption)
          .foregroundStyle(RGTheme.mutedCream)
          .fixedSize(horizontal: false, vertical: true)
      }
    } icon: {
      Image(systemName: icon)
        .foregroundStyle(color)
        .frame(width: 24)
    }
  }

  private func persist() {
    isSaving = true
    Task { @MainActor in
      await save(alarm.id, draft)
      isSaving = false
      dismiss()
    }
  }
}

private struct AlarmHistoryDetailSheet: View {
  @Environment(\.dismiss) private var dismiss

  let alarm: AlarmLedgerAlarm
  let events: [AlarmLedgerEvent]

  var body: some View {
    NavigationStack {
      RGScreenBackground {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            RGCard(accent: alarm.current.lifecycle.agendaColor) {
              VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(alarm.current.fireDate.formatted(date: .complete, time: .shortened))
                      .font(.title3.monospacedDigit().weight(.black))
                      .foregroundStyle(RGTheme.cream)

                    Text(alarm.current.title)
                      .font(.subheadline.weight(.semibold))
                      .foregroundStyle(RGTheme.mutedCream)
                  }

                  Spacer(minLength: 4)

                  RGStatusPill(
                    text: alarm.current.lifecycle.agendaLabel,
                    color: alarm.current.lifecycle.agendaColor,
                    icon: alarm.current.lifecycle.agendaIcon
                  )
                  .fixedSize()
                }

                Divider().overlay(RGTheme.cream.opacity(0.10))

                AlarmRecordFact(
                  label: "Position",
                  value:
                    alarm.owner.agendaLabel
                    + " • "
                    + alarm.slot.agendaLabel(current: alarm.current)
                )
                AlarmRecordFact(
                  label: "Alarm type",
                  value: alarm.current.alarmType.agendaLabel
                )
                AlarmRecordFact(
                  label: "User behavior",
                  value: alarm.current.userOverride.agendaSummary
                )
                AlarmRecordFact(
                  label: "Last changed",
                  value: alarm.updatedAt.formatted(date: .abbreviated, time: .standard)
                )
              }
            }

            RGCard(accent: RGTheme.coolBlue) {
              VStack(alignment: .leading, spacing: 14) {
                HStack {
                  Text("AUDIT TRAIL")
                    .font(.caption.weight(.black))
                    .tracking(1.5)
                    .foregroundStyle(RGTheme.coolBlue)

                  Spacer()

                  RGStatusPill(
                    text: "\(events.count) events",
                    color: RGTheme.coolBlue,
                    icon: "list.bullet.rectangle"
                  )
                }

                if events.isEmpty {
                  Text("No audit events have been recorded for this alarm yet.")
                    .font(.subheadline)
                    .foregroundStyle(RGTheme.mutedCream)
                } else {
                  ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 {
                      Divider().overlay(RGTheme.cream.opacity(0.09))
                    }
                    AlarmAuditEventRow(event: event)
                  }
                }
              }
            }
          }
          .padding(.horizontal, 18)
          .padding(.top, 14)
          .padding(.bottom, 28)
        }
      }
      .navigationTitle("Alarm Record")
      .rgInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .fontWeight(.bold)
        }
      }
    }
  }
}

private struct AlarmRecordFact: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label.uppercased())
        .font(.system(size: 9, weight: .black))
        .tracking(0.8)
        .foregroundStyle(RGTheme.mutedCream)
      Text(value)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(RGTheme.cream)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct AlarmAuditEventRow: View {
  let event: AlarmLedgerEvent

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: event.kind.agendaIcon)
        .font(.caption.weight(.black))
        .foregroundStyle(event.kind.agendaColor)
        .frame(width: 26, height: 26)
        .background(event.kind.agendaColor.opacity(0.12), in: Circle())

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(event.kind.agendaLabel)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(RGTheme.cream)

          Spacer()

          Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(RGTheme.mutedCream)
        }

        Text(event.agendaSummary)
          .font(.caption)
          .foregroundStyle(RGTheme.mutedCream)
          .fixedSize(horizontal: false, vertical: true)

        Text(event.source)
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundStyle(RGTheme.coolBlue.opacity(0.82))
          .lineLimit(2)

        ForEach(displayedDetails, id: \.key) { key, value in
          Text("\(key): \(value)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(RGTheme.mutedCream.opacity(0.78))
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 2)
  }

  /// Audit details carry raw record identifiers; those never reach the UI.
  private var displayedDetails: [(key: String, value: String)] {
    Array(
      event.details
        .filter { UUID(uuidString: $0.value) == nil }
        .sorted { $0.key < $1.key }
        .prefix(3)
    )
  }
}

private struct AlarmCalendarInfluenceCard: View {
  let influences: [AlarmCalendarInfluence]
  let setIgnored: @MainActor (AlarmCalendarInfluence, Bool) async -> Void

  @State private var pendingInfluenceIDs: Set<CalendarEventOccurrenceID> = []

  var body: some View {
    RGCard(accent: RGTheme.orange) {
      VStack(alignment: .leading, spacing: 14) {
        RGSectionHeading(
          "Calendar Influence",
          eyebrow: "Why this wake time",
          detail:
            "Upcoming events can pull the alarm stack earlier. Ignore an event to keep it from affecting Grind Time."
        )

        if sortedInfluences.isEmpty {
          Label(
            "No calendar events are currently influencing the next wake time.",
            systemImage: "calendar.badge.checkmark"
          )
          .font(.subheadline)
          .foregroundStyle(RGTheme.mutedCream)
          .fixedSize(horizontal: false, vertical: true)
        } else {
          ForEach(Array(sortedInfluences.enumerated()), id: \.element.id) { index, influence in
            if index > 0 {
              Divider().overlay(RGTheme.cream.opacity(0.10))
            }

            HStack(spacing: 12) {
              Image(
                systemName:
                  influence.isIgnored
                  ? "calendar.badge.minus"
                  : "calendar.badge.clock"
              )
              .font(.headline)
              .foregroundStyle(
                influence.isIgnored ? RGTheme.mutedCream : RGTheme.orange
              )
              .frame(width: 30)

              VStack(alignment: .leading, spacing: 4) {
                Text(influence.title)
                  .font(.subheadline.weight(.bold))
                  .foregroundStyle(
                    influence.isIgnored ? RGTheme.mutedCream : RGTheme.cream
                  )
                  .lineLimit(2)
                  .strikethrough(influence.isIgnored, color: RGTheme.orange)

                HStack(spacing: 7) {
                  Text(
                    influence.startDate.formatted(
                      date: .abbreviated,
                      time: .shortened
                    )
                  )
                  .monospacedDigit()

                  if !influence.calendarTitle.isEmpty {
                    Text("•")
                    Text(influence.calendarTitle)
                      .lineLimit(1)
                  }

                  if influence.affectsRiseTime, !influence.isIgnored {
                    Text("SETS WAKE")
                      .font(.system(size: 8, weight: .black))
                      .tracking(0.55)
                      .foregroundStyle(RGTheme.orange)
                  } else if influence.isIgnored {
                    Text("IGNORED")
                      .font(.system(size: 8, weight: .black))
                      .tracking(0.55)
                      .foregroundStyle(RGTheme.mutedCream)
                  }
                }
                .font(.caption)
                .foregroundStyle(RGTheme.mutedCream)
              }

              Spacer(minLength: 6)

              Button {
                update(influence, ignored: !influence.isIgnored)
              } label: {
                if pendingInfluenceIDs.contains(influence.id) {
                  ProgressView()
                    .controlSize(.small)
                    .tint(RGTheme.cream)
                    .frame(minWidth: 52)
                } else {
                  Text(influence.isIgnored ? "Restore" : "Ignore")
                    .font(.caption.weight(.black))
                    .foregroundStyle(
                      influence.isIgnored ? RGTheme.mint : RGTheme.orange
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(
                      (influence.isIgnored ? RGTheme.mint : RGTheme.orange)
                        .opacity(0.10),
                      in: Capsule()
                    )
                    .overlay {
                      Capsule()
                        .stroke(
                          (influence.isIgnored ? RGTheme.mint : RGTheme.orange)
                            .opacity(0.30),
                          lineWidth: 1
                        )
                    }
                }
              }
              .buttonStyle(.plain)
              .disabled(pendingInfluenceIDs.contains(influence.id))
              .accessibilityLabel(
                influence.isIgnored
                  ? "Restore \(influence.title)"
                  : "Ignore \(influence.title)"
              )
            }
          }
        }
      }
    }
  }

  private var sortedInfluences: [AlarmCalendarInfluence] {
    influences.sorted {
      if $0.startDate == $1.startDate {
        return $0.id.storageKey < $1.id.storageKey
      }
      return $0.startDate < $1.startDate
    }
  }

  private func update(_ influence: AlarmCalendarInfluence, ignored: Bool) {
    pendingInfluenceIDs.insert(influence.id)
    Task { @MainActor in
      await setIgnored(influence, ignored)
      pendingInfluenceIDs.remove(influence.id)
    }
  }
}

extension AlarmLedgerOwner {
  fileprivate var agendaLabel: String {
    switch self {
    case .barrage: "Morning stack"
    case .powerNap: "Power nap"
    case .test: "Test"
    @unknown default: "Alarm"
    }
  }
}

extension AlarmLedgerType {
  fileprivate var agendaLabel: String {
    switch self {
    case .routine: "Routine alarm"
    case .calendarAdjusted: "Calendar-adjusted alarm"
    case .powerNap: "Power nap"
    case .test: "Test alarm"
    @unknown default: "Alarm"
    }
  }
}

extension AlarmUserOverride {
  fileprivate var agendaSummary: String {
    let challenge = requiresChallenge ? "Challenge required" : "Direct dismissal"
    let mute = isMuted ? "Muted" : "Audible"
    return "\(challenge) • \(mute) • \(musicIntensity.displayName) intensity"
  }
}

extension AlarmLedgerSlot {
  fileprivate func agendaLabel(current: AlarmLedgerCurrentState) -> String {
    switch self {
    case .primary(let slotFromFinal):
      if slotFromFinal == 0 {
        return "Grind Time • challenge"
      }
      // The stack carries the challenge alarm on top of the nudges.
      return "Nudge \(current.ordinal)/\(max(1, current.total - 1))"
    case .relay:
      // Retired slot; kept only so legacy ledgers still decode.
      return "Follow-up coverage"
    @unknown default:
      return "Alarm \(current.ordinal)/\(current.total)"
    }
  }
}

extension AlarmLedgerLifecycleState {
  fileprivate var agendaLabel: String {
    switch self {
    case .planned: "Planned"
    case .scheduled: "Armed"
    case .alerting: "Alerting"
    case .activePreChallenge: "Challenge ready"
    case .activeInChallenge: "Challenge active"
    case .snoozed: "Snoozed"
    case .challengeCompleted: "Challenge done"
    case .completed: "Completed"
    case .silenced: "Silenced"
    case .deprecated: "Retired"
    case .failed: "Failed"
    @unknown default: "Unknown"
    }
  }

  fileprivate var agendaIcon: String {
    switch self {
    case .planned: "calendar.badge.clock"
    case .scheduled: "alarm.fill"
    case .alerting: "alarm.waves.left.and.right.fill"
    case .activePreChallenge: "figure.strengthtraining.traditional"
    case .activeInChallenge: "figure.highintensity.intervaltraining"
    case .snoozed: "zzz"
    case .challengeCompleted: "trophy.fill"
    case .completed: "checkmark.circle.fill"
    case .silenced: "speaker.slash.fill"
    case .deprecated: "archivebox.fill"
    case .failed: "exclamationmark.triangle.fill"
    @unknown default: "questionmark.circle.fill"
    }
  }

  fileprivate var agendaColor: Color {
    switch self {
    case .planned: RGTheme.coolBlue
    case .scheduled: RGTheme.mint
    case .alerting, .activePreChallenge, .activeInChallenge: RGTheme.orange
    case .snoozed: RGTheme.gold
    case .challengeCompleted, .completed: RGTheme.mint
    case .silenced, .deprecated: RGTheme.mutedCream
    case .failed: RGTheme.danger
    @unknown default: RGTheme.mutedCream
    }
  }
}

extension AlarmIntensityTier {
  fileprivate var agendaColor: Color {
    switch self {
    case .soothing: RGTheme.coolBlue
    case .relaxing: RGTheme.mint
    case .motivating: RGTheme.gold
    case .energizing: RGTheme.orange
    case .abrasive: RGTheme.danger
    @unknown default: RGTheme.mutedCream
    }
  }

  fileprivate var agendaIcon: String {
    switch self {
    case .soothing: "cloud.moon.fill"
    case .relaxing: "leaf.fill"
    case .motivating: "bolt.fill"
    case .energizing: "flame.fill"
    case .abrasive: "exclamationmark.3"
    @unknown default: "music.note"
    }
  }
}

extension AlarmLedgerEventKind {
  fileprivate var agendaLabel: String {
    switch self {
    case .created: "Alarm created"
    case .configurationChanged: "Schedule changed"
    case .deliveryChanged: "Delivery refreshed"
    case .lifecycleChanged: "State changed"
    case .deprecated: "Alarm retired"
    case .restored: "Alarm restored"
    case .challengeStarted: "Challenge started"
    case .challengeProgressed: "Challenge progress"
    case .challengeCompleted: "Challenge completed"
    case .userOverrideChanged: "Overrides changed"
    @unknown default: "Alarm updated"
    }
  }

  fileprivate var agendaIcon: String {
    switch self {
    case .created: "plus.circle.fill"
    case .configurationChanged: "slider.horizontal.3"
    case .deliveryChanged: "arrow.triangle.2.circlepath"
    case .lifecycleChanged: "waveform.path"
    case .deprecated: "archivebox.fill"
    case .restored: "arrow.uturn.forward.circle.fill"
    case .challengeStarted: "figure.strengthtraining.traditional"
    case .challengeProgressed: "chart.line.uptrend.xyaxis"
    case .challengeCompleted: "trophy.fill"
    case .userOverrideChanged: "slider.horizontal.3"
    @unknown default: "circle.fill"
    }
  }

  fileprivate var agendaColor: Color {
    switch self {
    case .created, .restored: RGTheme.mint
    case .configurationChanged, .deliveryChanged: RGTheme.gold
    case .lifecycleChanged, .challengeStarted, .challengeProgressed: RGTheme.coolBlue
    case .challengeCompleted: RGTheme.mint
    case .deprecated: RGTheme.orange
    case .userOverrideChanged: RGTheme.magenta
    @unknown default: RGTheme.mutedCream
    }
  }
}

extension AlarmLedgerEvent {
  fileprivate var agendaSummary: String {
    guard let followUpNote else { return primaryAgendaSummary }
    return primaryAgendaSummary + " " + followUpNote
  }

  /// Describes follow-up coverage whenever this event changed how much of it exists.
  ///
  /// Follow-up deliveries usually arrive alongside another change, so this reads
  /// as an extra clause rather than replacing the primary summary.
  private var followUpNote: String? {
    let previousCount = before?.supportingDeliveryIDs.count ?? 0
    let nextCount = after?.supportingDeliveryIDs.count ?? 0
    guard previousCount != nextCount else { return nil }
    guard nextCount > 0 else {
      return "Follow-up coverage was released."
    }
    return
      "Scheduled \(nextCount) follow-up AlarmKit deliveries so this alarm keeps "
      + "sounding past the system's per-alarm limit."
  }

  private var primaryAgendaSummary: String {
    guard let before, let after else {
      if let after {
        return
          "Persistent alarm created for "
          + after.fireDate.formatted(date: .abbreviated, time: .shortened)
          + "."
      }
      return "A persistent audit event was recorded."
    }

    if before.fireDate != after.fireDate {
      return
        "Moved from "
        + before.fireDate.formatted(date: .abbreviated, time: .shortened)
        + " to "
        + after.fireDate.formatted(date: .abbreviated, time: .shortened)
        + "."
    }
    if before.lifecycle != after.lifecycle {
      return
        before.lifecycle.agendaLabel
        + " → "
        + after.lifecycle.agendaLabel
        + "."
    }
    if before.userOverride != after.userOverride {
      var changes: [String] = []
      if before.userOverride.requiresChallenge != after.userOverride.requiresChallenge {
        changes.append(
          after.userOverride.requiresChallenge ? "challenge required" : "challenge removed")
      }
      if before.userOverride.isMuted != after.userOverride.isMuted {
        changes.append(after.userOverride.isMuted ? "alarm muted" : "alarm unmuted")
      }
      if before.userOverride.musicIntensity != after.userOverride.musicIntensity {
        changes.append("music set to \(after.userOverride.musicIntensity.displayName)")
      }
      if before.userOverride.requestedVolume != after.userOverride.requestedVolume {
        changes.append("volume preference changed")
      }
      return changes.isEmpty
        ? "User-controlled alarm behavior changed."
        : changes.joined(separator: ", ").capitalized + "."
    }
    if before.supportingDeliveryIDs != after.supportingDeliveryIDs {
      return "Follow-up coverage for this alarm was rescheduled."
    }
    if before.physicalDeliveryID != after.physicalDeliveryID {
      return "The AlarmKit delivery changed while this logical alarm kept its identity."
    }
    if before.title != after.title {
      return "The alarm description changed without replacing its persistent record."
    }
    return "Alarm configuration was updated without replacing its persistent record."
  }
}
