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
import ReplayKit
import UserNotifications

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
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "or_api_key")
            KeychainHelper.set(apiKey, account: "api_key")
        }
    }
    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: "or_model")
            KeychainHelper.set(model, account: "model")
        }
    }
    @Published var theme: String {
        didSet { UserDefaults.standard.set(theme, forKey: "ra_theme") }
    }
    @Published var customTone: String {
        didSet {
            UserDefaults.standard.set(customTone, forKey: "ra_custom_tone")
            syncPrefs()
        }
    }
    @Published var tone: String {
        didSet {
            UserDefaults.standard.set(tone, forKey: "ra_tone")
            syncPrefs()
        }
    }
    @Published var partner: String {
        didSet {
            UserDefaults.standard.set(partner, forKey: "ra_partner")
            syncPrefs()
        }
    }
    @Published var length: String {
        didSet {
            UserDefaults.standard.set(length, forKey: "ra_length")
            syncPrefs()
        }
    }
    @Published var draftCount: Int {
        didSet {
            UserDefaults.standard.set(draftCount, forKey: "ra_count")
            syncPrefs()
        }
    }
    @Published var autoImport: Bool {
        didSet { UserDefaults.standard.set(autoImport, forKey: "ra_auto_import") }
    }
    init() {
        let d = UserDefaults.standard
        apiKey = d.string(forKey: "or_api_key") ?? ""
        model = d.string(forKey: "or_model") ?? RAConstants.defaultModel
        theme = d.string(forKey: "ra_theme") ?? RATheme.ocean.rawValue
        customTone = d.string(forKey: "ra_custom_tone") ?? ""
        tone = d.string(forKey: "ra_tone") ?? RAConstants.tones[0]
        partner = d.string(forKey: "ra_partner") ?? RAConstants.partners[0]
        length = d.string(forKey: "ra_length") ?? RAConstants.lengths[1]
        draftCount = d.object(forKey: "ra_count") as? Int ?? 3
        autoImport = d.object(forKey: "ra_auto_import") as? Bool ?? true
        KeychainHelper.set(apiKey, account: "api_key")
        KeychainHelper.set(model, account: "model")
        syncPrefs()
    }
    var themeValue: RATheme { RATheme(rawValue: theme) ?? .ocean }
    var keyConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func syncPrefs() {
        let prefs: [String: Any] = [
            "tone": tone, "customTone": customTone, "partner": partner,
            "length": length, "count": draftCount,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: prefs),
           let str = String(data: data, encoding: .utf8) {
            KeychainHelper.set(str, account: "prefs")
        }
    }
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

// MARK: - 悬浮视频工厂（把回复文字渲染成一段循环视频，喂给系统画中画）

enum TextVideoFactory {
    static func makeVideo(text: String, theme: RATheme) async throws -> URL {
        try await makeVideo(lines: [text], theme: theme)
    }

    static func makeVideo(lines: [String], theme: RATheme) async throws -> URL {
        let size = CGSize(width: 880, height: 400)
        let uiImage = renderImage(lines: lines, theme: theme, size: size)
        guard let ciImage = CIImage(image: uiImage) else { throw AIError.empty }
        let ciContext = CIContext(options: [.cacheIntermediates: false])
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
                    if let pool = adaptor.pixelBufferPool {
                        var pbOpt: CVPixelBuffer?
                        if CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt) == kCVReturnSuccess, let pb = pbOpt {
                            ciContext.render(ciImage, to: pb)
                            adaptor.append(pb, withPresentationTime: CMTime(value: frame, timescale: 1))
                        }
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

    /// 浅色简约帧：暖白底、炭灰字、一条主题色细线，留白多
    private static func renderImage(lines: [String], theme: RATheme, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor(red: 0.975, green: 0.972, blue: 0.960, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            theme.accentUIColor.setFill()
            UIRectFill(CGRect(x: 36, y: 42, width: 54, height: 6))
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 25, weight: .medium),
                .foregroundColor: UIColor(red: 0.45, green: 0.45, blue: 0.48, alpha: 1),
            ]
            ("AI 起草 · 回话助手" as NSString).draw(at: CGPoint(x: 36, y: 62), withAttributes: titleAttrs)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 8
            if lines.count <= 1 {
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 46, weight: .semibold),
                    .foregroundColor: UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1),
                    .paragraphStyle: para,
                ]
                let rect = CGRect(x: 36, y: 112, width: size.width - 72, height: size.height - 136)
                ((lines.first ?? "") as NSString).draw(in: rect, withAttributes: bodyAttrs)
            } else {
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 31, weight: .medium),
                    .foregroundColor: UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1),
                    .paragraphStyle: para,
                ]
                let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                let rect = CGRect(x: 36, y: 108, width: size.width - 72, height: size.height - 128)
                (numbered as NSString).draw(in: rect, withAttributes: bodyAttrs)
            }
        }
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
        guard let c = AVPictureInPictureController(playerLayer: layer) else {
            statusText = "画中画初始化失败"
            return
        }
        c.delegate = self
        pip = c
    }

    func prepareAndFloat(text: String, theme: RATheme) {
        beginFloat(lines: [text], theme: theme)
    }

    func prepareAndFloatLines(_ lines: [String], theme: RATheme) {
        beginFloat(lines: lines, theme: theme)
    }

    private func beginFloat(lines: [String], theme: RATheme) {
        currentReply = lines.joined(separator: "\n")
        isPreparing = true
        statusText = "正在生成悬浮视频…"
        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                let url = try await TextVideoFactory.makeVideo(lines: lines, theme: theme)
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

// MARK: - 直播基础设施

final class DarwinWatcher: ObservableObject {
    var onSignal: (() -> Void)?
    private var started = false
    func start() {
        if started { return }
        started = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let watcher = Unmanaged<DarwinWatcher>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onSignal?() }
        }, "com.lengmo.replyassistant.newdraft" as CFString, nil, .deliverImmediately)
    }
}

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        v.preferredExtension = "com.lengmo.ReplyAssistant.ReplyBroadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {}
}

// MARK: - 起草引擎状态

final class DraftEngine: ObservableObject {
    @Published var image: UIImage? = nil
    @Published var lines: [ChatLine] = []
    @Published var transcriptDraft: String = ""
    @Published var intent: String = ""
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
            let effTone = settings.tone == "自定义" ? (settings.customTone.isEmpty ? "自然接话" : settings.customTone) : settings.tone
            candidates = try await AIClient.draft(apiKey: key, model: settings.model, transcript: convo, intent: intent, tone: effTone, partner: settings.partner, length: settings.length, count: settings.draftCount)
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
    @StateObject private var darwin = DarwinWatcher()
    @State private var inbox: DraftPayload? = nil
    @State private var extAlive = false
    @AppStorage("ra_last_draft_id") private var lastDraftID: String = ""
    @AppStorage("pb_last_cc") private var lastPasteboardCC: Int = -1
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    broadcastCard
                    materialCard
                    intentToneCard
                    draftButton
                    if !engine.errorText.isEmpty {
                        Text(engine.errorText)
                            .font(.caption).foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let payload = inbox {
                        inboxSection(payload)
                    }
                    if !engine.candidates.isEmpty {
                        stageCard
                        candidatesSection
                    }
                }
                .padding(16)
            }
            .background(LinearGradient(colors: [settings.themeValue.accent.opacity(0.13), Color(.systemGroupedBackground)], startPoint: .top, endPoint: .center).ignoresSafeArea())
            .navigationTitle("回话助手")
            .sheet(isPresented: $showPicker) {
                PhotoPicker { img in
                    Task { await engine.processImage(img) }
                }
            }
            .onAppear {
                if lastPasteboardCC == -1 { lastPasteboardCC = UIPasteboard.general.changeCount }
                darwin.onSignal = { checkInbox() }
                darwin.start()
                checkInbox()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    checkInbox()
                    autoImportIfNeeded()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var broadcastCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .foregroundColor(extAlive ? .red : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("直播助手 · 全自动").font(.subheadline.weight(.bold))
                    Text(extAlive ? "已连接：正盯着屏幕，对方发消息自动起草" : "未连接：开播后对方发消息会自动起草并通知你")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                BroadcastPickerView().frame(width: 52, height: 52)
            }
            Text("点右侧按钮选「回话助手」开始直播（或控制中心长按屏幕录制）。直播中对方发来消息，几秒后建议会推送通知，也会出现在这里下方。第一次先授权通知。")
                .font(.caption2).foregroundColor(.secondary)
            Button("授权通知（直播建议要用）") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
            .font(.caption).tint(settings.themeValue.accent)
        }
        .raCard()
    }

    private func inboxSection(_ payload: DraftPayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundColor(settings.themeValue.accent)
                Text("直播建议").font(.subheadline.weight(.bold))
                Spacer()
                Button("关闭") { inbox = nil }
                    .font(.caption).tint(.secondary)
            }
            Text("对方说：「\(payload.otherText)」")
                .font(.caption).foregroundColor(.secondary).lineLimit(2)
            ForEach(Array(payload.candidates.enumerated()), id: \.offset) { _, cand in
                HStack(spacing: 8) {
                    Text(cand).font(.subheadline)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = cand
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain).foregroundColor(.teal)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button {
                pip.prepareAndFloatLines(payload.candidates, theme: settings.themeValue)
            } label: {
                Label("三条一起悬浮", systemImage: "pip.enter")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .tint(settings.themeValue.accent)
        }
        .raCard()
    }

    private func checkInbox() {
        refreshHeartbeat()
        guard let raw = KeychainHelper.get("draft_latest"),
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DraftPayload.self, from: data) else { return }
        if payload.id != lastDraftID {
            inbox = payload
            history.add(intent: "直播 · 对方说：" + String(payload.otherText.prefix(12)), candidates: payload.candidates)
            lastDraftID = payload.id
        }
    }

    private func refreshHeartbeat() {
        if let raw = KeychainHelper.get("ext_heartbeat"), let t = Double(raw) {
            extAlive = Date().timeIntervalSince1970 - t < 150
        } else {
            extAlive = false
        }
    }

    private func autoImportIfNeeded() {
        guard settings.autoImport else { return }
        let pb = UIPasteboard.general
        let cc = pb.changeCount
        if cc == lastPasteboardCC { return }
        lastPasteboardCC = cc
        if pb.hasImages, let img = pb.image {
            Task { await engine.processImage(img) }
        }
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
                    .font(.caption2.weight(.bold)).foregroundColor(.white)
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

    private var materialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundColor(settings.themeValue.accent)
                Text("聊天截图").font(.subheadline.weight(.bold))
                Spacer()
                if engine.ocrRunning {
                    HStack(spacing: 5) {
                        ProgressView()
                        Text("本机识别中…").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if let img = engine.image {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 190)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text("在聊天里截个图，选进来或从剪贴板粘贴。本机 OCR 会自动分清「对方 / 我」，截图不上传。")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    showPicker = true
                } label: {
                    Label(engine.image == nil ? "选截图" : "换一张", systemImage: "photo")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .tint(settings.themeValue.accent)
                Button {
                    if let img = UIPasteboard.general.image {
                        Task { await engine.processImage(img) }
                    } else {
                        engine.errorText = "剪贴板里没有图片，先在聊天里截图并复制"
                    }
                } label: {
                    Label("粘贴截图", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .foregroundColor(settings.themeValue.accent)
                Text("对话记录").font(.subheadline.weight(.bold))
                Spacer()
                if !engine.lines.isEmpty {
                    Text("\(engine.lines.filter { $0.speaker != .system }.count) 条消息")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            TextEditor(text: $engine.transcriptDraft)
                .frame(height: 118)
                .padding(4)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("识别有错字可以直接改；介意的内容删掉再起草。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .raCard()
    }

    private var intentToneCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("你想表达", systemImage: "pencil.line")
                .font(.subheadline.weight(.bold))
            TextField("可留空，AI 顺着对方最后一句接话", text: $engine.intent)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(RAConstants.tones.enumerated()), id: \.offset) { i, tone in
                        Button {
                            settings.tone = tone
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: RAConstants.toneIcons[i])
                                Text(tone)
                            }
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(settings.tone == tone ? settings.themeValue.gradient : LinearGradient(colors: [Color(.secondarySystemBackground), Color(.secondarySystemBackground)], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(settings.tone == tone ? .white : .primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if settings.tone == "自定义" {
                TextField("自定义语气，如：撒娇一点 / 官方一点", text: $settings.customTone)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Text("对象").font(.caption).foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(RAConstants.partners, id: \.self) { p in
                            miniChip(p, selected: settings.partner == p) { settings.partner = p }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("长度").font(.caption).foregroundColor(.secondary)
                ForEach(RAConstants.lengths, id: \.self) { l in
                    miniChip(l, selected: settings.length == l) { settings.length = l }
                }
                Spacer()
                Text("条数").font(.caption).foregroundColor(.secondary)
                ForEach([3, 5], id: \.self) { n in
                    miniChip("\(n) 条", selected: settings.draftCount == n) { settings.draftCount = n }
                }
            }
        }
        .raCard()
    }

    private func miniChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(selected ? settings.themeValue.gradient : LinearGradient(colors: [Color(.secondarySystemBackground), Color(.secondarySystemBackground)], startPoint: .leading, endPoint: .trailing))
                .foregroundColor(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func draftAndSave() {
        Task {
            await engine.runDraft(settings: settings)
            if !engine.candidates.isEmpty && engine.candidates != lastSaved {
                history.add(intent: engine.intent, candidates: engine.candidates)
                lastSaved = engine.candidates
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private var draftButton: some View {
        Button {
            draftAndSave()
        } label: {
            HStack {
                if engine.aiRunning { ProgressView().tint(.white) }
                Image(systemName: "sparkles")
                Text(engine.aiRunning ? "AI 正在起草…" : "AI 起草候选")
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
                    .font(.subheadline.weight(.bold))
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
            HStack {
                Text("候选回复").font(.headline)
                Spacer()
                Button {
                    draftAndSave()
                } label: {
                    Label("换一批", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.bold))
                }
                .tint(settings.themeValue.accent)
                .disabled(engine.aiRunning)
            }
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
                Text(style.0).font(.caption.weight(.bold))
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
        .padding(14)
        .background(cardTint(idx))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private func cardTint(_ idx: Int) -> Color {
        let tints: [Color] = [
            Color(red: 0.925, green: 0.970, blue: 0.955),
            Color(red: 0.960, green: 0.940, blue: 0.990),
            Color(red: 0.990, green: 0.960, blue: 0.920),
            Color(red: 0.930, green: 0.950, blue: 0.990),
            Color(red: 0.990, green: 0.935, blue: 0.950),
        ]
        return tints[idx % tints.count]
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
                            .font(.caption2.weight(.bold))
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
    @EnvironmentObject var pip: PiPPlayerManager
    @EnvironmentObject var settings: RASettingsStore
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
                                        Button {
                                            pip.prepareAndFloat(text: cand, theme: settings.themeValue)
                                        } label: {
                                            Image(systemName: "pip.enter")
                                                .foregroundColor(.purple)
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
                                                .font(.caption.weight(.bold)).foregroundColor(.white)
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
                Section(header: Text("起草偏好"), footer: Text("语气选「自定义」时按上面写的来。自动导入：打开 App 时若剪贴板有新截图，自动识别（会弹系统粘贴提示，属正常）。")) {
                    TextField("自定义语气，如：撒娇一点", text: $settings.customTone)
                    Toggle("打开时自动导入剪贴板截图", isOn: $settings.autoImport)
                }
                Section(header: Text("隐私")) {
                    Text("截图识别（OCR）在本机离线完成，截图本身不会上传。只有你点「AI 起草」时，对话文字才会发给 OpenRouter。历史记录只存在本机。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("关于")) {
                    HStack { Text("版本"); Spacer(); Text("2.0.0").foregroundColor(.secondary) }
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
