import SwiftUI

/// 面向所有教练的常用设置；只通过现有 API 添加，不写入演示业务记录。
struct QuickSetupView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void = {}
    @State private var location = "健身房"
    @State private var pattern = 0
    @State private var busy = false
    @State private var err: String?

    private var weekdays: [Int] {
        (pattern == 1 ? QuickSetup.Days.daily : pattern == 2 ? .weekend : .weekdays).weekdays
    }

    var body: some View {
        Form {
            Section {
                Text("先用这套常用设置，之后随时可以改。已有地点、档期和体测项目会保留，只补齐空白项。")
                if let err { ErrorBar(text: err) }
            }
            Section("上课地点") {
                TextField("地点名称", text: $location)
                HStack {
                    ForEach(["健身房", "公园", "上门授课"], id: \.self) { name in
                        Button(name) { location = name }.buttonStyle(.bordered)
                    }
                }
            }
            Section {
                Picker("上课日", selection: $pattern) {
                    Text("工作日").tag(0)
                    Text("每天").tag(1)
                    Text("周末").tag(2)
                }.pickerStyle(.segmented)
                Text("09:00–18:00")
            } header: { Text("每周档期") }
            Section("体测项目") {
                Text("添加一套常用项目：立定跳远、50 米跑、平板支撑等。")
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("使用这套设置").bold() }
                        Spacer()
                    }
                }.disabled(busy || location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("设置完成后，到「学员」添加姓名和课包，就可以排课。")
            }
        }
        .disabled(busy)
        .navigationTitle("快速开始")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy)
    }

    @MainActor private func save() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            // 编排在 QuickSetup.swift（与命令行 `fitcoach setup` 共用）；每步按服务端现状补空白，
            // 部分成功后重试只补剩下的。
            _ = try await QuickSetup.run(api: API(session), location: location, weekdays: weekdays)
            onDone(); dismiss()
        } catch { err = "部分设置可能已保存，重试会继续完成。\n" + errText(error) }
    }
}
