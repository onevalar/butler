import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// Required by AlarmKit for countdown presentation. Management remains in the conversation.
struct ButlerAlarmWidget: Widget {
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

@main struct ButlerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ButlerAlarmWidget()
        ButlerTaskDisplayWidget()
        ButlerWidget()
    }
}

/// A display window, never evidence that its underlying task has completed.
struct ButlerTaskDisplayWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskDisplayAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.state.ended ? "展示已关闭" : context.isStale ? "展示已到期" : "任务限时展示")
                    .font(.headline)
                remaining(context).font(.largeTitle.monospacedDigit())
                Text("展示结束不代表任务完成 · 轻点返回对话")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .widgetURL(WidgetDestination.task(context.attributes.taskID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text("限时展示") }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        remaining(context).font(.title.monospacedDigit())
                        Text("不代表任务完成").font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: "hourglass")
            } compactTrailing: {
                remaining(context).monospacedDigit().frame(maxWidth: 64)
            } minimal: {
                Image(systemName: context.isStale || context.state.ended ? "hourglass.bottomhalf.filled" : "hourglass")
            }
            .widgetURL(WidgetDestination.task(context.attributes.taskID).url)
        }
    }

    @ViewBuilder private func remaining(_ context: ActivityViewContext<TaskDisplayAttributes>) -> some View {
        if context.state.ended {
            Text("已关闭")
        } else if context.isStale || context.state.deadline <= Date.now {
            Text("已到期")
        } else {
            Text(timerInterval: min(Date.now, context.state.deadline)...context.state.deadline, countsDown: true)
        }
    }
}
