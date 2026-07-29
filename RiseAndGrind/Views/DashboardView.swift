// The primary Grind Time, event-buffer, and active-day configuration dashboard.

import Foundation
import RiseAndGrindCore
import SwiftUI

struct DashboardView: View {
  @Binding var settings: RiseAndGrindSettings
  let muteState: AlarmMuteState?
  let scheduledPowerNaps: [ScheduledAlarmRecord]
  let isWorking: Bool
  let schedulePowerNap: @MainActor (Date) async -> Bool
  let clearMute: @MainActor () async -> Void

  @State private var presentsPowerNapSheet = false
  @State private var powerNapTime = Date.now.addingTimeInterval(20 * 60)

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          RGAlarmConfigurationCard(settings: $settings)

          powerNapButton
            .buttonStyle(RGPowerNapButtonStyle())
            .disabled(isWorking)

          if let muteState {
            muteStatus(muteState)
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Regimen")
    .rgInlineNavigationTitle()
    .sheet(isPresented: $presentsPowerNapSheet) {
      RGPowerNapSheet(
        fireDate: $powerNapTime,
        isWorking: isWorking,
        schedule: schedulePowerNap
      )
    }
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
      .padding(.horizontal, 18)
    }
    .accessibilityLabel(
      activePowerNap == nil ? "Set Power Nap" : "Power Nap armed"
    )
    .accessibilityValue(
      activePowerNap?.fireDate.formatted(date: .omitted, time: .shortened) ?? "Not armed"
    )
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
