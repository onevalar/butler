import PhotosUI
import SwiftUI

struct ItemProfileEditor: View {
    let facts: LotFacts
    let onSave: (ItemProfile) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ItemProfile
    @State private var fields: [Field]
    @State private var tags: String
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var error: String?
    struct Field: Identifiable { let id = UUID(); var name: String; var value: String }

    init(facts: LotFacts, onSave: @escaping (ItemProfile) throws -> Void) {
        self.facts = facts; self.onSave = onSave
        let profile = facts.profile ?? ItemProfile(category: facts.category)
        _profile = State(initialValue: profile)
        _fields = State(initialValue: profile.attributes.sorted { $0.key < $1.key }.map { Field(name: $0.key, value: $0.value) })
        _tags = State(initialValue: profile.tags.joined(separator: "、"))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ItemPhoto(profile: profile, size: 120).frame(maxWidth: .infinity)
                    PhotosPicker(selection: $pickedPhoto, matching: .images) { Label("选择物品照片", systemImage: "photo") }
                    if loadingPhoto { Text("正在读取照片…").foregroundStyle(.secondary) }
                    if profile.photo != nil { Button("移除照片", role: .destructive) { profile.photo = nil } }
                }
                Section("分类与状态") {
                    Picker("分类", selection: $profile.category) {
                        ForEach(ItemCategory.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("状态", selection: $profile.availability) {
                        Text("可使用").tag("ready"); Text("待清洗").tag("laundry")
                        Text("已借出").tag("lent"); Text("维修中").tag("repair")
                    }
                    TextField("用途标签，用顿号分隔", text: $tags)
                }
                Section {
                    ForEach($fields) { $field in
                        HStack {
                            TextField("属性，如颜色", text: $field.name).frame(maxWidth: 130)
                            TextField("内容", text: $field.value)
                            Button(role: .destructive) { fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("移除属性")
                        }
                    }
                    Button("添加属性") { fields.append(Field(name: "", value: "")) }.disabled(fields.count >= 16)
                } header: { Text("物品资料") } footer: { Text("可以记录尺码、颜色、材质、适用季节、用途等。也可以直接告诉小当家，由它整理。") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(facts.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(loadingPhoto) }
            }
            .task(id: pickedPhoto) {
                guard let pickedPhoto else { return }
                loadingPhoto = true
                defer { loadingPhoto = false }
                do {
                    guard let data = try await pickedPhoto.loadTransferable(type: Data.self), let image = UIImage(data: data),
                          let photo = image.chatJPEG() else { throw ButlerTools.ToolError("无法读取照片") }
                    try Task.checkCancellation()
                    profile.photo = photo
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        }
    }
    private func save() {
        do {
            let filled = fields.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            guard Set(filled.map(\.name)).count == filled.count else { throw ButlerTools.ToolError("属性名称不能重复") }
            profile.attributes = Dictionary(uniqueKeysWithValues: filled.map { ($0.name, $0.value) })
            profile.tags = tags.split(whereSeparator: { "、,，".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            try profile.validate(); try onSave(profile); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ItemPhoto: View {
    let profile: ItemProfile?
    var size: CGFloat = 48
    var body: some View {
        Group {
            if let data = profile?.photo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: profile?.category.symbol ?? "shippingbox")
                    .font(.system(size: size * 0.38)).foregroundStyle(.secondary)
                    .frame(width: size, height: size).background(.quaternary.opacity(0.4))
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: min(size / 4, 20)))
            .accessibilityHidden(true)
    }
}
