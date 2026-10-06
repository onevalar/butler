import Foundation

/// Tool definitions sent to the model. They are dictionary literals, so serialization cannot fail.
enum ToolSchema {
    static func json(_ tools: [[String: Any]], sortedKeys: Bool = false) -> String {
        tools.map { json($0, sortedKeys: sortedKeys) }.joined(separator: ",")
    }

    static func json(_ tool: [String: Any], sortedKeys: Bool = false) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: tool, options: sortedKeys ? [.sortedKeys] : []), as: UTF8.self)
    }
}
