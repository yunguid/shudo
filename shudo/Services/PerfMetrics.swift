import os

/// Timestamped phase markers for the latency-critical journeys: microphone
/// capture, composer presentation, photo preparation, day loads, and meal
/// submission. Each mark is a single os_log line under subsystem
/// "luke.shudo" / category "perf" — cheap enough for release builds (no
/// string formatting beyond the static name) and parseable from
/// `log stream` during automated latency measurements.
enum Perf {
    private static let logger = Logger(subsystem: "luke.shudo", category: "perf")

    /// Marks a named instant on the timeline. Names are dot-separated
    /// phases, e.g. "mic.tap", "mic.record.live", "composer.appear".
    static func mark(_ name: StaticString) {
        logger.info("\(String(describing: name), privacy: .public)")
    }
}
