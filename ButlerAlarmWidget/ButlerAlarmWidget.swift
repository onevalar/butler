import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// Required by AlarmKit for countdown presentation. Management remains in the conversation.
@main struct ButlerAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ButlerAlarmMetadata>.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.attributes.metadata?.title ?? "Butler 倒计时")
                    .font(.headline).lineLimit(2)
                remaining(context.state)
                    .font(.largeTitle.monospacedDigit())
                Text("通过 Butler 对话暂停、继续或取消")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.metadata?.title ?? "倒计时").lineLimit(2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    remaining(context.state).font(.title.monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                remaining(context.state).monospacedDigit().frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }

    @ViewBuilder private func remaining(_ state: AlarmPresentationState) -> some View {
        switch state.mode {
        case .countdown(let countdown):
            // A stale render may arrive after the deadline. Never construct a reversed ClosedRange.
            Text(timerInterval: min(Date.now, countdown.fireDate)...countdown.fireDate, countsDown: true)
        case .paused(let paused):
            Text(Duration.seconds(max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration))
                .formatted(.time(pattern: .hourMinuteSecond)))
        default:
            Text("响铃中")
        }
    }
}
