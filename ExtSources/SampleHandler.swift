// 回话助手 · 直播扩展（ReplayKit Broadcast Upload）
// 盯着屏幕画面：画面稳定后做本地 OCR，发现对方发了新消息就自动起草，
// 结果写共享钥匙串 + 达尔文通知主 App + 发本地通知。
// 开发者：LengMo

import ReplayKit
import Foundation
import UIKit
import CoreImage
import UserNotifications

class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "com.lengmo.replyassistant.broadcast")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastCheckAt: Double = 0
    private var currentHash: Int = -1
    private var hashChangedAt: Double = 0
    private var ocrHash: Int = -2
    private var lastOCRAt: Double = 0
    private var lastDraftKey: String = ""
    private var lastDraftAt: Double = 0
    private var ocrBusy = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        KeychainHelper.set(String(Date().timeIntervalSince1970), account: "ext_heartbeat")
        if (KeychainHelper.get("api_key") ?? "").isEmpty {
            notify(title: "回话直播已开始", body: "还没配置 OpenRouter Key，先去主 App 的设置里填好再开播")
        } else {
            notify(title: "回话直播已开始", body: "盯着聊天界面就行，对方发新消息我会自动起草并通知你")
        }
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}
    override func broadcastFinished() {}

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date().timeIntervalSince1970
        if now - lastCheckAt < 0.45 { return }
        lastCheckAt = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        queue.async { [weak self] in
            self?.handleFrame(pixelBuffer, now: now)
        }
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, now: Double) {
        autoreleasepool {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let hash = frameHash(ci)
            if hash != currentHash {
                currentHash = hash
                hashChangedAt = now
                return
            }
            // 画面稳定 0.7 秒以上、距上次 OCR 1.5 秒以上、内容确实变了，才做 OCR
            if now - hashChangedAt < 0.7 { return }
            if now - lastOCRAt < 1.5 { return }
            if hash == ocrHash { return }
            if ocrBusy { return }
            ocrHash = hash
            lastOCRAt = now
            ocrBusy = true
            KeychainHelper.set(String(now), account: "ext_heartbeat")
            let scale: CGFloat = 0.55
            let transformed = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = ciContext.createCGImage(transformed, from: transformed.extent) else {
                ocrBusy = false
                return
            }
            let image = UIImage(cgImage: cg)
            Task {
                let boxes = await OCREngine.recognize(image)
                let lines = OCREngine.rebuild(boxes)
                self.queue.async {
                    self.ocrBusy = false
                    self.evaluate(lines: lines, now: Date().timeIntervalSince1970)
                }
            }
        }
    }

    /// 把帧缩成小图采样求和，做廉价的画面变化指纹
    private func frameHash(_ ci: CIImage) -> Int {
        let scale: CGFloat = 0.045
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else { return -1 }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return -1 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        var i = 0
        while i < pixels.count {
            sum = (sum &+ Int(pixels[i]) &* 31) &+ i
            i += 16
        }
        return sum
    }

    private func evaluate(lines: [ChatLine], now: Double) {
        let nonSystem = lines.filter { $0.speaker != .system }
        guard let last = nonSystem.last, last.speaker == .other else { return }
        let draftKey = last.text + "|" + String(nonSystem.count)
        if draftKey == lastDraftKey { return }
        if now - lastDraftAt < 6 { return }
        lastDraftKey = draftKey
        lastDraftAt = now
        draft(lines: lines, otherText: last.text)
    }

    private func draft(lines: [ChatLine], otherText: String) {
        let key = (KeychainHelper.get("api_key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return }
        let model = KeychainHelper.get("model") ?? RAConstants.defaultModel
        var tone = RAConstants.tones[0]
        var partner = RAConstants.partners[0]
        var length = RAConstants.lengths[1]
        var count = 3
        if let raw = KeychainHelper.get("prefs"),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let rawTone = obj["tone"] as? String ?? tone
            let custom = obj["customTone"] as? String ?? ""
            tone = rawTone == "自定义" ? (custom.isEmpty ? "自然接话" : custom) : rawTone
            partner = obj["partner"] as? String ?? partner
            length = obj["length"] as? String ?? length
            count = (obj["count"] as? NSNumber)?.intValue ?? 3
        }
        let transcript = transcriptText(lines)
        Task {
            do {
                let cands = try await AIClient.draft(apiKey: key, model: model, transcript: transcript,
                                                     intent: "", tone: tone, partner: partner,
                                                     length: length, count: count)
                let payload = DraftPayload(id: UUID().uuidString,
                                           time: Date().timeIntervalSince1970,
                                           otherText: otherText,
                                           candidates: cands)
                if let data = try? JSONEncoder().encode(payload),
                   let str = String(data: data, encoding: .utf8) {
                    KeychainHelper.set(str, account: "draft_latest")
                }
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                     CFNotificationName("com.lengmo.replyassistant.newdraft" as CFString),
                                                     nil, nil, true)
                notify(title: "AI 回话建议 · 对方说「" + String(otherText.prefix(10)) + "」",
                       body: cands.first ?? "")
            } catch {
                // 起草失败静默（网络/额度问题），不打扰用户
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
