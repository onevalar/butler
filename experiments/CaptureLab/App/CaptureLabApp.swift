import AVFoundation
import SwiftUI
import UIKit

@main
struct CaptureLabApp: App {
  var body: some Scene {
    WindowGroup { CaptureHome(model: .shared) }
  }
}

private struct CaptureHome: View {
  @Bindable var model: CaptureModel

  var body: some View {
    NavigationStack {
      Group {
        if let draft = model.draft {
          CaptureEditor(model: model, id: draft.id).id(draft.id)
        } else {
          List {
            Section {
              Text("只测试截图交接与自由输入。不会调用 AI、创建提醒或改变正式版数据。实验记录不参与 iCloud 同步或系统备份。")
                .font(.footnote)
            }
            if let error = model.error {
              Section("需要处理") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("等待截图") {
              Label("从控制中心运行你配置的采集快捷指令", systemImage: "camera.viewfinder")
              Text("系统先截取原 App 页面，再把图片交到这里。无需打开相册，也不需要预先选择分类。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            if let notice = model.notice { Section { Text(notice) } }
            Section("已保存的实验记录 · \(model.saved.count)") {
              ForEach(model.saved) { record in
                NavigationLink {
                  CaptureDetail(record: record, model: model)
                } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(record.text).lineLimit(2)
                    Text(
                      record.receivedAt, format: .dateTime.month().day().hour().minute().second()
                    )
                    .font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
      }
      .navigationTitle("小当家采集实验")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

private struct CaptureEditor: View {
  @Bindable var model: CaptureModel
  let id: UUID
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focused: Bool
  @State private var speech = CaptureSpeech()
  @State private var voiceTask: Task<Void, Never>?
  @State private var confirmDelete = false

  var body: some View {
    Form {
      Section {
        Text("采集实验 · 仅本机保存，不执行任务")
          .font(.footnote).foregroundStyle(.secondary)
      }
      if let error = model.error {
        Section("需要处理") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      }
      Section("收到的截图") { CaptureImage(store: model.store, id: id) }
      Section {
        TextEditor(
          text: Binding(
            get: { model.draft?.text ?? "" },
            set: { model.edit($0, id: id) }
          )
        )
        .frame(minHeight: 130)
        .focused($focused)
        .disabled(speech.state != .idle)
        .accessibilityLabel("这次想让小当家做什么")
        .accessibilityHint("自由描述意图；保存仅保存在本机，不会执行任务")

        Button {
          switch speech.state {
          case .idle: beginVoice()
          case .listening: voiceTask = Task { await speech.stop() }
          case .preparing, .finishing: cancelVoice()
          }
        } label: {
          Label(voiceLabel, systemImage: speech.state == .idle ? "mic" : "stop.circle")
            .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        if let error = speech.error { Text(error).font(.footnote).foregroundStyle(.red) }
      } header: {
        Text("这次想让小当家做什么？")
      } footer: {
        Text("可自由打字或说话，不预设用途。看到“正在听”后再说话；语音仅尝试设备端中文识别，不可用时请打字。文字自动暂存，录音不保存。")
      }
      Section {
        Button("保存到本机实验记录") {
          focused = false
          model.finish()
        }
        .frame(minHeight: 44)
        .disabled(
          speech.state != .idle
            || (model.draft?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
        Button("删除这条实验草稿", role: .destructive) { confirmDelete = true }
          .frame(minHeight: 44)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Button("收起键盘") { focused = false }
        Spacer()
        Button("保存实验记录") {
          focused = false
          model.finish()
        }
        .disabled(
          speech.state != .idle
            || (model.draft?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
      }
    }
    .confirmationDialog("删除这张截图和输入的文字？", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("删除草稿", role: .destructive) {
        cancelVoice()
        model.delete(id)
      }
      Button("取消", role: .cancel) {}
    }
    .onAppear { activate() }
    .onChange(of: model.autoStartID) { _, _ in activate() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { activate() }
      if phase == .background { model.autoStartID = nil }
      // Permission prompts may temporarily make the app inactive while preparing.
      if phase == .background || (phase == .inactive && speech.state == .listening) {
        cancelVoice()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) {
      _ in cancelVoice()
    }
    .onDisappear { cancelVoice() }
  }

  private var voiceLabel: String {
    switch speech.state {
    case .idle: "开始说话"
    case .preparing: "正在准备语音 · 点此取消"
    case .listening: "正在听 · 点此停止并核对"
    case .finishing: "正在收尾 · 点此取消等待"
    }
  }

  private func activate() {
    guard scenePhase == .active, model.autoStartID == id else { return }
    model.autoStartID = nil
    if model.draft?.mode == .voice { beginVoice() } else { focused = true }
  }

  private func beginVoice() {
    focused = false
    let base = model.draft?.text ?? ""
    voiceTask = Task { await speech.start(base: base) { model.edit($0, id: id) } }
  }

  private func cancelVoice() {
    voiceTask?.cancel()
    voiceTask = nil
    speech.cancel()
  }
}

private struct CaptureDetail: View {
  let record: CaptureRecord
  let model: CaptureModel
  @Environment(\.dismiss) private var dismiss
  @State private var confirmDelete = false

  var body: some View {
    List {
      Section("截图") { CaptureImage(store: model.store, id: record.id) }
      Section("当时的意图 · 未执行") { Text(record.text).textSelection(.enabled) }
      Section("接收时间") { Text(record.receivedAt, format: .dateTime.hour().minute().second()) }
      Section {
        Button("删除这条实验记录", role: .destructive) { confirmDelete = true }
        if let error = model.error { Text(error).foregroundStyle(.red) }
      }
    }
    .navigationTitle("本机实验记录")
    .confirmationDialog("删除这条实验记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("删除", role: .destructive) {
        model.delete(record.id)
        if !model.saved.contains(where: { $0.id == record.id }) { dismiss() }
      }
    }
    // A newly received screenshot must not stay hidden behind a history detail.
    .onChange(of: model.draft?.id) { _, id in if id != nil { dismiss() } }
  }
}

private struct CaptureImage: View {
  let store: CaptureStore
  let id: UUID
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
          .accessibilityLabel("本次快捷指令传来的截图，请核对是否为原 App 页面")
      } else {
        Text("截图预览暂不可用。请不要把这次实验判为成功。")
      }
    }
    .frame(maxWidth: .infinity)
    .task(id: id) { image = (try? store.image(id)).flatMap { UIImage(data: $0) } }
  }
}
