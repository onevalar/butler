import SwiftUI

struct CaptureReviewEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: InventoryReviewEdit
    let save: (InventoryReviewEdit) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("这次录入") {
                    TextField("名称", text: $draft.name)
                    TextField("数量（正整数）", text: $draft.quantity).keyboardType(.numberPad)
                    TextField("单位", text: $draft.unit)
                    TextField("位置（可留空）", text: $draft.storage)
                    Text("改名只影响这一条，不会修改家里已有的产品。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("日期（可不填）") {
                    optionalDate("购买日期", date: $draft.purchasedAt)
                    optionalDate("包装有效期", date: $draft.packageExpiry)
                    optionalDate("估算到期日", date: $draft.estimatedExpiry)
                    optionalDate("计划使用日期", date: $draft.plannedUseBy)
                    Text("估算和计划日期不是包装有效期。包装有效期会在最终记下时再次确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !draft.isValid {
                    Text("请填写名称、单位和有效的正整数数量。")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("编辑这一条")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { if save(draft) { dismiss() } }
                        .disabled(!draft.isValid)
                }
            }
        }
    }

    private func optionalDate(_ title: String, date: Binding<Date?>) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(get: { date.wrappedValue != nil }, set: {
                date.wrappedValue = $0 ? (date.wrappedValue ?? Date()) : nil
            }))
            if date.wrappedValue != nil {
                DatePicker(title, selection: Binding(get: { date.wrappedValue ?? Date() },
                                                    set: { date.wrappedValue = $0 }), displayedComponents: .date)
            }
        }
    }
}
