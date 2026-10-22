// 回话助手 · 回话键盘（自定义键盘扩展）
// 用法：长按复制对方的消息 → 切到本键盘 → 「按剪贴板起草」→ 点候选直接填入输入框；
// 或先在输入框打下想表达的意思 → 「按输入框起草」，候选会替换输入框内容；
// 「问问 AI」拿输入框里的文字当问题，答案可整段填入。
// 需要在 系统设置 → 通用 → 键盘 里添加本键盘并打开「允许完全访问」（联网+剪贴板必需）。
// 开发者：LengMo

import UIKit
import SwiftUI

final class KBModel: ObservableObject {
    weak var controller: UIInputViewController?
    @Published var mode = 0               // 0 剪贴板起草 1 输入框起草 2 问问AI
    @Published var panel = 0              // 0 按键 1 候选 2 答案
    @Published var status = "复制对方的消息后，点下面的按钮起草"
    @Published var candidates: [String] = []
    @Published var answer = ""
    @Published var running = false
    @Published var fullAccess = false
    @Published var toneLabel = ""
    @Published var ctx: [[String: String]] = []

    func attach(_ c: UIInputViewController) {
        controller = c
        fullAccess = c.hasFullAccess
        loadCtx()
        toneLabel = toneSelection()
    }

    // MARK: 偏好（与主 App 共用钥匙串 prefs）
    private func prefs() -> [String: Any] {
        if let raw = KeychainHelper.get("prefs"),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return [:]
    }

    private func toneSelection() -> String {
        if let t = KeychainHelper.get("kb_tone"), !t.isEmpty { return t }
        return (prefs()["tone"] as? String) ?? RAConstants.tones[0]
    }

    func cycleTone() {
        let all = RAConstants.tones
        let cur = toneSelection()
        let idx = all.firstIndex(of: cur) ?? 0
        let next = all[(idx + 1) % all.count]
        KeychainHelper.set(next, account: "kb_tone")
        toneLabel = next
    }

    private func effectiveTone() -> String {
        let sel = toneSelection()
        if sel == "自定义" {
            let custom = (prefs()["customTone"] as? String) ?? ""
            return custom.isEmpty ? "自然接话" : custom
        }
        return sel
    }

    // MARK: 上下文（最近若干句，存钥匙串，键盘重启不丢）
    private func loadCtx() {
        if let raw = KeychainHelper.get("kb_context"),
           let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            ctx = arr
        }
    }

    private func saveCtx() {
        if let data = try? JSONSerialization.data(withJSONObject: ctx),
           let str = String(data: data, encoding: .utf8) {
            KeychainHelper.set(str, account: "kb_context")
        }
    }

    private func appendCtx(_ speaker: String, _ text: String) {
        let t = String(text.prefix(300))
        if let last = ctx.last, last["s"] == speaker, last["t"] == t { return }
        ctx.append(["s": speaker, "t": t])
        if ctx.count > 14 { ctx.removeFirst(ctx.count - 14) }
        saveCtx()
    }

    func clearCtx() {
        ctx = []
        saveCtx()
        status = "上下文已清空"
    }

    private func ctxTranscript() -> String {
        ctx.map { ($0["s"] == "other" ? "对方：" : "我：") + ($0["t"] ?? "") }.joined(separator: "\n")
    }

    // MARK: 输入框操作
    func inputText() -> String {
        guard let p = controller?.textDocumentProxy else { return "" }
        return ((p.documentContextBeforeInput ?? "") + (p.documentContextAfterInput ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearInputBox() {
        guard let p = controller?.textDocumentProxy else { return }
        let after = p.documentContextAfterInput ?? ""
        if !after.isEmpty { p.adjustTextPosition(byCharacterOffset: after.count) }
        var n = 0
        while let before = p.documentContextBeforeInput, !before.isEmpty, n < 300 {
            p.deleteBackward()
            n += 1
        }
    }

    func insertRaw(_ s: String) { controller?.textDocumentProxy.insertText(s) }
    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
    func advanceKeyboard() { controller?.advanceToNextInputMode() }

    // MARK: 三大动作
    func draftFromClipboard() {
        guard fullAccess else { status = "还没开「完全访问」：设置 → 通用 → 键盘 → 回话键盘 → 打开允许完全访问"; return }
        let raw = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { status = "剪贴板是空的：先在聊天里长按对方的消息 → 复制"; return }
        appendCtx("other", raw)
        runDraft(intent: "")
    }

    func draftFromInput() {
        let intent = inputText()
        if intent.isEmpty { status = "先在输入框打几个字（你想表达的意思），再点起草"; return }
        runDraft(intent: intent)
    }

    private func runDraft(intent: String) {
        let key = (KeychainHelper.get("api_key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { status = "还没填 Key：去主 App 的设置里填 OpenRouter Key"; return }
        let model = KeychainHelper.get("model") ?? RAConstants.defaultModel
        let p = prefs()
        let partner = (p["partner"] as? String) ?? RAConstants.partners[0]
        let length = (p["length"] as? String) ?? RAConstants.lengths[1]
        let count = (p["count"] as? NSNumber)?.intValue ?? 3
        let tone = effectiveTone()
        let transcript = ctxTranscript()
        running = true
        status = "AI 起草中…"
        Task {
            do {
                let cands = try await AIClient.draft(apiKey: key, model: model, transcript: transcript,
                                                     intent: intent, tone: tone, partner: partner,
                                                     length: length, count: count)
                await MainActor.run {
                    self.running = false
                    self.candidates = cands
                    self.panel = 1
                    self.status = "点一条就填进输入框"
                }
            } catch {
                await MainActor.run {
                    self.running = false
                    self.status = "起草失败：" + AIClient.describe(error)
                }
            }
        }
    }

    func askFromInput() {
        let q = inputText()
        if q.isEmpty { status = "先在输入框里打下你的问题，再点问一问"; return }
        let key = (KeychainHelper.get("api_key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { status = "还没填 Key：去主 App 的设置里填 OpenRouter Key"; return }
        let model = KeychainHelper.get("model") ?? RAConstants.defaultModel
        let transcript = ctxTranscript()
        running = true
        status = "AI 思考中…"
        Task {
            do {
                let ans = try await AIClient.ask(apiKey: key, model: model, transcript: transcript, question: q)
                await MainActor.run {
                    self.running = false
                    self.answer = ans
                    self.panel = 2
                    self.status = "答案在下面，可整段填入"
                }
            } catch {
                await MainActor.run {
                    self.running = false
                    self.status = "提问失败：" + AIClient.describe(error)
                }
            }
        }
    }

    func tapCandidate(_ cand: String) {
        if mode == 1 { clearInputBox() }
        insertRaw(cand)
        appendCtx("me", cand)
        candidates = []
        panel = 0
        status = "已填入，检查一下再发送"
    }

    func insertAnswer() {
        clearInputBox()
        insertRaw(answer)
        panel = 0
        status = "答案已填入"
    }
}

// MARK: - 界面

struct KBRootView: View {
    @ObservedObject var model: KBModel
    @State private var shifted = false
    @State private var numbers = false

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            actionRow
            if model.panel == 1 {
                candidatePanel
            } else if model.panel == 2 {
                answerPanel
            } else {
                keypad
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Button(["剪贴板", "输入框", "问问AI"][i]) { model.mode = i; model.panel = 0 }
                    .font(.caption.weight(model.mode == i ? .bold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(model.mode == i ? Color.accentColor.opacity(0.25) : Color.clear)
                    .clipShape(Capsule())
            }
            Spacer()
            Button("语气·" + (model.toneLabel.isEmpty ? "自然" : model.toneLabel)) { model.cycleTone() }
                .font(.caption)
            Button("上下文 \(model.ctx.count) · 清空") { model.clearCtx() }
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                if model.mode == 0 { model.draftFromClipboard() }
                else if model.mode == 1 { model.draftFromInput() }
                else { model.askFromInput() }
            } label: {
                HStack {
                    if model.running { ProgressView() }
                    Text(model.running ? "处理中…" : ["按剪贴板起草", "按输入框起草", "问一问 AI"][model.mode])
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.running)
            Text(model.status)
                .font(.caption2).foregroundColor(.secondary)
                .frame(width: 128, alignment: .leading)
                .lineLimit(3)
        }
    }

    private var candidatePanel: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(model.candidates.enumerated()), id: \.offset) { _, cand in
                        Button { model.tapCandidate(cand) } label: {
                            Text(cand)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("返回按键") { model.panel = 0 }
                .font(.caption)
        }
        .frame(height: 236)
    }

    private var answerPanel: some View {
        VStack(spacing: 6) {
            ScrollView {
                Text(model.answer)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Button("整段填入输入框") { model.insertAnswer() }
                    .font(.caption.weight(.bold))
                Spacer()
                Button("返回按键") { model.panel = 0 }
                    .font(.caption)
            }
        }
        .frame(height: 236)
    }

    private var keypad: some View {
        VStack(spacing: 5) {
            if numbers {
                keyRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
                keyRow(["。", "，", "？", "！", "、", "：", "；", "～", "…", "·"])
                keyRow(["(", ")", "「", "」", "—", "%", "@", "#", "&", "/"])
            } else {
                keyRow(rowKeys("qwertyuiop"))
                keyRow(rowKeys("asdfghjkl"))
                HStack(spacing: 5) {
                    keyButton(shifted ? "⇧" : "⇪", wide: 1.4) { shifted.toggle() }
                    ForEach(rowKeys("zxcvbnm"), id: \.self) { k in
                        keyButton(k, wide: 1) { typeLetter(k) }
                    }
                    keyButton("⌫", wide: 1.4) { model.deleteBackward() }
                }
            }
            HStack(spacing: 5) {
                keyButton(numbers ? "ABC" : "123", wide: 1.6) { numbers.toggle() }
                keyButton("🌐", wide: 1.2) { model.advanceKeyboard() }
                Button { model.insertRaw(" ") } label: {
                    Text("空格").font(.subheadline)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                keyButton("换行", wide: 1.6) { model.insertRaw("\n") }
            }
        }
    }

    private func rowKeys(_ s: String) -> [String] { s.map { String($0) } }

    private func keyRow(_ keys: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { k in
                keyButton(numbers ? k : (shifted ? k.uppercased() : k), wide: 1) {
                    if numbers { model.insertRaw(k) } else { typeLetter(k) }
                }
            }
        }
    }

    private func typeLetter(_ k: String) {
        model.insertRaw(shifted ? k.uppercased() : k)
        if shifted { shifted = false }
    }

    private func keyButton(_ label: String, wide: CGFloat, action: @escaping () -> Void) -> some View {
        let b = Button(action: action) {
            Text(label)
                .font(.system(size: 16))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        return Group {
            if wide > 1.2 {
                b.frame(width: 58)
            } else {
                b.frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 控制器

class KeyboardViewController: UIInputViewController {
    private let model = KBModel()
    private var hosting: UIHostingController<KBRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.attach(self)
        let hc = UIHostingController(rootView: KBRootView(model: model))
        hosting = hc
        addChild(hc)
        view.addSubview(hc.view)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hc.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 336)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.attach(self)
    }
}
