// 回话助手 · 直播扩展 v3（ReplayKit Broadcast Upload）
// 设计要点（据真机踩坑与公开复盘修正）：
// - 只处理最新帧（容量 1 的槽位），绝不阻塞 ReplayKit 的投递队列
// - 聊天区小图识别（内存压在广播扩展上限内），网格指纹抗光标/时钟闪烁
// - 全程写诊断面包屑（ext_status），主 App 可直接看到卡在哪一步
// - 通知走「存钥匙串 + 达尔文信号 → 主 App 中继」，扩展直发仅作 best-effort
// 开发者：LengMo

import ReplayKit
import Foundation
import UIKit
import CoreImage
import CoreMedia
import UserNotifications

class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "com.lengmo.replyassistant.broadcast")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pending: (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation?)?
    private var checkScheduled = false
    private var lastCheckAt: Double = 0
    private var prevSig: [UInt8] = []
    private var stableCount = 0
    private var ocrSig: [UInt8] = []
    private var lastOCRAt: Double = 0
    private var ocrBusy = false
    private var lastDraftKey: String = ""
    private var lastDraftAt: Double = 0
    private var status: [String: Any] = [:]

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.async {
            self.status = ["startedAt": Date().timeIntervalSince1970, "frames": 0, "ocrRuns": 0, "drafts": 0, "lastErr": ""]
            self.writeStatus()
        }
        KeychainHelper.set(String(Date().timeIntervalSince1970), account: "ext_heartbeat")
        notify(identifier: "broadcast-start", title: "回话直播已开始",
               body: "盯着聊天界面就行，对方发新消息会自动起草", category: nil)
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        queue.async {
            self.status["stoppedAt"] = Date().timeIntervalSince1970
            self.writeStatus()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var orientation: CGImagePropertyOrientation? = nil
        if let num = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            orientation = CGImagePropertyOrientation(rawValue: num.uint32Value)
        }
        queue.async {
            self.pending = (pixelBuffer, orientation)
            if !self.checkScheduled {
                self.checkScheduled = true
                self.runCheck()
            }
        }
    }

    private func runCheck() {
        let now = Date().timeIntervalSince1970
        if now - lastCheckAt < 0.5 {
            queue.asyncAfter(deadline: .now() + 0.3) { self.runCheck() }
            return
        }
        checkScheduled = false
        guard let frame = pending else { return }
        pending = nil
        lastCheckAt = now
        autoreleasepool { handleFrame(frame.buffer, orientation: frame.orientation, now: now) }
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation?, now: Double) {
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        if let o = orientation { ci = ci.oriented(o) }
        let ext = ci.extent
        if ext.width < 50 || ext.height < 50 { return }
        // 聊天消息区（UIKit 坐标 y 0.07–0.67）→ CI 坐标（y 轴向上）取 0.33H 起、高 0.60H
        let roiRect = CGRect(x: ext.minX, y: ext.minY + ext.height * 0.33, width: ext.width, height: ext.height * 0.60)
        let roi = ci.cropped(to: roiRect)
        status["frames"] = (status["frames"] as? Int ?? 0) + 1
        status["lastFrameAt"] = now
        let sig = signature(of: roi)
        if sig.isEmpty { return }
        if prevSig.count == sig.count {
            let d = sigDiff(prevSig, sig)
            if d <= 3 { stableCount += 1 } else { stableCount = 0 }
        } else {
            stableCount = 0
        }
        prevSig = sig
        if stableCount < 1 { return }
        if ocrBusy { return }
        if now - lastOCRAt < 2.0 { return }
        if ocrSig.count == sig.count && sigDiff(ocrSig, sig) < 8 { return }
        ocrSig = sig
        lastOCRAt = now
        ocrBusy = true
        KeychainHelper.set(String(now), account: "ext_heartbeat")
        let targetW: CGFloat = 800
        let scale = targetW / roi.extent.width
        let small = roi.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else {
            ocrBusy = false
            return
        }
        let image = UIImage(cgImage: cg)
        Task {
            let boxes = await OCREngine.recognize(image)
            let lines = OCREngine.rebuild(boxes)
            self.queue.async {
                self.ocrBusy = false
                self.status["ocrRuns"] = (self.status["ocrRuns"] as? Int ?? 0) + 1
                self.status["lastOcrAt"] = Date().timeIntervalSince1970
                self.status["lastLines"] = lines.count
                self.writeStatus()
                self.evaluate(lines: lines, now: Date().timeIntervalSince1970)
            }
        }
    }

    /// 网格指纹：把区域缩成小图，按 10×20 格取平均灰度。光标闪烁只动 1–2 格，新消息会动一整排
    private func signature(of ci: CIImage) -> [UInt8] {
        let targetW: CGFloat = 100
        let scale = targetW / ci.extent.width
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else { return [] }
        let w = cg.width
        let h = cg.height
        guard w >= 10, h >= 20 else { return [] }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cols = 10
        let rows = 20
        var sig = [UInt8](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = c * w / cols
                let x1 = max(x0 + 1, (c + 1) * w / cols)
                let y0 = r * h / rows
                let y1 = max(y0 + 1, (r + 1) * h / rows)
                var sum = 0
                var n = 0
                var y = y0
                while y < y1 {
                    var x = x0
                    while x < x1 {
                        let i = (y * w + x) * 4
                        sum += (Int(pixels[i]) + 2 * Int(pixels[i + 1]) + Int(pixels[i + 2])) / 4
                        n += 1
                        x += 2
                    }
                    y += 2
                }
                sig[r * cols + c] = UInt8(clamping: n > 0 ? sum / n : 0)
            }
        }
        return sig
    }

    private func sigDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var d = 0
        for i in 0..<min(a.count, b.count) {
            if abs(Int(a[i]) - Int(b[i])) > 20 { d += 1 }
        }
        return d
    }

    private func evaluate(lines: [ChatLine], now: Double) {
        let nonSystem = lines.filter { $0.speaker != .system }
        // 不像聊天界面（左右气泡太少）就不动作
        if nonSystem.count < 2 { return }
        guard let last = nonSystem.last, last.speaker == .other else { return }
        status["lastOther"] = String(last.text.prefix(20))
        let draftKey = last.text + "|" + String(nonSystem.count)
        if draftKey == lastDraftKey { return }
        if now - lastDraftAt < 6 { return }
        lastDraftKey = draftKey
        lastDraftAt = now
        draft(lines: lines, otherText: last.text)
    }

    private func draft(lines: [ChatLine], otherText: String) {
        let key = (KeychainHelper.get("api_key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            status["lastErr"] = "没有读到 Key"
            writeStatus()
            return
        }
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
                self.queue.async {
                    self.status["drafts"] = (self.status["drafts"] as? Int ?? 0) + 1
                    self.status["lastDraftAt"] = Date().timeIntervalSince1970
                    self.status["lastErr"] = ""
                    self.writeStatus()
                }
                notify(identifier: payload.id,
                       title: "AI 回话建议 · 对方说「" + String(otherText.prefix(10)) + "」",
                       body: cands.first ?? "", category: "DRAFT_CAT")
            } catch {
                self.queue.async {
                    self.status["lastErr"] = String(describing: error).prefix(60).description
                    self.writeStatus()
                }
            }
        }
    }

    private func writeStatus() {
        status["updatedAt"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: status),
           let str = String(data: data, encoding: .utf8) {
            KeychainHelper.set(str, account: "ext_status")
        }
    }

    private func notify(identifier: String, title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = category { content.categoryIdentifier = category }
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
