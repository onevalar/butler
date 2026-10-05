import SwiftUI
import UIKit

struct ScreenshotSetupView: View {
    @State private var installError: String?

    var body: some View {
        Form {
            Section {
                Text("看到想交给小当家的内容，打开控制中心点一次采集。截图会进入对话，你可以打字或说话补充要求，再发送。")
                ForEach(["打字", "语音"], id: \.self) { mode in
                    if let url = Bundle.main.url(forResource: "小当家截图" + mode, withExtension: "shortcut") {
                        ShortcutInstallButton(title: "安装\(mode)采集入口", url: url) { installError = $0 }
                    }
                }
            } header: { Text("安装入口") } footer: {
                Text("在系统菜单中选择「快捷指令」，进入添加页面后确认添加。语音沿用你在小当家中的语音识别配置。")
            }
            Section("添加到控制中心") {
                Text("打开控制中心 → 长按空白处 → 添加控制 → 快捷指令下的「运行快捷指令」。")
                Text("点新增的控制，选择「小当家截图打字」或「小当家截图语音」。")
            }
            Section {
                Text("无需手动添加截屏或等待动作。首次使用时按系统提示允许运行。截图只在你主动采集时取得；发送前保存在本机，发送时才交给对话模型。")
                Text("如果你已有实验入口，只需安装这里的正式入口，再将原控制选择的快捷指令换成它。")
            }
        }
        .navigationTitle("从其他 App 采集")
        .alert("无法打开快捷指令", isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            Button("知道了", role: .cancel) { installError = nil }
        } message: { Text(installError ?? "") }
    }
}
