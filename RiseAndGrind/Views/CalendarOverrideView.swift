// Lists upcoming app-owned attacks and provides alarm cleanup controls.

import RiseAndGrindCore
import SwiftUI

struct CalendarOverrideView: View {
  let scheduledAlarms: [ScheduledAlarmRecord]
  let scheduledTestAlarms: [ScheduledAlarmRecord]
  let mutedAlarms: [ScheduledAlarmRecord]
  let muteState: AlarmMuteState?
  let isWorking: Bool
  let cancel: () -> Void

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          VStack(spacing: 18) {
            RGScheduledAlarmList(
              alarms: activeScheduledAlarms,
              mutedAlarms: mutedAlarms,
              muteState: muteState
            )

            if activeScheduledAlarms.isEmpty == false {
              Button(role: .destructive, action: cancel) {
                Label("Clear alarms", systemImage: "trash")
              }
              .buttonStyle(RGSecondaryButtonStyle())
              .disabled(isWorking)
            }
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Alarms")
    .rgInlineNavigationTitle()
  }

  private var activeScheduledAlarms: [ScheduledAlarmRecord] {
    (scheduledAlarms + scheduledTestAlarms)
      .sorted { $0.fireDate < $1.fireDate }
  }

}
