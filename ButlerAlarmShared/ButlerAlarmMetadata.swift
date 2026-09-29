import AlarmKit

/// Shared by the app and the countdown extension, with no access to the app's task database.
struct ButlerAlarmMetadata: AlarmMetadata {
    let title: String
}
