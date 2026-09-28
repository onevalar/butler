import Foundation

/// A read the phone actually performed before the main model's first request.
struct PrefetchedToolResult {
    let call: LocalToolCall
    let output: String
}
