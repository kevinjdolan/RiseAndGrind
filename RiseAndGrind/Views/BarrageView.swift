// Configures barrage cadence and previews the resulting schedule.

import RiseAndGrindCore
import SwiftUI

struct BarrageView: View {
  @Binding var settings: RiseAndGrindSettings
  let scheduledAlarms: [ScheduledAlarmRecord]
  let scheduledTestAlarms: [ScheduledAlarmRecord]
  let scheduledPowerNaps: [ScheduledAlarmRecord]
  let mutedAlarms: [ScheduledAlarmRecord]
  let muteState: AlarmMuteState?

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          RGCard(accent: RGTheme.magenta) {
            VStack(alignment: .leading, spacing: 16) {
              RGSectionHeading("Alarm Stack Config")
              RGLadderEditor(
                count: $settings.barrage.alarmCount,
                spacingMinutes: $settings.barrage.spacingMinutes,
                finalWarningMinutes: $settings.barrage.finalWarningMinutes
              )
            }
          }

          RGScheduledAlarmList(
            alarms: activeScheduledAlarms,
            mutedAlarms: mutedAlarms,
            muteState: muteState
          )
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Stack")
    .rgInlineNavigationTitle()
  }

  private var activeScheduledAlarms: [ScheduledAlarmRecord] {
    (scheduledAlarms + scheduledTestAlarms + scheduledPowerNaps)
      .sorted { $0.fireDate < $1.fireDate }
  }
}
