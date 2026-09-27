#if DEBUG
import SwiftUI
import UIKit

struct JevEvaluationView: View {
    @State private var evaluation: JevEvaluation
    @State private var share: EvaluationExport?
    @State private var exportError: String?
    @Environment(\.scenePhase) private var scenePhase
    init(connection: SubscriptionConnection) {
        _evaluation = State(initialValue: JevEvaluation(connection: connection))
    }
    // Also used by the native, network-stubbed UI verification harness.
    init(evaluation: JevEvaluation) { _evaluation = State(initialValue: evaluation) }

    var body: some View {
        List {
            Section {
                Text("8 个固定场景 × Jev 开/关 × 2 次 = 32 个独立对话。使用已有主模型登录与 Jev 密钥，会消耗现有额度；32 个对话可能产生更多请求。")
                Text("只使用每次重置的虚构库存；确认也仅写入临时库。不读取真实库存、笔记或聊天，不发送通知，不改变你的 Jev 开关。")
                    .foregroundStyle(.secondary)
            } header: { Text("自动对照 · Debug") }
            Section {
                Text(evaluation.status).accessibilityIdentifier("evaluation.status")
                if evaluation.running {
                    ProgressView(value: Double(evaluation.results.count), total: 32)
                    Text(evaluation.current).font(.subheadline)
                    Button("停止测试", role: .destructive) { evaluation.cancel() }
                        .accessibilityIdentifier("evaluation.cancel")
                } else {
                    Button(evaluation.results.isEmpty ? "开始 32 个测试对话" : "重新开始（替换本页结果）") { evaluation.start() }
                        .disabled(!evaluation.ready)
                        .accessibilityIdentifier("evaluation.start")
                    if !evaluation.ready { Text("请先在上一级设置确认主模型已登录、Jev 密钥已保存；无需为测试另配账号。") }
                }
                if !evaluation.results.isEmpty && !evaluation.running {
                    Button("分享 JSON 结果（含已完成部分）") { export() }
                        .accessibilityIdentifier("evaluation.export")
                }
                if let exportError { Text(exportError).foregroundStyle(.red) }
            } footer: {
                Text("运行期间屏幕保持常亮。请保持前台；主动锁屏、离开页面或进入后台会停止。离开前请先导出结果。每例最多 90 秒，整批 20 分钟；每例主模型 6 次/Jev 8 次，整批主模型 192 次/Jev 128 次。计数含重试，不含连通性探测及授权刷新，不是费用账单。")
            }
            if !evaluation.results.isEmpty {
                Section("结果摘要") {
                    summary(enabled: false)
                    summary(enabled: true)
                    LabeledContent("主模型请求", value: "\(evaluation.results.reduce(0) { $0 + $1.modelRequests })")
                    LabeledContent("Jev 尝试 / 成功 / 失败", value: jevSummary)
                    Text("Jev 失败回退或未实际调用的开启样本单独列出，不计入有效开启样本。两次重复只用于初步比较，不能据此断言稳定优劣。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("逐例结果") {
                    ForEach(evaluation.results) { result in
                        DisclosureGroup("\(result.id). \(result.scenario.title) · \(result.jevEnabled ? "开" : "关") · \(label(result.verdict))") {
                            Text("输入：\(result.scenario.input)")
                            Text("期望：\(result.expected)")
                            Text("提议：\(result.proposals.joined(separator: "；"))")
                            Text("耗时 \(result.seconds, specifier: "%.1f") 秒 · 主模型 \(result.modelRequests) 次 · Jev \(result.jevRequests) 次")
                            Text("Jev 独立耗时 \(result.jevAttempts.reduce(0) { $0 + $1.seconds }, specifier: "%.2f") 秒")
                            ForEach(result.assertions.keys.sorted(), id: \.self) { key in
                                Text("\(result.assertions[key] == true ? "✓" : "✗") \(key)")
                            }
                            if let error = result.error { Text(error).foregroundStyle(.red) }
                        }.font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Jev 自动对照").navigationBarTitleDisplayMode(.inline)
        .onDisappear { evaluation.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { evaluation.cancel() } }
        .sheet(item: $share) { item in EvaluationShareSheet(export: item) }
    }

    private var jevSummary: String {
        let attempts = evaluation.results.flatMap(\.jevAttempts)
        return "\(evaluation.results.reduce(0) { $0 + $1.jevRequests }) / \(attempts.filter(\.succeeded).count) / \(attempts.filter { !$0.succeeded }.count)"
    }
    private func summary(enabled: Bool) -> some View {
        let samples = evaluation.results.filter { $0.jevEnabled == enabled }
        let valid = samples.filter { ["pass", "fail"].contains($0.verdict) }
        let elapsed = valid.reduce(0) { $0 + $1.seconds } / Double(max(1, valid.count))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Jev \(enabled ? "开" : "关")：\(valid.filter { $0.verdict == "pass" }.count)/\(valid.count) 有效样本通过")
            Text("未纳入 \(samples.count - valid.count) 例 · 有效样本均耗时 \(elapsed, specifier: "%.1f") 秒")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func label(_ verdict: String) -> String {
        switch verdict {
        case "pass": "通过"
        case "fail": "不符合预期"
        case "jev_fallback": "Jev 失败回退"
        case "jev_not_exercised": "未实际调用 Jev"
        case "cancelled": "已取消"
        default: "已停止"
        }
    }
    private func export() {
        do {
            share = try EvaluationExport(data: evaluation.export())
            exportError = nil
        } catch { exportError = "结果导出失败，请重试。" }
    }
}

/// Both the presenting view and sheet retain the file; releasing the sheet cannot delete it early.
final class EvaluationExport: Identifiable {
    let id = UUID()
    nonisolated let url: URL
    init(data: Data) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("butler-jev-results-\(UUID()).json")
        try data.write(to: url, options: .atomic)
    }
    nonisolated deinit { try? FileManager.default.removeItem(at: url) }
}

struct EvaluationShareSheet: UIViewControllerRepresentable {
    let export: EvaluationExport
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [export.url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
