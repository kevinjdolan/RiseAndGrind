// Lists upcoming app-owned attacks.

import RiseAndGrindCore
import SwiftUI

struct CalendarOverrideView: View {
  let scheduledAlarms: [ScheduledAlarmRecord]
  let scheduledTestAlarms: [ScheduledAlarmRecord]
  let scheduledPowerNaps: [ScheduledAlarmRecord]
  let mutedAlarms: [ScheduledAlarmRecord]
  let muteState: AlarmMuteState?

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
    (scheduledAlarms + scheduledTestAlarms + scheduledPowerNaps)
      .sorted { $0.fireDate < $1.fireDate }
  }
}
