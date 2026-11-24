import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The take while recording: red dot, timer and format on the lock screen and in the Dynamic Island,
/// with a Stop key (StopTakeIntent: runs in the app). The timer counts by itself from the start time.
struct TakeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TakeAttributes.self) { context in
            // Lock screen, Notification Center, Apple Watch Smart Stack.
            HStack(spacing: 14) {
                Image(systemName: "record.circle.fill").font(.system(size: 30)).foregroundStyle(Palette.rec)
                VStack(alignment: .leading, spacing: 2) {
                    TakeTimer(start: context.state.start).font(.system(size: 30, weight: .semibold))
                    Text("CineMe · \(context.state.format)").font(.system(size: 14)).foregroundStyle(Palette.dim)
                }
                Spacer()
                StopKey()
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.75))
            .activitySystemActionForegroundColor(Palette.ivory)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("REC", systemImage: "record.circle.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.rec)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TakeTimer(start: context.state.start).font(.system(size: 22, weight: .semibold))
                        .frame(maxWidth: 110, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.format).font(.system(size: 15)).foregroundStyle(Palette.ivory)
                        Spacer()
                        StopKey()
                    }
                }
            } compactLeading: {
                Image(systemName: "record.circle.fill").foregroundStyle(Palette.rec)
            } compactTrailing: {
                TakeTimer(start: context.state.start).frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                Image(systemName: "record.circle.fill").foregroundStyle(Palette.rec)
            }
            .keylineTint(Palette.rec)
        }
    }
}

/// 0:42, 12:05, 1:02:10: counts up from the take's start.
struct TakeTimer: View {
    let start: Date
    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Palette.ivory)
    }
}

struct StopKey: View {
    var body: some View {
        Button(intent: StopTakeIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ivory)
        }
        .tint(Palette.rec)
    }
}
