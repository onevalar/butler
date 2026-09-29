import SwiftUI

struct SpeechRecognitionSettingsView: View {
    @State private var provider = SpeechRecognitionProvider.apple
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var message: String?
    @State private var saveFailed = false
    @State private var checking = false
    private let settings = SpeechRecognitionSettings()
    private var realtime: Bool { model.trimmingCharacters(in: .whitespacesAndNewlines) == "gpt-live-transcribe" }

    var body: some View {
        Form {
            Section {
                Picker("识别服务", selection: $provider) {
                    ForEach(SpeechRecognitionProvider.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(provider == .apple
                     ? "默认使用苹果语音识别，支持边说边显示文字。优先使用系统语音分析器，必要时使用苹果在线识别服务。"
                     : realtime ? "实时识别：说话时持续上传音频并显示文字，松手后发送。上滑取消会断开连接并丢弃文字，已经上传的音频无法撤回。"
                     : "录音结束后上传到你配置的服务，再返回识别文字；录音期间显示声条，不逐字显示结果。上滑取消的录音不会上传。")
            }
            .glassRows()
            if provider == .custom {
                Section {
                    TextField("Base URL（如 https://服务地址/v1）", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("语音服务 Base URL")
                    TextField("模型名称（服务商提供的 Model ID）", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("语音模型名称")
                    SecureField(hasSavedKey ? "API Key（留空保留当前密钥）" : "API Key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("服务配置")
                } footer: {
                    Text(realtime
                         ? "gpt-live-transcribe 使用实时语音接口。AiHubMix 可填 https://aihubmix.com/v1 或 https://api.inferera.com/v1；仅填这两个域名时会自动补全 /v1。\n密钥保存在此设备的系统钥匙串，更换服务地址需重新填写。每次最长录音 2 分钟。"
                         : "支持 OpenAI 兼容的 /audio/transcriptions 文件转写接口，可填写 Base URL 或完整接口地址。AiHubMix 地址包含 /v1；仅有聊天接口的模型不能用于语音识别。\n密钥保存在此设备的系统钥匙串，更换服务地址需重新填写。每次最长录音 2 分钟，录音结束后需要网络识别时间。")
                }
                .glassRows()
            }
            Section {
                Button("保存语音设置") {
                    do {
                        try settings.save(provider: provider, baseURL: baseURL, model: model, newKey: apiKey)
                        apiKey = ""
                        hasSavedKey = settings.hasSavedKey
                        saveFailed = false
                        message = "已保存，下一次语音输入生效。"
                    } catch { saveFailed = true; message = error.localizedDescription }
                }
                if provider == .custom, realtime {
                    Button(checking ? "正在检查连接…" : "检查已保存的实时语音连接") {
                        checking = true
                        Task { @MainActor in
                            defer { checking = false }
                            do {
                                let config = try settings.customConfiguration()
                                guard config.usesRealtime else {
                                    throw SpeechServiceError.invalidConfiguration("请先保存实时模型的配置。")
                                }
                                try await RealtimeSpeechClient(configuration: config).checkConnection(model: config.model)
                                saveFailed = false
                                message = "鉴权成功，实时会话配置已被接受。未录音或上传音频。"
                            } catch { saveFailed = true; message = (error as? SpeechServiceError)?.localizedDescription ?? "连接超时或中断，请检查网络后重试。" }
                        }
                    }
                    .disabled(checking)
                }
                if let message { Text(message).foregroundStyle(saveFailed ? Color.red : Color.secondary) }
            } footer: {
                Text("应用于所有页面的水晶球、对话框麦克风和语音试用页。自定义服务不可用时会提示错误，不会自动切换服务或把录音发往其他地址。")
            }
            .glassRows()
            if hasSavedKey {
                Section {
                    Button("移除自定义配置与密钥", role: .destructive) {
                        do {
                            try settings.removeCustomConfiguration()
                            load()
                            message = "已移除，恢复使用苹果语音识别。"
                            saveFailed = false
                        } catch { saveFailed = true; message = error.localizedDescription }
                    }
                }
                .glassRows()
            }
        }
        .glassList()
        .navigationTitle("语音识别").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        provider = settings.provider
        baseURL = settings.baseURL
        model = settings.model
        apiKey = ""
        hasSavedKey = settings.hasSavedKey
    }
}
