import Foundation

struct ButlerSettingChange: Equatable {
    let key: String
    let before: String
    let after: String
}

extension Notification.Name {
    static let butlerSettingsChanged = Notification.Name("butlerSettingsChanged")
}

/// Typed configuration shared by the model and native controls. Credentials are never exposed.
@MainActor
enum ButlerSettingsService {
    static let definitions: [(key: String, title: String, fallback: String, values: String)] = [
        ("appearanceMode", "显示模式", "system", "system,light,dark"),
        ("accentChoice", "主题色", "glass", "glass,celadon,ocean,amber,berry,dusk"),
        ("appTheme", "主题背景", "mist", "mist,window,plain"),
        ("expiryWarningDays", "到期提前天数", "2", "0,1,2,3,7"),
        ("reminderMinutes", "默认提醒时刻（零点起分钟数）", "540", "0...1439"),
        ("jevEnabled", "启用 Jev", "true", "true,false"),
        ("jevPrefetchEnabled", "提前准备查询资料", "true", "true,false"),
        ("showSystemCalendar", "显示系统日历（仍需系统授权）", "false", "true,false"),
        ("butlerProfile", "关于我和家里", "", "最多4000字")
    ]

    static func value(_ key: String, defaults: UserDefaults) -> String {
        guard let definition = definitions.first(where: { $0.key == key }) else { return "" }
        if key == "appTheme" { return AppTheme.stored(in: defaults).rawValue }
        guard let object = defaults.object(forKey: key) else { return definition.fallback }
        if ["jevEnabled", "jevPrefetchEnabled", "showSystemCalendar"].contains(key) {
            return defaults.bool(forKey: key) ? "true" : "false"
        }
        return String(describing: object)
    }

    static func snapshot(defaults: UserDefaults) -> [[String: String]] {
        definitions.map { ["key": $0.key, "title": $0.title, "value": value($0.key, defaults: defaults), "allowed": $0.values] }
    }

    static func proposal(key: String, value: String, defaults: UserDefaults) throws -> ButlerSettingChange {
        guard let definition = definitions.first(where: { $0.key == key }) else {
            throw ButlerTools.ToolError("这项设置不能通过管家修改；密钥和系统权限请使用对应设置入口")
        }
        if key == "butlerProfile" {
            guard value.count <= 4000 else { throw ButlerTools.ToolError("家庭背景最多4000字") }
        } else if key == "reminderMinutes" {
            guard let minute = Int(value), (0..<1440).contains(minute) else { throw ButlerTools.ToolError("提醒时刻须为0到1439分钟") }
        } else {
            guard definition.values.split(separator: ",").contains(Substring(value)) else {
                throw ButlerTools.ToolError("\(definition.title)的值无效，允许：\(definition.values)")
            }
        }
        return ButlerSettingChange(key: key, before: self.value(key, defaults: defaults), after: value)
    }

    static func apply(_ changes: [ButlerSettingChange], defaults: UserDefaults, jev: JevClient?) throws {
        // Validate the whole batch before writing anything; reject previews made against old values.
        guard Set(changes.map(\.key)).count == changes.count else { throw ButlerTools.ToolError("同一设置不能重复修改") }
        for change in changes {
            _ = try proposal(key: change.key, value: change.after, defaults: defaults)
            guard value(change.key, defaults: defaults) == change.before else {
                throw ButlerTools.ToolError("设置已经改变，请重新读取后提出修改")
            }
        }
        for change in changes {
            switch change.key {
            case "expiryWarningDays", "reminderMinutes": defaults.set(Int(change.after), forKey: change.key)
            case "jevEnabled", "jevPrefetchEnabled", "showSystemCalendar":
                defaults.set(change.after == "true", forKey: change.key)
            default: defaults.set(change.after, forKey: change.key)
            }
            if change.key == "jevEnabled" { jev?.isEnabled = change.after == "true" }
            if change.key == "jevPrefetchEnabled" { jev?.prefetchEnabled = change.after == "true" }
        }
        NotificationCenter.default.post(name: .butlerSettingsChanged, object: nil)
    }
}
