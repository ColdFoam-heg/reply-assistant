// 回话助手 — 聊天截图 → 本地 OCR → AI 起草回复 → 复制 / 系统画中画悬浮
// 开发者：LengMo
// 隐私：OCR 在本机离线完成；只有点「AI 起草」时，对话文本才会发给你自己配置的 OpenRouter Key 对应的接口。

import SwiftUI
import Foundation
import UIKit
import Vision
import PhotosUI
import AVFoundation
import AVKit

// MARK: - App 入口

@main
struct ReplyAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var settings = RASettingsStore()
    @StateObject private var pip = PiPPlayerManager()
    @StateObject private var history = HistoryStore()
    var body: some View {
        TabView {
            DraftView()
                .tabItem { Label("起草", systemImage: "text.bubble.fill") }
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            RASettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .environmentObject(settings)
        .environmentObject(pip)
        .environmentObject(history)
        .accentColor(settings.themeValue.accent)
    }
}

// MARK: - 主题

enum RATheme: String, CaseIterable, Identifiable {
    case ocean, grape, peach, forest, night
    var id: String { rawValue }
    var name: String {
        switch self {
        case .ocean: return "海洋青"
        case .grape: return "葡萄紫"
        case .peach: return "蜜桃橙"
        case .forest: return "森林绿"
        case .night: return "星空夜"
        }
    }
    var colors: [Color] {
        switch self {
        case .ocean: return [Color(red: 0.04, green: 0.45, blue: 0.60), Color(red: 0.05, green: 0.70, blue: 0.75)]
        case .grape: return [Color(red: 0.38, green: 0.16, blue: 0.65), Color(red: 0.72, green: 0.30, blue: 0.85)]
        case .peach: return [Color(red: 0.88, green: 0.36, blue: 0.24), Color(red: 0.99, green: 0.66, blue: 0.35)]
        case .forest: return [Color(red: 0.07, green: 0.38, blue: 0.26), Color(red: 0.25, green: 0.68, blue: 0.46)]
        case .night: return [Color(red: 0.07, green: 0.07, blue: 0.28), Color(red: 0.38, green: 0.26, blue: 0.70)]
        }
    }
    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var accent: Color { colors[1] }
    var darkUIColor: UIColor { UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1) }
    var accentUIColor: UIColor {
        switch self {
        case .ocean: return UIColor(red: 0.30, green: 0.90, blue: 0.85, alpha: 1)
        case .grape: return UIColor(red: 0.85, green: 0.55, blue: 1.00, alpha: 1)
        case .peach: return UIColor(red: 1.00, green: 0.75, blue: 0.45, alpha: 1)
        case .forest: return UIColor(red: 0.45, green: 0.95, blue: 0.65, alpha: 1)
        case .night: return UIColor(red: 0.65, green: 0.60, blue: 1.00, alpha: 1)
        }
    }
}

// MARK: - 设置

final class RASettingsStore: ObservableObject {
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "or_api_key") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "or_model") }
    }
    @Published var theme: String {
        didSet { UserDefaults.standard.set(theme, forKey: "ra_theme") }
    }
    init() {
        let d = UserDefaults.standard
        apiKey = d.string(forKey: "or_api_key") ?? ""
        model = d.string(forKey: "or_model") ?? RAConstants.defaultModel
        theme = d.string(forKey: "ra_theme") ?? RATheme.ocean.rawValue
    }
    var themeValue: RATheme { RATheme(rawValue: theme) ?? .ocean }
    var keyConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum RAConstants {
    static let defaultModel = "minimax/minimax-m3.1-flash:free"
    static let tones: [String] = ["自然接话", "温柔体贴", "幽默风趣", "直截了当", "正式礼貌"]
    static let toneIcons: [String] = ["text.bubble", "heart.fill", "face.smiling", "bolt.fill", "briefcase.fill"]
    static let candidateStyles: [(String, String)] = [
        ("暖心版", "heart.fill"),
        ("俏皮版", "face.smiling.inverse"),
        ("稳重版", "checkmark.shield.fill"),
    ]
    /// 精选免费模型（来自 2026-10-22 免费模型扫描，聊天向）
    static let curatedFree: [String] = [
        "minimax/minimax-m3.1-flash:free",
        "recursive/flint-v1.0:free",
        "openrouter/free",
        "thinkingmachines/inkling:free",
        "google/gemma-4-31b-it:free",
        "nvidia/nemotron-3-super-120b-a12b:free",
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

// MARK: - 历史记录

struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    var time: Date
    var intent: String
    var candidates: [String]
}

final class HistoryStore: ObservableObject {
    @Published var items: [HistoryItem] = [] {
        didSet { save() }
    }
    init() {
        if let data = UserDefaults.standard.data(forKey: "ra_history"),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
    }
    func add(intent: String, candidates: [String]) {
        guard !candidates.isEmpty else { return }
        items.insert(HistoryItem(time: Date(), intent: intent, candidates: candidates), at: 0)
        if items.count > 30 { items = Array(items.prefix(30)) }
    }
    func clear() { items = [] }
    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "ra_history")
        }
    }
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
var errorDescription: String? {
switch self {
case.http(let code, let msg): return "接口返回 \(code)：\(msg)"
case.empty: return "模型没有返回内容，换个模型或稍后再试"
}
}
}

enum AIClient {
static func draft(apiKey: String, model: String, transcript: String, intent: String, tone: String) async throws -> [String] {
let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
var req = URLRequest(url: url, timeoutInterval: 60)
req.httpMethod = "POST"
req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
let system = "你是一个高情商的回话参谋，帮用户回复聊天消息。根据对话记录和用户想表达的意思，起草 3 条可以直接发送的回复候选。要求：三条风格有明显区别（依次偏暖心、偏俏皮、偏稳重）；自然口语，像真人打字聊天；长度贴合聊天场景；不要解释、不要加前后缀，只输出 3 行，每行一条，格式为「1. 内容」「2. 内容」「3. 内容」。"
let intentText = intent.isEmpty ? "顺着对方最后一句自然接话" : intent
var user = "\n"
user += transcript
user += "\n\n"
user += intentText
user += "\n"
user += tone
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
let cands = parseCandidates(content)
if cands.isEmpty { throw AIError.empty}
return cands
}

static func parseCandidates(_ content: String) -> [String] {
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
return Array(out.prefix(3))
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

// MARK: - 悬浮视频工厂（把回复文字渲染成一段循环视频，喂给系统画中画）

enum TextVideoFactory {
    static func makeVideo(text: String, theme: RATheme) async throws -> URL {
        let size = CGSize(width: 880, height: 400)
        let image = renderImage(text: text, theme: theme, size: size)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pip_reply.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 300_000],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: adaptorAttrs)
        guard writer.canAdd(input) else { throw AIError.empty }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AIError.empty }
        writer.startSession(atSourceTime: .zero)
        let totalFrames: Int64 = 300   // 1 帧/秒 × 300 秒，播放器循环，足够长
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var frame: Int64 = 0
            var finished = false
            let queue = DispatchQueue(label: "pip.video.factory")
            input.requestMediaDataWhenReady(on: queue) {
                if finished { return }
                while input.isReadyForMoreMediaData && frame < totalFrames {
                    if let pool = adaptor.pixelBufferPool,
                       let pb = makePixelBuffer(pool: pool, image: image) {
                        adaptor.append(pb, withPresentationTime: CMTime(value: frame, timescale: 1))
                    }
                    frame += 1
                }
                if frame >= totalFrames {
                    finished = true
                    input.markAsFinished()
                    writer.finishWriting {
                        if writer.status == .completed {
                            cont.resume()
                        } else {
                            cont.resume(throwing: writer.error ?? AIError.empty)
                        }
                    }
                }
            }
        }
        return url
    }

    private static func renderImage(text: String, theme: RATheme, size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { _ in
            theme.darkUIColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            theme.accentUIColor.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: 10))
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 30),
                .foregroundColor: theme.accentUIColor,
            ]
            ("AI 起草 · 回话助手" as NSString).draw(at: CGPoint(x: 36, y: 26), withAttributes: titleAttrs)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 10
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 46, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para,
            ]
            let rect = CGRect(x: 36, y: 88, width: size.width - 72, height: size.height - 112)
            (text as NSString).draw(in: rect, withAttributes: bodyAttrs)
        }
        return uiImage.cgImage ?? UIImage().cgImage!
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool, image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixelBuffer
    }
}

// MARK: - 画中画管理（系统 AVPlayer 画中画）

final class PiPPlayerManager: NSObject, ObservableObject {
    @Published var statusText: String = "点候选回复的「悬浮显示」，这里会生成画中画"
    @Published var isFloating = false
    @Published var isPreparing = false
    @Published var currentReply: String = ""
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var pip: AVPictureInPictureController?
    private weak var playerLayer: AVPlayerLayer?

    override init() {
        super.init()
        player.isMuted = true
        player.allowsExternalPlayback = false
    }

    func attachLayer(_ layer: AVPlayerLayer) {
        playerLayer = layer
        layer.player = player
        setupControllerIfNeeded()
    }

    private func setupControllerIfNeeded() {
        guard pip == nil, let layer = playerLayer else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusText = "这台设备不支持画中画"
            return
        }
        let c = AVPictureInPictureController(playerLayer: layer)
        c.delegate = self
        pip = c
    }

    func prepareAndFloat(text: String, theme: RATheme) {
        currentReply = text
        isPreparing = true
        statusText = "正在生成悬浮视频…"
        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                let url = try await TextVideoFactory.makeVideo(text: text, theme: theme)
                await MainActor.run {
                    player.pause()
                    player.removeAllItems()
                    looper = nil
                    let item = AVPlayerItem(url: url)
                    looper = AVPlayerLooper(player: player, templateItem: item)
                    player.play()
                    setupControllerIfNeeded()
                }
                var ready = false
                for _ in 0..<24 {
                    let possible = await MainActor.run { pip?.isPictureInPicturePossible ?? false }
                    if possible { ready = true; break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                await MainActor.run {
                    isPreparing = false
                    if ready, let pip = pip {
                        statusText = "正在打开悬浮窗…"
                        pip.startPictureInPicture()
                    } else {
                        statusText = "悬浮窗还没就绪，请再点一次「悬浮显示」"
                    }
                }
            } catch {
                await MainActor.run {
                    isPreparing = false
                    statusText = "生成失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func stopFloat() {
        if let pip = pip, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        player.pause()
    }
}

extension PiPPlayerManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isFloating = true
            self.statusText = "悬浮中：切到聊天 App，它会一直飘在上面照着打"
        }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isFloating = false
            self.statusText = "悬浮已关闭"
        }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.isFloating = false
            self.statusText = "打开失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 播放器舞台（画中画的宿主层 + 预览）

final class StageUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerStageView: UIViewRepresentable {
    @EnvironmentObject var pip: PiPPlayerManager
    func makeUIView(context: Context) -> StageUIView {
        let v = StageUIView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1)
        pip.attachLayer(v.playerLayer)
        return v
    }
    func updateUIView(_ v: StageUIView, context: Context) {
        if v.playerLayer.player !== pip.player {
            pip.attachLayer(v.playerLayer)
        }
    }
}

// MARK: - 起草引擎状态

final class DraftEngine: ObservableObject {
    @Published var image: UIImage? = nil
    @Published var lines: [ChatLine] = []
    @Published var transcriptDraft: String = ""
    @Published var intent: String = ""
    @Published var tone: String = RAConstants.tones[0]
    @Published var ocrRunning = false
    @Published var aiRunning = false
    @Published var candidates: [String] = []
    @Published var errorText: String = ""

    func processImage(_ img: UIImage) async {
        image = img
        ocrRunning = true
        errorText = ""
        candidates = []
        defer { ocrRunning = false }
        let boxes = await OCREngine.recognize(img)
        let rebuilt = OCREngine.rebuild(boxes)
        lines = rebuilt
        transcriptDraft = transcriptText(rebuilt)
        if rebuilt.isEmpty {
            errorText = "这张图没识别出对话，换一张更清晰的聊天截图试试"
        }
    }

    func runDraft(settings: RASettingsStore) async {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            errorText = "先去「设置」页填入你的 OpenRouter Key"
            return
        }
        let convo = transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if convo.isEmpty {
            errorText = "先选一张聊天截图识别出对话，或在对话记录里手动输入"
            return
        }
        aiRunning = true
        errorText = ""
        defer { aiRunning = false }
        do {
            candidates = try await AIClient.draft(apiKey: key, model: settings.model, transcript: convo, intent: intent, tone: tone)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 相册选择器

struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ p: PhotoPicker) { parent = p }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { obj, _ in
                if let img = obj as? UIImage {
                    DispatchQueue.main.async { self.parent.onPick(img) }
                }
            }
        }
    }
}

// MARK: - 通用卡片样式

struct RACard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

extension View {
    func raCard() -> some View { modifier(RACard()) }
}

// MARK: - 起草页

struct DraftView: View {
    @StateObject private var engine = DraftEngine()
    @EnvironmentObject var settings: RASettingsStore
    @EnvironmentObject var pip: PiPPlayerManager
    @EnvironmentObject var history: HistoryStore
    @State private var showPicker = false
    @State private var copiedIndex: Int? = nil
    @State private var lastSaved: [String] = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    screenshotCard
                    transcriptCard
                    intentToneCard
                    draftButton
                    if !engine.errorText.isEmpty {
                        Text(engine.errorText)
                            .font(.caption).foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !engine.candidates.isEmpty {
                        stageCard
                        candidatesSection
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("回话助手")
            .sheet(isPresented: $showPicker) {
                PhotoPicker { img in
                    Task { await engine.processImage(img) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 30))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 回话参谋")
                    .font(.headline).foregroundColor(.white)
                Text(settings.model)
                    .font(.caption2).foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(settings.keyConfigured ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(settings.keyConfigured ? "Key 已配置" : "未配置 Key")
                    .font(.caption2).bold().foregroundColor(.white)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.white.opacity(0.22))
            .clipShape(Capsule())
        }
        .padding(16)
        .background(settings.themeValue.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private var screenshotCard: some View {
        VStack(spacing: 10) {
            if let img = engine.image {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Label("四步搞定", systemImage: "sparkles")
                        .font(.subheadline).bold()
                    Text("1. 聊天里截个图，回这里选它\n2. 本机 OCR 自动分清「对方 / 我」\n3. 写下想表达的意思，点 AI 起草\n4. 复制粘贴，或开画中画悬浮照着打")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                showPicker = true
            } label: {
                Label(engine.image == nil ? "选一张聊天截图" : "换一张截图", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(settings.themeValue.accent)
        }
        .raCard()
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("对话记录", systemImage: "text.quote")
                    .font(.subheadline).bold()
                Spacer()
                if engine.ocrRunning {
                    HStack(spacing: 5) {
                        ProgressView()
                        Text("本机识别中…").font(.caption).foregroundColor(.secondary)
                    }
                } else if !engine.lines.isEmpty {
                    Text("\(engine.lines.filter { $0.speaker != .system }.count) 条消息")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            TextEditor(text: $engine.transcriptDraft)
                .frame(height: 118)
                .padding(4)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("识别结果有错字可以直接改；介意的内容删掉再起草。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .raCard()
    }

    private var intentToneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("你想表达", systemImage: "pencil.line")
                .font(.subheadline).bold()
            TextField("可留空，AI 顺着对方最后一句接话", text: $engine.intent)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(RAConstants.tones.enumerated()), id: \.offset) { i, tone in
                        Button {
                            engine.tone = tone
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: RAConstants.toneIcons[i])
                                Text(tone)
                            }
                            .font(.caption).bold()
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(engine.tone == tone ? settings.themeValue.gradient : LinearGradient(colors: [Color(.secondarySystemBackground), Color(.secondarySystemBackground)], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(engine.tone == tone ? .white : .primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .raCard()
    }

    private var draftButton: some View {
        Button {
            Task {
                await engine.runDraft(settings: settings)
                if !engine.candidates.isEmpty && engine.candidates != lastSaved {
                    history.add(intent: engine.intent, candidates: engine.candidates)
                    lastSaved = engine.candidates
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        } label: {
            HStack {
                if engine.aiRunning { ProgressView().tint(.white) }
                Image(systemName: "sparkles")
                Text(engine.aiRunning ? "AI 正在起草…" : "AI 起草 3 条候选")
                    .font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(settings.themeValue.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        }
        .disabled(engine.aiRunning)
    }

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("悬浮预览 · 系统画中画", systemImage: "pip.fill")
                    .font(.subheadline).bold()
                Spacer()
                if pip.isPreparing {
                    ProgressView()
                }
                if pip.isFloating {
                    Button("停止悬浮") { pip.stopFloat() }
                        .font(.caption).tint(.red)
                }
            }
            PlayerStageView()
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(pip.statusText)
                .font(.caption).foregroundColor(.secondary)
        }
        .raCard()
    }

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("候选回复").font(.headline)
            ForEach(Array(engine.candidates.enumerated()), id: \.offset) { idx, cand in
                candidateCard(idx: idx, text: cand)
            }
        }
    }

    private func candidateCard(idx: Int, text: String) -> some View {
        let style = RAConstants.candidateStyles[min(idx, RAConstants.candidateStyles.count - 1)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: style.1)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(5)
                    .background(settings.themeValue.gradient)
                    .clipShape(Circle())
                Text(style.0).font(.caption).bold()
                Spacer()
                Text("候选 \(idx + 1)").font(.caption2).foregroundColor(.secondary)
            }
            Text(text).font(.body)
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = text
                    copiedIndex = idx
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label(copiedIndex == idx ? "已复制" : "复制", systemImage: copiedIndex == idx ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button {
                    pip.prepareAndFloat(text: text, theme: settings.themeValue)
                } label: {
                    Label(pip.isPreparing && pip.currentReply == text ? "生成中" : "悬浮显示", systemImage: "pip.enter")
                }
                .buttonStyle(.bordered)
                .tint(settings.themeValue.accent)
                Spacer()
            }
            .font(.subheadline)
        }
        .raCard()
    }
}

// MARK: - 模型选择页（实时拉取 OpenRouter 模型库）

struct ModelPickerView: View {
    @EnvironmentObject var settings: RASettingsStore
    @Environment(\.dismiss) var dismiss
    @State private var models: [ModelInfo] = []
    @State private var loading = true
    @State private var loadNote: String = ""
    @State private var search: String = ""
    @State private var showPaid = false

    private var filtered: [ModelInfo] {
        if search.isEmpty { return models }
        let q = search.lowercased()
        return models.filter { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) }
    }
    private var freeList: [ModelInfo] { filtered.filter { $0.isFree } }
    private var paidList: [ModelInfo] { filtered.filter { !$0.isFree } }
    private var curatedFreeList: [ModelInfo] {
        RAConstants.curatedFree.compactMap { id in filtered.first { $0.id == id } }
    }
    private var curatedPaidList: [ModelInfo] {
        RAConstants.curatedPaid.compactMap { id in filtered.first { $0.id == id } }
    }

    var body: some View {
        List {
            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在拉取 OpenRouter 实时模型库…").font(.subheadline).foregroundColor(.secondary)
                }
            }
            if !loadNote.isEmpty {
                Text(loadNote).font(.caption).foregroundColor(.orange)
            }
            if search.isEmpty && !curatedFreeList.isEmpty {
                Section("精选免费 · 优先推荐") {
                    ForEach(curatedFreeList) { modelRow($0) }
                }
            }
            Section("全部免费模型（\(freeList.count) 个）") {
                ForEach(freeList) { modelRow($0) }
            }
            if search.isEmpty && !curatedPaidList.isEmpty {
                Section("精选付费 · 消耗余额") {
                    ForEach(curatedPaidList) { modelRow($0) }
                }
            }
            Section {
                Toggle("展开全部付费模型（\(paidList.count) 个）", isOn: $showPaid)
            }
            if showPaid || !search.isEmpty {
                Section("全部付费模型") {
                    ForEach(paidList) { modelRow($0) }
                }
            }
            Section(header: Text("自定义模型 ID"), footer: Text("带 :free 后缀的才是免费模型，填错会走付费额度。")) {
                TextField("模型 ID", text: $settings.model)
                    .font(.system(.footnote, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
        .navigationTitle("选择模型")
        .searchable(text: $search, prompt: "搜索模型名")
        .task { await load() }
    }

    private func modelRow(_ m: ModelInfo) -> some View {
        Button {
            settings.model = m.id
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.name)
                        .font(.subheadline).foregroundColor(.primary).lineLimit(1)
                    Text(m.id)
                        .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(m.isFree ? "免费" : m.priceText)
                            .font(.caption2).bold()
                            .foregroundColor(m.isFree ? .green : .orange)
                        if m.contextLength > 0 {
                            Text(m.contextText).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                if settings.model == m.id {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                }
            }
        }
    }

    private func load() async {
        do {
            models = try await ModelCatalog.fetch()
        } catch {
            models = ModelCatalog.fallback()
            loadNote = "实时模型库拉取失败，已切换到内置精选名单"
        }
        loading = false
    }
}

// MARK: - 历史页

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var copiedKey: String = ""
    var body: some View {
        NavigationView {
            Group {
                if history.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 44)).foregroundColor(.secondary)
                        Text("还没有起草记录").font(.headline)
                        Text("在「起草」页成功生成候选后，会自动存到这里，随时回来复制。")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(history.items) { item in
                            Section(header: Text(headerText(item))) {
                                ForEach(Array(item.candidates.enumerated()), id: \.offset) { _, cand in
                                    HStack(spacing: 8) {
                                        Text(cand).font(.subheadline)
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = cand
                                            copiedKey = item.id.uuidString + cand
                                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        } label: {
                                            Image(systemName: copiedKey == item.id.uuidString + cand ? "checkmark" : "doc.on.doc")
                                                .foregroundColor(.teal)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史记录")
            .toolbar {
                if !history.items.isEmpty {
                    Button("清空") { history.clear() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func headerText(_ item: HistoryItem) -> String {
        var s = item.time.formatted(date: .abbreviated, time: .shortened)
        if !item.intent.isEmpty {
            s += " · 想表达：\(item.intent)"
        }
        return s
    }
}

// MARK: - 设置页

struct RASettingsView: View {
    @EnvironmentObject var settings: RASettingsStore
    @State private var testing = false
    @State private var testResult: String = ""
    @State private var testOK: Bool? = nil
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("OpenRouter 连接")) {
                    SecureField("API Key（sk-or-...）", text: $settings.apiKey)
                    HStack {
                        if settings.keyConfigured {
                            Label("已配置", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green).font(.subheadline)
                        } else {
                            Label("未配置", systemImage: "exclamationmark.circle.fill")
                                .foregroundColor(.orange).font(.subheadline)
                        }
                        Spacer()
                        if testing {
                            ProgressView()
                        } else {
                            Button("测试连接") { runTest() }
                                .font(.subheadline)
                                .disabled(!settings.keyConfigured)
                        }
                    }
                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.caption)
                            .foregroundColor(testOK == true ? .green : .red)
                    }
                    Text("Key 只保存在这台手机里，起草时直连 OpenRouter 官方接口。没有 Key 去 openrouter.ai 免费注册一个即可。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("模型"), footer: Text("优先选带「免费」徽章的；付费模型会消耗你的 OpenRouter 余额。")) {
                    NavigationLink {
                        ModelPickerView()
                    } label: {
                        HStack {
                            Text("当前模型")
                            Spacer()
                            Text(settings.model)
                                .foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .trailing)
                        }
                    }
                }
                Section(header: Text("主题")) {
                    HStack(spacing: 16) {
                        ForEach(RATheme.allCases) { t in
                            Button {
                                settings.theme = t.rawValue
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack {
                                        Circle()
                                            .fill(t.gradient)
                                            .frame(width: 42, height: 42)
                                        if settings.themeValue == t {
                                            Image(systemName: "checkmark")
                                                .font(.caption).bold().foregroundColor(.white)
                                        }
                                    }
                                    Text(t.name).font(.caption2).foregroundColor(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                Section(header: Text("隐私")) {
                    Text("截图识别（OCR）在本机离线完成，截图本身不会上传。只有你点「AI 起草」时，对话文字才会发给 OpenRouter。历史记录只存在本机。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("关于")) {
                    HStack { Text("版本"); Spacer(); Text("1.1.0").foregroundColor(.secondary) }
                    HStack { Text("开发者"); Spacer(); Text("LengMo").foregroundColor(.secondary) }
                    Text("© 2026 LengMo").font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
        }
        .navigationViewStyle(.stack)
    }

    private func runTest() {
        testing = true
        testResult = ""
        testOK = nil
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                testResult = try await AIClient.testKey(apiKey: key)
                testOK = true
            } catch {
                testResult = error.localizedDescription
                testOK = false
            }
            testing = false
        }
    }
}
