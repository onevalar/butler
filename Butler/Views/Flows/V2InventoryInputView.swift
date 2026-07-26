#if DEBUG
import SwiftUI

struct V2InventoryInputView: View {
    @Bindable var coordinator: InventoryInputCoordinator
    @State private var text = "我今天买了一瓶牛奶、三包方便面和一个冰激凌。冰激凌先放冰箱了还没吃。"
    @State private var voice = VoiceManager()

    var body: some View {
        Form {
            Section("V2 输入") {
                TextField("数量、单位和物品", text: $text, axis: .vertical)
                HStack {
                    Button(voice.state == .recording ? "停止录音" : "语音输入") { toggleVoice() }
                    Button("生成计划") { Task { await coordinator.submit(text: text) } }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || coordinator.state == .planning)
                }
                if case .error(let message) = voice.state { Text(message).foregroundStyle(.red) }
            }
            if coordinator.state == .clarifying { clarification }
            if let plan = coordinator.reviewPlan { review(plan) }
            if let error = coordinator.errorMessage { Section("错误") { Text(error).foregroundStyle(.red) } }
            if coordinator.state == .completed { Section { Label("已写入 V2 库存", systemImage: "checkmark.circle.fill") } }
        }
        .onChange(of: voice.transcribedText) { _, value in if !value.isEmpty { text = value } }
    }

    @ViewBuilder private var clarification: some View {
        Section("需要确认") {
            ForEach(Array(coordinator.questions.enumerated()), id: \.offset) { _, question in
                switch question {
                case .field(let field):
                    Text("冰箱是冷藏还是冷冻？")
                    HStack {
                        Button("冷藏") { coordinator.answerStorage(field, choice: .refrigerated) }
                        Button("冷冻") { coordinator.answerStorage(field, choice: .frozen) }
                    }
                case .productChoice(let operationID, _, let candidates):
                    Text("发现同名产品，请明确选择：")
                    ForEach(candidates) { candidate in
                        Button("使用已有：\(candidate.canonicalName)\(candidate.brand.map { " · \($0)" } ?? "")") {
                            coordinator.chooseProduct(createOperationID: operationID, choice: .existing(productID: candidate.id))
                        }
                    }
                    Button("仍创建独立产品") {
                        coordinator.chooseProduct(createOperationID: operationID, choice: .createSeparate)
                    }
                }
            }
        }
    }

    private func review(_ plan: InventoryOperationPlan) -> some View {
        Section("最终审核") {
            ForEach(plan.operations, id: \.operationID) { operation in
                if case .addLot(let lot) = operation.operation {
                    VStack(alignment: .leading, spacing: 4) {
                        if let product = coordinator.productDisplays[lot.productID] {
                            Text("\(product.canonicalName)\(product.brand.map { " · \($0)" } ?? "")")
                                .font(.headline)
                            Text(coordinator.existingProductIDs.contains(lot.productID) ? "加入已有产品" : "创建新产品")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("数量：\(lot.quantity) \(lot.unit)")
                        dateRow("包装有效期", lot.packageExpiryDate)
                        dateRow("估算有效期", lot.estimatedExpiryDate)
                        dateRow("计划用完", lot.plannedUseByDate)
                        Text("储存：\(lot.storageLocation ?? "未指定")")
                        Text("证据：" + lot.evidence.map { "\($0.fieldKey.rawValue) · \($0.source.rawValue)" }.joined(separator: "，"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !coordinator.confirmationRequirements.isEmpty {
                Text("下列高风险字段将由本次明确确认授权：" +
                     coordinator.confirmationRequirements.map(\.fieldKey.rawValue).joined(separator: "、"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if coordinator.state == .reviewing {
                Button("确认并添加") { coordinator.confirmAndExecute() }.buttonStyle(.borderedProminent)
            } else if coordinator.state == .executing { ProgressView("正在写入…") }
        }
    }

    private func dateRow(_ title: String, _ date: Date?) -> some View {
        HStack { Text(title + "："); Text(date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "无") }
    }

    private func toggleVoice() {
        if voice.state == .recording {
            Task { if let transcript = await voice.stopRecordingAndTranscribe() { text = transcript } }
        } else {
            Task {
                guard await voice.requestAuthorization() else { return }
                do { try voice.startRecording(requiresOnDeviceRecognition: true) } catch { voice.state = .error(error.localizedDescription) }
            }
        }
    }
}
#endif
