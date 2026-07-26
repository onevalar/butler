//
//  VoiceInputView.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import SwiftUI

struct VoiceInputView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataManager.self) private var dataManager

    @State private var inputText: String = ""
    @State private var isProcessing: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    // Voice recording
    @State private var voiceManager = VoiceManager()
    @State private var isRecording: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // MARK: - Header
                VStack(spacing: 8) {
                    Image(systemName: isRecording ? "waveform" : "text.bubble")
                        .font(.system(size: 50))
                        .foregroundStyle(isRecording ? .red : .blue)
                        .symbolEffect(.pulse, isActive: isRecording)

                    Text("添加物品")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(isRecording ? "正在聆听，请说话..." : "语音或文字输入物品信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .animation(.default, value: isRecording)
                }

                // MARK: - Text Input
                VStack(alignment: .leading, spacing: 8) {
                    TextField("例如：三瓶牛奶明天过期", text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                        .focused($isTextFieldFocused)
                        .padding(.horizontal)

                    // Quick input suggestions
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(quickInputSuggestions, id: \.self) { suggestion in
                                Button {
                                    inputText = suggestion
                                } label: {
                                    Text(suggestion)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Spacer()

                // MARK: - Action Buttons
                HStack(spacing: 16) {
                    // Microphone button
                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(isRecording ? .red : Color.secondary)
                            .symbolEffect(.pulse, isActive: isRecording)
                    }
                    .accessibilityLabel(isRecording ? "停止录音" : "开始语音输入")

                    // Submit button
                    Button {
                        submitInput()
                    } label: {
                        HStack(spacing: 12) {
                            if isProcessing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                            }
                            Text(isProcessing ? "处理中..." : "添加")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(inputText.isEmpty ? Color.secondary : Color.accentColor)
                        .clipShape(Capsule())
                    }
                    .disabled(inputText.isEmpty || isProcessing)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle("添加物品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        if isRecording { voiceManager.cancel() }
                        dismiss()
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isTextFieldFocused = true
                }
            }
            // Sync recording state from VoiceManager
            .onChange(of: voiceManager.state) { _, newState in
                switch newState {
                case .idle, .error:
                    isRecording = false
                case .recording:
                    isRecording = true
                case .processing:
                    break
                }
            }
            // Live transcript → fill text field
            .onChange(of: voiceManager.transcribedText) { _, newValue in
                if !newValue.isEmpty {
                    inputText = newValue
                }
            }
        }
    }

    // MARK: - Quick Input Suggestions

    private var quickInputSuggestions: [String] {
        [
            "三瓶牛奶明天过期",
            "一盒鸡蛋下周过期",
            "两袋面包后天过期",
            "感冒药一盒",
            "洗衣液一瓶"
        ]
    }

    // MARK: - Voice Recording

    private func toggleRecording() {
        if isRecording {
            Task {
                _ = await voiceManager.stopRecordingAndProcess()
                // inputText is already updated live via onChange(of: voiceManager.transcribedText)
            }
        } else {
            Task {
                let authorized = await voiceManager.requestAuthorization()
                guard authorized else { return }
                do {
                    try voiceManager.startRecording()
                } catch {
                    print("Voice recording error: \(error)")
                }
            }
        }
    }

    // MARK: - Submit Logic

    private func submitInput() {
        guard !inputText.isEmpty else { return }
        if isRecording { voiceManager.cancel() }

        isProcessing = true

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s for UX feel

            await parseAndAddItem(from: inputText)

            await MainActor.run {
                isProcessing = false
                dismiss()
            }
        }
    }

    // MARK: - Parse and Add Item

    private func parseAndAddItem(from text: String) async {
        let parsed = parseSimpleInput(text)
        for item in parsed {
            dataManager.addItem(from: item, source: .voice(transcript: text))
        }
        await MainActor.run {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }

    // MARK: - Simple Text Parser

    private func parseSimpleInput(_ text: String) -> [ParsedItemInput] {
        let quantity = extractQuantity(from: text)
        let unit = extractUnit(from: text)
        let name = extractItemName(from: text)
        let expiryDate = extractDate(from: text)
        let itemType = guessItemType(from: name)

        return [ParsedItemInput(
            name: name,
            quantity: quantity,
            unit: unit,
            suggestedType: itemType,
            expiryDate: expiryDate,
            storageHint: nil,
            confidence: 0.8
        )]
    }

    // MARK: - Parsing Helpers

    private func extractQuantity(from text: String) -> Int {
        // Arabic numerals first
        let arabicNumbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        if let first = arabicNumbers.first { return first }

        // Chinese numerals
        let cnNumbers: [String: Int] = [
            "一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]
        for (char, val) in cnNumbers {
            if text.contains(char) { return val }
        }

        return 1
    }

    private func extractUnit(from text: String) -> String? {
        let units = ["瓶", "盒", "袋", "包", "罐", "支", "条", "片", "只", "斤", "块", "桶"]
        return units.first { text.contains($0) }
    }

    private func extractItemName(from text: String) -> String {
        var name = text
        let removeWords = [
            "个", "瓶", "盒", "袋", "包", "罐", "支", "条", "片", "只", "斤", "块", "桶",
            "明天", "后天", "下周", "一周", "七天", "一个月",
            "过期",
            "一", "两", "二", "三", "四", "五", "六", "七", "八", "九", "十"
        ]
        for word in removeWords {
            name = name.replacingOccurrences(of: word, with: "")
        }
        // Remove Arabic digits
        name = name.components(separatedBy: CharacterSet.decimalDigits).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未知物品" : name
    }

    /// Returns nil if no date keyword is found — allows Butler Engine R1 rule to trigger.
    private func extractDate(from text: String) -> Date? {
        let calendar = Calendar.current
        let today = Date()

        if text.contains("明天") {
            return calendar.date(byAdding: .day, value: 1, to: today)
        } else if text.contains("后天") {
            return calendar.date(byAdding: .day, value: 2, to: today)
        } else if text.contains("下周") {
            return calendar.date(byAdding: .day, value: 7, to: today)
        } else if text.contains("一周") || text.contains("七天") {
            return calendar.date(byAdding: .day, value: 7, to: today)
        } else if text.contains("一个月") {
            return calendar.date(byAdding: .month, value: 1, to: today)
        }

        // No date keyword found → return nil so DataManager can apply R1/R2 logic
        return nil
    }

    private func guessItemType(from name: String) -> ItemType {
        if name.contains("牛奶") || name.contains("酸奶") || name.contains("面包") ||
           name.contains("鸡蛋") || name.contains("肉") || name.contains("鱼") ||
           name.contains("菜") || name.contains("果") {
            return .fresh
        }
        if name.contains("药") || name.contains("胶囊") {
            return .medicine
        }
        if name.contains("洗") || name.contains("纸") || name.contains("液") {
            return .general
        }
        return .pantry
    }
}

#Preview {
    VoiceInputView()
        .environment(PreviewData.dataManager)
}
