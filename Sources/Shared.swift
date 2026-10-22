// 回话助手 · 共享层（主 App 与直播扩展共用：常量、OCR、AI、钥匙串）
// 开发者：LengMo

import Foundation
import UIKit
import Vision
import Security

// MARK: - 钥匙串（App 与扩展的默认共享组，用来传 Key / 偏好 / 最新草稿）

enum KeychainHelper {
    static let service = "com.lengmo.replyassistant"
    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 直播草稿载荷

struct DraftPayload: Codable {
    var id: String
    var time: Double
    var otherText: String
    var candidates: [String]
}

enum RAConstants {
    static let defaultModel = "google/gemma-4-31b-it:free"
    static let tones: [String] = ["自然接话", "温柔体贴", "幽默风趣", "直截了当", "正式礼貌", "自定义"]
    static let toneIcons: [String] = ["text.bubble", "heart.fill", "face.smiling", "bolt.fill", "briefcase.fill", "slider.horizontal.3"]
    static let partners: [String] = ["不指定", "女朋友", "朋友", "家人", "领导", "客户"]
    static let lengths: [String] = ["短句", "适中", "详细"]
    static let candidateStyles: [(String, String)] = [
        ("暖心版", "heart.fill"),
        ("俏皮版", "face.smiling.inverse"),
        ("稳重版", "checkmark.shield.fill"),
        ("走心版", "sparkles"),
        ("精简版", "scissors"),
    ]
    /// 精选免费模型（来自 2026-10-22 免费模型扫描，聊天向）
    static let curatedFree: [String] = [
        "google/gemma-4-31b-it:free",
        "thinkingmachines/inkling:free",
        "openrouter/free",
        "recursive/flint-v1.0:free",
        "nvidia/nemotron-3-super-120b-a12b:free",
        "google/gemma-4-26b-a4b-it:free",
        "poolside/laguna-s-2.1:free",
        "xingchen-agi/xing4.0-29b-a4b:free",
    ]
    /// 精选付费模型（会消耗 OpenRouter 余额）
    static let curatedPaid: [String] = [
        "openai/gpt-4o-mini",
        "openai/gpt-4o",
        "anthropic/claude-sonnet-4",
        "google/gemini-2.5-flash",
        "google/gemini-2.5-pro",
        "deepseek/deepseek-chat",
        "deepseek/deepseek-r1",
        "x-ai/grok-4",
        "meta-llama/llama-4-maverick",
    ]
}

// MARK: - 对话数据

enum Speaker: String {
    case other = "对方"
    case me = "我"
    case system = "系统"
}

struct ChatLine: Identifiable {
    let id = UUID()
    var speaker: Speaker
    var text: String
}

func transcriptText(_ lines: [ChatLine]) -> String {
    lines.filter { $0.speaker != .system }
        .map { "\($0.speaker.rawValue)：\($0.text)" }
        .joined(separator: "\n")
}

// MARK: - OCR + 对话重建

struct OCRLineBox {
var text: String
var minX: CGFloat
var maxX: CGFloat
var topY: CGFloat // 距图像顶部距离（0..1），已从 Vision 的左下原点坐标换算
var bottomY: CGFloat
var centerX: CGFloat { (minX + maxX) / 2}
var height: CGFloat { bottomY - topY}
}

enum OCREngine {
/// 把图片摆正（处理相册图片的方向标记），避免 Vision 读歪
static func upright(_ image: UIImage) -> UIImage {
if image.imageOrientation == .up { return image}
let format = UIGraphicsImageRendererFormat()
format.scale = 1
let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
return renderer.image { _ in
image.draw(in: CGRect(origin:.zero, size: image.size))
}
}

static func recognize(_ image: UIImage) async -> [OCRLineBox] {
let img = upright(image)
guard let cg = img.cgImage else { return []}
return await withCheckedContinuation { cont in
let req = VNRecognizeTextRequest { request, _ in
var boxes: [OCRLineBox] = []
let results = request.results as? [VNRecognizedTextObservation] ?? []
for obs in results {
guard let cand = obs.topCandidates(1).first else { continue}
let text = cand.string.trimmingCharacters(in:.whitespacesAndNewlines)
if text.isEmpty { continue}
let bb = obs.boundingBox
boxes.append(OCRLineBox(
text: text,
minX: bb.minX, maxX: bb.maxX,
topY: 1 - bb.maxY, bottomY: 1 - bb.minY))
}
cont.resume(returning: boxes)
}
req.recognitionLevel = .accurate
req.recognitionLanguages = ["zh-Hans", "en-US"]
req.usesLanguageCorrection = true
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
DispatchQueue.global(qos:.userInitiated).async {
try? handler.perform([req])
}
}
}

/// 把 OCR 行按位置聚成一条条消息，并按气泡左右判定说话人
static func rebuild(_ boxes: [OCRLineBox]) -> [ChatLine] {
let body = boxes.filter { $0.topY > 0.09 && $0.bottomY < 0.92}
let sorted = body.sorted { $0.topY < $1.topY}
var groups: [[OCRLineBox]] = []
for box in sorted {
if var last = groups.last, let prev = last.last {
let gap = box.topY - prev.bottomY
let sameSide = (prev.centerX < 0.5) == (box.centerX < 0.5)
if gap < 0.020 && sameSide {
last.append(box)
groups[groups.count - 1] = last
continue
}
}
groups.append([box])
}
var lines: [ChatLine] = []
for g in groups {
let avgCX = g.map { $0.centerX}.reduce(0, +) / CGFloat(g.count)
let text = g.map { $0.text}.joined(separator: "")
if text.isEmpty { continue}
let speaker: Speaker
if avgCX < 0.46 {
speaker = .other
} else if avgCX > 0.54 {
speaker = .me
} else {
speaker = .system
}
lines.append(ChatLine(speaker: speaker, text: text))
}
return lines
}
}

// MARK: - AI（OpenRouter）

enum AIError: LocalizedError {
case http(Int, String)
case empty
var friendly: String {
switch self {
case .http(let code, _):
switch code {
case 404: return "这个模型已被 OpenRouter 下线，去「设置 → 模型」换一个；起草时会自动先拿默认模型顶一次"
case 401: return "Key 无效或已过期，去「设置」里检查 OpenRouter Key"
case 402: return "这个模型要扣费或余额不足，换一个带「免费」徽章的模型"
case 429: return "请求太频繁，或者今天的免费额度用完了，过一会儿再试"
default: return "服务出错了（\(code)），稍后再试"
}
case .empty: return "模型没返回内容，换个模型或稍后再试"
}
}
var errorDescription: String? { friendly }
}

enum AIClient {
static func describe(_ error: Error) -> String {
if let e = error as? AIError { return e.friendly }
if error is URLError { return "网络出问题了，检查一下网络再试" }
return "出错了，稍后再试"
}

static func isModelGone(_ error: Error) -> Bool {
guard let e = error as? AIError, case .http(let code, _) = e else { return false }
return code == 404
}

static func draft(apiKey: String, model: String, transcript: String, intent: String, tone: String, partner: String, length: String, count: Int) async throws -> [String] {
do {
return try await draftOnce(apiKey: apiKey, model: model, transcript: transcript, intent: intent, tone: tone, partner: partner, length: length, count: count)
} catch {
if isModelGone(error), model != RAConstants.defaultModel {
return try await draftOnce(apiKey: apiKey, model: RAConstants.defaultModel, transcript: transcript, intent: intent, tone: tone, partner: partner, length: length, count: count)
}
throw error
}
}

static func draftOnce(apiKey: String, model: String, transcript: String, intent: String, tone: String, partner: String, length: String, count: Int) async throws -> [String] {
let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
var req = URLRequest(url: url, timeoutInterval: 60)
req.httpMethod = "POST"
req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
var system = "你是一个高情商的回话参谋，帮用户回复聊天消息。根据对话记录和用户想表达的意思，起草 "
        system += String(count)
        system += " 条可以直接发送的回复候选。要求：每条风格有明显区别（依次偏暖心、俏皮、稳重、走心、精简）；自然口语，像真人打字聊天；不要解释、不要加前后缀，只输出 "
        system += String(count)
        system += " 行，每行一条，格式为「1. 内容」「2. 内容」以此类推。"
let intentText = intent.isEmpty ? "顺着对方最后一句自然接话" : intent
var user = "【对话记录】\n"
        user += transcript
        if partner != "不指定" {
            user += "\n\n【聊天对象】"
            user += partner
            user += "（注意分寸与亲疏）"
        }
        user += "\n\n【我想表达】"
        user += intentText
        user += "\n【语气基调】"
        user += tone
        user += "\n【回复长度】"
        user += lengthHint(length)
let body: [String: Any] = [
"model": model,
"messages": [
["role": "system", "content": system],
["role": "user", "content": user],
],
"temperature": 0.8,
]
req.httpBody = try JSONSerialization.data(withJSONObject: body)
let (data, resp) = try await URLSession.shared.data(for: req)
let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
guard code == 200 else {
let msg = String(data: data, encoding: .utf8) ?? ""
throw AIError.http(code, String(msg.prefix(180)))
}
guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
let choices = obj["choices"] as? [[String: Any]],
let message = choices.first?["message"] as? [String: Any],
let content = message["content"] as? String else {
throw AIError.empty
}
let cands = parseCandidates(content, count: count)
if cands.isEmpty { throw AIError.empty}
return cands
}

static func ask(apiKey: String, model: String, transcript: String, question: String) async throws -> String {
do {
return try await askOnce(apiKey: apiKey, model: model, transcript: transcript, question: question)
} catch {
if isModelGone(error), model != RAConstants.defaultModel {
return try await askOnce(apiKey: apiKey, model: RAConstants.defaultModel, transcript: transcript, question: question)
}
throw error
}
}

static func askOnce(apiKey: String, model: String, transcript: String, question: String) async throws -> String {
let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.timeoutInterval = 45
let sys = "你是中文聊天回话助手。结合对话记录回答用户的问题：简洁、直接、有用，不客套、不编号、不用标题。若用户让你润色句子，只输出润色后的那句话。"
var user = ""
if !transcript.isEmpty { user += "【对话记录】\n" + transcript + "\n\n" }
user += "【用户的问题】\n" + question
let body: [String: Any] = [
"model": model,
"messages": [
["role": "system", "content": sys],
["role": "user", "content": user],
],
"temperature": 0.6,
"max_tokens": 500,
]
req.httpBody = try JSONSerialization.data(withJSONObject: body)
let cfg = URLSessionConfiguration.ephemeral
cfg.timeoutIntervalForRequest = 45
let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
guard code == 200 else {
let msg = String(data: data, encoding: .utf8) ?? ""
throw AIError.http(code, String(msg.prefix(160)))
}
guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
let choices = obj["choices"] as? [[String: Any]],
let message = choices.first?["message"] as? [String: Any],
let content = message["content"] as? String else {
throw AIError.empty
}
return content.trimmingCharacters(in: .whitespacesAndNewlines)
}

static func lengthHint(_ length: String) -> String {
        switch length {
        case "短句": return "短句，每条尽量 15 字以内"
        case "详细": return "可以稍长，把话说完整、说贴心"
        default: return "适中，像日常聊天那样"
        }
    }

    static func parseCandidates(_ content: String, count: Int) -> [String] {
var out: [String] = []
for raw in content.split(separator: "\n") {
var s = raw.trimmingCharacters(in:.whitespaces)
if s.isEmpty { continue}
if let r = s.range(of: "^[0-9]+[.、．:：]?\\s*", options:.regularExpression) {
s.removeSubrange(r)
}
if s.hasPrefix("- ") { s = String(s.dropFirst(2))}
s = s.trimmingCharacters(in:.whitespaces)
if !s.isEmpty { out.append(s)}
}
return Array(out.prefix(count))
}

/// 测试 Key 是否可用，返回人类可读的账户摘要
static func testKey(apiKey: String) async throws -> String {
var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/key")!, timeoutInterval: 30)
req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
let (data, resp) = try await URLSession.shared.data(for: req)
let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
guard code == 200 else {
throw AIError.http(code, "Key 无效或已被撤销")
}
let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
let d = obj?["data"] as? [String: Any]
let freeTier = (d?["is_free_tier"] as? Bool) ?? false
let usage = (d?["usage"] as? NSNumber)?.doubleValue ?? 0
var text = "连接成功"
text += freeTier ? " · 免费层账号" : " · 付费层账号"
text += " · 累计用量 $\(String(format: "%.3f", usage))"
if let limit = d?["limit"] as? NSNumber {
text += " / 额度 $\(String(format: "%.2f", limit.doubleValue))"
}
return text
}
}

// MARK: - 模型库

struct ModelInfo: Identifiable {
var id: String
var name: String
var contextLength: Int
var promptPerMillion: Double
var completionPerMillion: Double
var priceKnown: Bool = true
    var isFree: Bool { promptPerMillion == 0 && completionPerMillion == 0}
var priceText: String {
if !priceKnown { return "付费" }
        if isFree { return "免费" }
return "$\(trimNum(promptPerMillion))/$\(trimNum(completionPerMillion)) 每百万词"
}
var contextText: String {
if contextLength >= 1000 {
return "\(contextLength / 1000)K 上下文"
}
return "\(contextLength) 上下文"
}
}

func trimNum(_ v: Double) -> String {
if v >= 100 { return String(format: "%.0f", v)}
if v >= 1 { return String(format: "%.1f", v)}
return String(format: "%.2f", v)
}

enum ModelCatalog {
static func fetch() async throws -> [ModelInfo] {
let url = URL(string: "https://openrouter.ai/api/v1/models")!
let (data, resp) = try await URLSession.shared.data(from: url)
let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
guard code == 200 else { throw AIError.http(code, "模型库拉取失败")}
let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
let arr = obj?["data"] as? [[String: Any]] ?? []
var out: [ModelInfo] = []
for m in arr {
guard let id = m["id"] as? String else { continue}
let pricing = m["pricing"] as? [String: Any]
let p = Double(pricing?["prompt"] as? String ?? "") ?? -1
let c = Double(pricing?["completion"] as? String ?? "") ?? -1
if p < 0 { continue}
out.append(ModelInfo(
id: id,
name: (m["name"] as? String) ?? id,
contextLength: (m["context_length"] as? NSNumber)?.intValue ?? 0,
promptPerMillion: p * 1_000_000,
completionPerMillion: max(c, 0) * 1_000_000))
}
return out
}

/// 拉取失败时的内置兜底名单
static func fallback() -> [ModelInfo] {
var out: [ModelInfo] = []
for id in RAConstants.curatedFree {
out.append(ModelInfo(id: id, name: id, contextLength: 0, promptPerMillion: 0, completionPerMillion: 0))
}
for id in RAConstants.curatedPaid {
out.append(ModelInfo(id: id, name: id, contextLength: 0, promptPerMillion: 1, completionPerMillion: 1, priceKnown: false))
}
return out
}
}

