import SwiftUI

struct PackageFormSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let studentId: Int
    let package: PackageRow?
    let onDone: () -> Void

    @State private var total = "10"
    @State private var priceYuan = ""
    @State private var purchased = Date()
    @State private var hasExpiry = false
    @State private var expires = Date()
    @State private var note = ""
    @State private var reason = ""
    @State private var reasonCode = ""
    @State private var force = false           // 课包表单不需要 force，占位给 ReasonFields
    @State private var busy = false
    @State private var err: String?
    @State private var warns: [Warn] = []

    private var isEdit: Bool { package != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                if !warns.isEmpty {
                    Section {
                        ForEach(warns) { w in
                            Text(w.message).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                Section("课包") {
                    LabeledContent("总节数") {
                        TextField("10", text: $total)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("单价（元/节）") {
                        TextField("可不填", text: $priceYuan)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    DatePicker("购买日", selection: $purchased, displayedComponents: .date)
                        .environment(\.timeZone, TZ.zone)
                    Toggle("设到期日", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("到期日", selection: $expires, displayedComponents: .date)
                            .environment(\.timeZone, TZ.zone)
                    }
                    TextField("备注（学员看不到）", text: $note, axis: .vertical).lineLimit(1...3)
                }

                if isEdit {
                    ReasonFields(reason: $reason, reasonCode: $reasonCode,
                                 required: false, showForce: false, force: $force)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text("保存").bold() }
                            Spacer() }
                    }
                    .disabled(busy || Int(total) == nil)
                } footer: {
                    Text("剩余节数是算出来的（总节数 − 已上 − 未到），不存冗余计数。把总节数改小到低于已用会得到「余额为负」的警告，但允许 —— 真实世界会退课。")
                }
            }
            .navigationTitle(isEdit ? "改课包" : "新课包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear {
                guard let p = package else { return }
                total = String(p.total_sessions)
                priceYuan = p.unit_price_cents > 0 ? Money.yuan(p.unit_price_cents) : ""
                purchased = TZ.date(fromDate: p.purchased_on)
                if let e = p.expires_on { hasExpiry = true; expires = TZ.date(fromDate: e) }
                note = p.note
            }
        }
    }

    private func submit() async {
        busy = true; err = nil; warns = []
        defer { busy = false }
        var f: [String: String] = [
            "total_sessions": total,
            "unit_price_yuan": priceYuan,
            "purchased_on": TZ.dateString(purchased),
            "expires_on": hasExpiry ? TZ.dateString(expires) : "",
            "note": note,
        ]
        do {
            if let p = package {
                f["reason"] = reason
                f["reason_code"] = reasonCode
                let r = try await API(session).post("/coach/api/packages/\(p.package_id)", f)
                onDone()
                if let w = r.warnings, !w.isEmpty { warns = w } else { dismiss() }
            } else {
                f["student_id"] = String(studentId)
                try await API(session).post("/coach/api/packages", f)
                onDone(); dismiss()
            }
        } catch {
            err = errText(error)
        }
    }
}

struct VoidSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let package: PackageRow
    let onDone: () -> Void

    @State private var reason = ""
    @State private var reasonCode = ""
    @State private var force = false
    @State private var busy = false
    @State private var err: String?
    @State private var note: String?

    private var voiding: Bool { package.voided_at == nil }

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                if let n = note {
                    Section { Text(n).font(.footnote).foregroundStyle(.orange) }
                }
                Section {
                    LabeledContent("课包", value: "\(package.total_sessions) 节 · 购于 \(package.purchased_on)")
                    LabeledContent("剩余", value: "\(package.remaining)")
                    LabeledContent("包内未上的课", value: "\(package.booked) 节")
                } footer: {
                    Text(voiding
                         ? "作废会把包内已排、还没上的课一并取消（不扣课时），学员端也会立刻看不到。"
                         : "撤销作废只恢复课包本身，被取消的课不会自动排回来。")
                }
                ReasonFields(reason: $reason, reasonCode: $reasonCode,
                             required: false, showForce: false, force: $force)
                Section {
                    Button(role: voiding ? .destructive : nil) {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text(voiding ? "作废课包" : "撤销作废").bold() }
                            Spacer() }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle(voiding ? "作废课包" : "撤销作废")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            let r = try await API(session).post("/coach/api/packages/\(package.package_id)/void", [
                "action": voiding ? "void" : "unvoid",
                "reason": reason, "reason_code": reasonCode,
            ])
            onDone()
            if let w = r.warning { note = w } else { dismiss() }
        } catch {
            err = errText(error)
        }
    }
}
