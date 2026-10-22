// 回话助手 — 聊天截图 → 本地 OCR → AI 起草回复 → 复制 / PiP 悬浮
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
    var body: some View {
        TabView {
            DraftView()
                .tabItem { Label("起草", systemImage: "text.bubble") }
            RASettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .environmentObject(settings)
        .accentColor(.teal)
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
    init() {
        let d = UserDefaults.standard
        apiKey = d.string(forKey: "or_api_key") ?? ""
        model = d.string(forKey: "or_model") ?? RAConstants.defaultModel
    }
}

enum RAConstants {
    static let defaultModel = "minimax/minimax-m3.1-flash:free"
    static let presetModels: [String] = [
        "minimax/minimax-m3.1-flash:free",
        "recursive/flint-v1.0:free",
    ]
    static let tones: [String] = ["自然接话", "温柔体贴", "幽默风趣", "直截了当", "正式礼貌"]
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
    var topY: CGFloat    // 距图像顶部距离（0..1），已从 Vision 的左下原点坐标换算
    var bottomY: CGFloat
    var centerX: CGFloat { (minX + maxX) / 2 }
    var height: CGFloat { bottomY - topY }
}

enum OCREngine {
    /// 把图片摆正（处理相册图片的方向标记），避免 Vision 读歪
    static func upright(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func recognize(_ image: UIImage) async -> [OCRLineBox] {
        let img = upright(image)
        guard let cg = img.cgImage else { return [] }
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { request, _ in
                var boxes: [OCRLineBox] = []
                let results = request.results as? [VNRecognizedTextObservation] ?? []
                for obs in results {
                    guard let cand = obs.topCandidates(1).first else { continue }
                    let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { continue }
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
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([req])
            }
        }
    }

    /// 把 OCR 行按位置聚成一条条消息，并按气泡左右判定说话人
    static func rebuild(_ boxes: [OCRLineBox]) -> [ChatLine] {
        // 1) 砍掉状态栏/标题栏（顶部 9%）与输入栏（底部 8%）
        let body = boxes.filter { $0.topY > 0.09 && $0.bottomY < 0.92 }
        // 2) 按从上到下排序
        let sorted = body.sorted { $0.topY < $1.topY }
        // 3) 聚类：行间距小且同侧 → 同一条消息
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
        // 4) 每组判说话人并合并文本
        var lines: [ChatLine] = []
        for g in groups {
            let avgCX = g.map { $0.centerX }.reduce(0, +) / CGFloat(g.count)
            let text = g.map { $0.text }.joined(separator: "")
            if text.isEmpty { continue }
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

// MARK: - AI 起草（OpenRouter）

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
let system = "你是一个高情商的回话参谋，帮用户回复聊天消息。根据对话记录和用户想表达的意思，起草 3 条可以直接发送的回复候选。要求：三条风格有明显区别；自然口语，像真人打字聊天；长度贴合聊天场景；不要解释、不要加前后缀，只输出 3 行，每行一条，格式为「1. 内容」「2. 内容」「3. 内容」。"
let intentText = intent.isEmpty? "顺着对方最后一句自然接话": intent
let user = "\n\(transcript)\n\n\(intentText)\n\(tone)"
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
let msg = String(data: data, encoding:.utf8) ?? ""
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
}

// MARK: - PiP 悬浮（把候选回复渲染成画中画，飘在聊天 App 上方）

final class PiPFlasher: NSObject, ObservableObject {
@Published var isFloating = false
@Published var lastError: String = ""
private var pip: AVPictureInPictureController?
private let layer = AVSampleBufferDisplayLayer()
private var timer: Timer?
private var currentText: String = ""
private var frameNo: Int64 = 0

private func ensureController() -> Bool {
if pip!= nil { return true}
guard AVPictureInPictureController.isPictureInPictureSupported() else {
lastError = "这台设备不支持画中画"
return false
}
do {
try AVAudioSession.sharedInstance().setCategory(.playback, mode:.moviePlayback, options: [.mixWithOthers])
try AVAudioSession.sharedInstance().setActive(true)
} catch {
lastError = "音频会话初始化失败：\(error.localizedDescription)"
return false
}
let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
let c = AVPictureInPictureController(contentSource: source)
c.delegate = self
pip = c
return true
}

func show(text: String) {
currentText = text
lastError = ""
guard ensureController(), let pip = pip else { return}
pushFrame()
startTimer()
if !pip.isPictureInPictureActive {
pip.startPictureInPicture()
}
}

func stop() {
timer?.invalidate()
timer = nil
if let pip = pip, pip.isPictureInPictureActive {
pip.stopPictureInPicture()
}
isFloating = false
}

private func startTimer() {
timer?.invalidate()
timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
self?.pushFrame()
}
}

private func pushFrame() {
if layer.status == .failed { layer.flush()}
guard let sb = makeSampleBuffer(text: currentText) else { return}
layer.enqueue(sb)
}

private func makeSampleBuffer(text: String) -> CMSampleBuffer? {
let w = 880
let h = 400
var pb: CVPixelBuffer?
let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
let pixelBuffer = pb else { return nil}
CVPixelBufferLockBaseAddress(pixelBuffer, [])
defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, [])}
guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil}
let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
let rgbSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: rgbSpace, bitmapInfo: bitmapInfo) else { return nil}
ctx.setFillColor(UIColor(red: 0.07, green: 0.10, blue: 0.14, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
UIGraphicsPushContext(ctx)
let titleAttrs: [NSAttributedString.Key: Any] = [
.font: UIFont.boldSystemFont(ofSize: 30),
.foregroundColor: UIColor(red: 0.25, green: 0.85, blue: 0.75, alpha: 1),
]
("AI 起草" as NSString).draw(at: CGPoint(x: 36, y: 22), withAttributes: titleAttrs)
let para = NSMutableParagraphStyle()
para.lineSpacing = 10
let bodyAttrs: [NSAttributedString.Key: Any] = [
.font: UIFont.systemFont(ofSize: 44, weight:.medium),
.foregroundColor: UIColor.white,
.paragraphStyle: para,
]
let rect = CGRect(x: 36, y: 82, width: w - 72, height: h - 108)
(text as NSString).draw(in: rect, withAttributes: bodyAttrs)
UIGraphicsPopContext()
var format: CMVideoFormatDescription?
guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
let fmt = format else { return nil}
frameNo += 1
var timing = CMSampleTimingInfo(
duration: CMTime(value: 1, timescale: 30),
presentationTimeStamp: CMTime(value: frameNo, timescale: 30),
decodeTimeStamp:.invalid)
var sb: CMSampleBuffer?
guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb) == noErr,
let sample = sb else { return nil}
CMSetAttachment(sample, key: kCMSampleAttachmentKey_DisplayImmediately, value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
return sample
}
}

extension PiPFlasher: AVPictureInPictureSampleBufferPlaybackDelegate {
func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
CMTimeRange(start:.zero, duration: CMTime(value: 86400 * 30, timescale: 30))
}
func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false}
func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
completionHandler()
}
}

extension PiPFlasher: AVPictureInPictureControllerDelegate {
func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
DispatchQueue.main.async { self.isFloating = true}
}
func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
DispatchQueue.main.async {
self.isFloating = false
self.timer?.invalidate()
self.timer = nil
}
}
func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
DispatchQueue.main.async { self.lastError = "悬浮窗打开失败：\(error.localizedDescription)"}
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
                    DispatchQueue.main.async { parent.onPick(img) }
                }
            }
        }
    }
}

// MARK: - 起草页

struct DraftView: View {
    @StateObject private var engine = DraftEngine()
    @StateObject private var pip = PiPFlasher()
    @EnvironmentObject var settings: RASettingsStore
    @State private var showPicker = false
    @State private var copiedIndex: Int? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if let img = engine.image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        introCard
                    }
                    Button {
                        showPicker = true
                    } label: {
                        Label(engine.image == nil ? "选一张聊天截图" : "换一张截图", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.teal)

                    if engine.ocrRunning {
                        HStack { ProgressView(); Text("正在本机识别对话…").font(.subheadline).foregroundColor(.secondary) }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("对话记录（识别后可在这里改错字）").font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $engine.transcriptDraft)
                            .frame(height: 130)
                            .padding(6)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    TextField("你想表达什么（可留空，AI 顺着对方接话）", text: $engine.intent)
                        .textFieldStyle(.roundedBorder)

                    Picker("语气", selection: $engine.tone) {
                        ForEach(RAConstants.tones, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        Task { await engine.runDraft(settings: settings) }
                    } label: {
                        HStack {
                            if engine.aiRunning { ProgressView().tint(.white) }
                            Text(engine.aiRunning ? "AI 正在起草…" : "AI 起草 3 条候选")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(engine.aiRunning)

                    if !engine.errorText.isEmpty {
                        Text(engine.errorText).font(.caption).foregroundColor(.red)
                    }
                    if !pip.lastError.isEmpty {
                        Text(pip.lastError).font(.caption).foregroundColor(.orange)
                    }

                    if !engine.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("候选回复（点复制，回去粘贴发送）").font(.subheadline).bold()
                            ForEach(Array(engine.candidates.enumerated()), id: \.offset) { idx, cand in
                                candidateCard(idx: idx, text: cand)
                            }
                        }
                    }

                    if pip.isFloating {
                        Button(role: .destructive) {
                            pip.stop()
                        } label: {
                            Label("停止悬浮窗", systemImage: "pip.exit")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
            }
            .navigationTitle("回话助手")
            .sheet(isPresented: $showPicker) {
                PhotoPicker { img in
                    Task { await engine.processImage(img) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("怎么用").font(.headline)
            Text("1. 在聊天里截个图，回到这里选它\n2. 本机 OCR 自动分清「对方 / 我」说了啥\n3. 写下你想表达的意思（可留空），点 AI 起草\n4. 选一条复制粘贴，或用悬浮窗飘着照着打")
                .font(.subheadline).foregroundColor(.secondary)
            Text("第一次用先去「设置」页填 OpenRouter Key。")
                .font(.caption).foregroundColor(.teal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func candidateCard(idx: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.body)
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = text
                    copiedIndex = idx
                } label: {
                    Label(copiedIndex == idx ? "已复制" : "复制", systemImage: copiedIndex == idx ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button {
                    copiedIndex = nil
                    pip.show(text: text)
                } label: {
                    Label("悬浮显示", systemImage: "pip.enter")
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                Spacer()
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 设置页

struct RASettingsView: View {
    @EnvironmentObject var settings: RASettingsStore
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("OpenRouter")) {
                    SecureField("API Key（sk-or-...）", text: $settings.apiKey)
                    Text("Key 只保存在这台手机里，起草时直连 OpenRouter 官方接口。没有 Key 去 openrouter.ai 免费注册一个即可；免费模型每天有免费额度。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("模型")) {
                    Picker("常用模型", selection: $settings.model) {
                        ForEach(RAConstants.presetModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                        if !RAConstants.presetModels.contains(settings.model) {
                            Text(settings.model).tag(settings.model)
                        }
                    }
                    TextField("模型 ID（可手动改）", text: $settings.model)
                        .font(.system(.footnote, design: .monospaced))
                        .autocapitalization(.none)
                    Text("只能填带 :free 后缀的免费模型，不然会走付费额度。LengMo 的每日免费模型扫描会发新名单，看到好的填进来即可。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("隐私")) {
                    Text("截图识别（OCR）在本机离线完成，截图本身不会上传。只有你点「AI 起草」时，对话文字才会发给 OpenRouter。介意的内容可以先在对话记录框里删掉再起草。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("关于")) {
                    HStack { Text("版本"); Spacer(); Text("1.0.0").foregroundColor(.secondary) }
                    HStack { Text("开发者"); Spacer(); Text("LengMo").foregroundColor(.secondary) }
                    Text("© 2026 LengMo").font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
        }
        .navigationViewStyle(.stack)
    }
}
