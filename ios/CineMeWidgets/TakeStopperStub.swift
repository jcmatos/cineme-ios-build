// Only so CineMeShared/TakeActivity.swift builds in the widget target. StopTakeIntent is a
// LiveActivityIntent: iOS runs it in the app, where the real TakeStopper is (SystemIntents.swift).
enum TakeStopper {
    static func stop() async {}
}
