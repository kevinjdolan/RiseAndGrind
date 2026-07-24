// Configures barrage cadence and previews the resulting schedule.

import RiseAndGrindCore
import SwiftUI

struct BarrageView: View {
  @Binding var settings: RiseAndGrindSettings

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 18) {
          RGCard(accent: RGTheme.magenta) {
            VStack(alignment: .leading, spacing: 16) {
              RGSectionHeading("Attack Stack Configuration")
              RGLadderEditor(
                count: $settings.barrage.alarmCount,
                spacingMinutes: $settings.barrage.spacingMinutes,
                finalWarningMinutes: $settings.barrage.finalWarningMinutes
              )
            }
          }

          RGScenarioSimulator(
            count: settings.barrage.alarmCount,
            spacingMinutes: settings.barrage.spacingMinutes,
            finalWarningMinutes: settings.barrage.finalWarningMinutes,
            grindHour: settings.grindHour,
            grindMinute: settings.grindMinute,
            eventBufferMinutes: settings.eventBufferMinutes
          )

        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Attack Stack Configuration")
    .rgInlineNavigationTitle()
  }
}
