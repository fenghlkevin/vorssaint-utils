import AppKit
import SwiftUI
import ScreenCaptureKit
import Speech
import AVFoundation
import Translation

// Independent, memory-only probe. No microphone, screen output, API keys or network client.
struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let format: AVAudioFormat
    var converter: AVAudioConverter?
    var lastMeter = Date.distantPast
    var onMeter: ((Double, Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAudioTiming: ((Double, Bool) -> Void)?
    private var reportedSound = false
    var frames = 0
    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format
        self.continuation = continuation
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error.localizedDescription)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid,
              let description = sample.formatDescription else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        input.frameLength = input.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else {
            onFailure?("音频 PCM 数据转换失败"); return
        }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        if frames == 0 { onAudioTiming?(receivedAt, false) }
        frames += Int(input.frameLength)
        if Date().timeIntervalSince(lastMeter) > 0.25 {
            lastMeter = Date()
            var sum: Double = 0
            if let channel = input.floatChannelData?[0] {
                for i in 0..<Int(input.frameLength) { sum += Double(channel[i] * channel[i]) }
            }
            let rms = sqrt(sum / Double(max(1, input.frameLength)))
            if !reportedSound && rms > 0.00316 {
                reportedSound = true
                onAudioTiming?(receivedAt, true)
            }
            onMeter?(rms, frames)
        }
        if converter == nil { converter = AVAudioConverter(from: inputFormat, to: format) }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / inputFormat.sampleRate)) + 32) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { onFailure?(error?.localizedDescription ?? "重采样失败"); return }
        if output.frameLength > 0 {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                onFailure?("识别处理速度不足：音频队列溢出，已停止，避免字幕失真。")
            }
        }
    }
}

struct Caption: Identifiable {
    let id = UUID()
    var original: String
    var isFinal = false
    var translated = "等待翻译…"
    let recognizedAt = Date()
    var translationSeconds: Double?
    var waitSeconds: Double?
}

struct ProbeTranslationJob: Identifiable {
    let id = UUID()
    let captionID: UUID
    let text: String
}

@MainActor final class ProbeModel: ObservableObject {
    @Published var state = "尚未采集"
    @Published var ready = false
    @Published var running = false
    @Published var busy = false
    @Published var level = 0.0
    @Published var receivedFrames = 0
    @Published var partial = ""
    @Published var captions: [Caption] = []
    @Published var firstResult: Double?
    @Published var audioReceivedAt: Double?
    @Published var soundReceivedAt: Double?
    @Published var englishReceivedAt: Double?
    @Published var englishViewAt: Double?
    @Published var englishRevision = 0
    @Published var latestViewDelay: Double?
    private var latestEnglishAt: Double?
    private var timingOrigin = ProcessInfo.processInfo.systemUptime

    private func resetTiming() {
        timingOrigin = ProcessInfo.processInfo.systemUptime
        audioReceivedAt = nil; soundReceivedAt = nil; englishReceivedAt = nil
        englishViewAt = nil; latestEnglishAt = nil; latestViewDelay = nil
    }
    func englishViewUpdated() {
        guard let latestEnglishAt else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if englishViewAt == nil { englishViewAt = now }
        latestViewDelay = max(0, now - latestEnglishAt)
    }
    private func timestamp(_ value: Double?) -> String {
        value.map { String(format: "+%.2fs", max(0, $0 - timingOrigin)) } ?? "等待"
    }
    var timingSummary: String {
        "首包音频 \(timestamp(audioReceivedAt)) → 首条英文 \(timestamp(englishReceivedAt)) → 英文视图更新 \(timestamp(englishViewAt))"
    }
    var timingDetail: String {
        var parts: [String] = []
        if let audio = audioReceivedAt, let english = englishReceivedAt {
            parts.append(String(format: "首包→英文 %.2fs（含静音）", max(0, english - audio)))
        }
        if let sound = soundReceivedAt, let english = englishReceivedAt, english >= sound {
            parts.append(String(format: "首次有声→英文 %.2fs", english - sound))
        }
        if let english = englishReceivedAt, let view = englishViewAt {
            parts.append(String(format: "首条英文→视图 %.0fms", max(0, view - english) * 1000))
        }
        if let latestViewDelay { parts.append(String(format: "最近视图等待 %.0fms", latestViewDelay * 1000)) }
        return parts.isEmpty ? "等待真实音频与识别结果；固定英文自检不计入这些指标" : parts.joined(separator: " · ")
    }
    @Published var translationState = "正在检查英→中翻译语言包…"
    @Published var translationReady = false
    @Published var translationID: UUID?
    @Published var translationJob: ProbeTranslationJob?
    @Published var duration = 0
    private var stream: SCStream?
    private var sink: AudioSink?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var startedAt = Date()
    private var generation = UUID()
    private var translationQueue: [UUID] = []
    private var previewTask: Task<Void, Never>?
    private var segmentIDs: [Int64: [UUID]] = [:]
    private var segmentFirstSeen: [Int64: Date] = [:]
    private var pendingPreview: (key: Int64, text: String)?
    private var previewChangedAt = Date()
    private var previewEmittedAt = Date()
    private var finalizedThrough: Int64 = -1
    private var translationTimeout: Task<Void, Never>?

    private func receive(_ text: String, key: Int64, end: Int64, final: Bool) {
        // A volatile result can arrive after the same audio range was finalized.
        guard end > finalizedThrough else { return }
        if segmentFirstSeen[key] == nil { segmentFirstSeen[key] = Date(); previewEmittedAt = Date() }
        if final {
            finalizedThrough = max(finalizedThrough, end)
            if let pending = pendingPreview, pending.key < end { pendingPreview = nil }
            // Recognition can adjust its start timestamp when finalizing a phrase.
            // Remove superseded preview groups rather than leaving duplicate rows.
            for oldKey in Array(segmentIDs.keys) where oldKey != key && oldKey < end {
                let removed = Set(segmentIDs.removeValue(forKey: oldKey) ?? [])
                captions.removeAll { removed.contains($0.id) }
                translationQueue.removeAll { removed.contains($0) }
                segmentFirstSeen.removeValue(forKey: oldKey)
            }
            publish(text, key: key, final: true)
            partial = ""
        } else {
            partial = text
            if pendingPreview?.text != text || pendingPreview?.key != key {
                previewChangedAt = Date()
                pendingPreview = (key, text)
            }
        }
    }

    private func publish(_ text: String, key: Int64, final: Bool) {
        let chunks = PreviewSegments.split(text)
        var ids = segmentIDs[key] ?? []
        while ids.count > chunks.count {
            let removed = ids.removeLast()
            captions.removeAll { $0.id == removed }
            translationQueue.removeAll { $0 == removed }
        }
        for (offset, chunk) in chunks.enumerated() {
            var changed = false
            if offset >= ids.count {
                let caption = Caption(original: chunk)
                ids.append(caption.id); captions.append(caption); changed = true
            }
            guard let index = captions.firstIndex(where: { $0.id == ids[offset] }) else { continue }
            if captions[index].original != chunk {
                captions[index].original = chunk; changed = true
            }
            captions[index].isFinal = final
            if changed {
                captions[index].waitSeconds = Date().timeIntervalSince(segmentFirstSeen[key] ?? Date())
                if translationReady {
                    if !translationQueue.contains(ids[offset]) { translationQueue.append(ids[offset]) }
                } else { captions[index].translated = "未安装本地翻译语言包" }
            }
        }
        segmentIDs[key] = ids
        if final { segmentIDs.removeValue(forKey: key); segmentFirstSeen.removeValue(forKey: key) }
        if captions.count > 80 { captions.removeFirst(captions.count - 80) }
        let liveIDs = Set(captions.map(\.id))
        translationQueue.removeAll { !liveIDs.contains($0) }
        nextTranslation()
    }

    func preflight() async {
        let installed = await SpeechTranscriber.installedLocales
        ready = SpeechTranscriber.isAvailable && installed.contains { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" }
        state = ready ? "英语本地识别模型已就绪 · 不需要下载" : "缺少英语本地识别模型；未自动下载"
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        translationReady = status == .installed
        translationState = translationReady ? "Apple 英→中翻译已就绪" : "英→中翻译语言包尚未安装，本轮不会自动下载；可先验证识别"
    }

    func start() async {
        guard !running, !busy, ready else { return }
        busy = true
        defer { busy = false }
        generation = UUID()
        let token = generation
        captions = []; partial = ""; receivedFrames = 0; firstResult = nil; duration = 0
        resetTiming()
        translationQueue = []; translationID = nil
        translationJob = nil; translationTimeout?.cancel(); finalizedThrough = -1
        segmentIDs = [:]; segmentFirstSeen = [:]; pendingPreview = nil
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, self.generation == token else { return }
                guard let pending = self.pendingPreview else { continue }
                let stable = Date().timeIntervalSince(self.previewChangedAt) >= 1.0
                let overdue = Date().timeIntervalSince(self.previewEmittedAt) >= 2.0
                if stable || (overdue && pending.text.split(separator: " ").count >= 5) {
                    self.publish(pending.text, key: pending.key, final: false)
                    self.previewEmittedAt = Date()
                }
            }
        }
        state = "正在请求系统声音采集权限…"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw ProbeFailure(message: "找不到可用显示器") }
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw ProbeFailure(message: "本地识别没有可用音频格式")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(500))
            let sink = AudioSink(format: format, continuation: continuation)
            sink.onAudioTiming = { [weak self] time, audible in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if audible { self.soundReceivedAt = time }
                    else { self.audioReceivedAt = time }
                }
            }
            sink.onMeter = { [weak self] value, count in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.level = value; self.receivedFrames = count
                }
            }
            sink.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    await self.stop(reason: message)
                }
            }
            self.sink = sink
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, !Task.isCancelled, self.generation == token else { return }
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        if self.firstResult == nil { self.firstResult = Date().timeIntervalSince(self.startedAt) }
                        let key = CMTimeConvertScale(result.range.start, timescale: 1_000_000, method: .default).value
                        let end = CMTimeConvertScale(CMTimeRangeGetEnd(result.range), timescale: 1_000_000, method: .default).value
                        guard end > self.finalizedThrough else { continue }
                        let receivedAt = ProcessInfo.processInfo.systemUptime
                        if self.englishReceivedAt == nil { self.englishReceivedAt = receivedAt }
                        self.latestEnglishAt = receivedAt
                        self.receive(text, key: key, end: end, final: result.isFinal)
                        self.englishRevision += 1
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    await self.stop(reason: "识别失败：\(error.localizedDescription)")
                }
            }
            try await analyzer.start(inputSequence: inputs)
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = false
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 1
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: sink)
            try capture.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "probe.audio"))
            stream = capture
            startedAt = Date()
            try await capture.startCapture()
            running = true
            state = "正在采集系统声音 · 请播放英文视频 · 5 分钟后自动停止"
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.duration = Int(Date().timeIntervalSince(self.startedAt))
                    if self.duration >= 300 { await self.stop(reason: "5 分钟验证已结束"); return }
                }
            }
        } catch { await stop(reason: "无法开始：\(error.localizedDescription)；如已授权，请退出后重新打开验证程序。") }
    }

    func stop(reason: String = "已停止；音频没有保存") async {
        generation = UUID()
        running = false; level = 0
        timerTask?.cancel(); timerTask = nil
        previewTask?.cancel(); previewTask = nil; pendingPreview = nil
        resultTask?.cancel(); resultTask = nil
        sink?.continuation.finish()
        let oldStream = stream; stream = nil
        try? await oldStream?.stopCapture()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil; sink = nil
        translationQueue = []; translationID = nil
        translationJob = nil; translationTimeout?.cancel(); translationTimeout = nil
        for i in captions.indices where captions[i].translated == "等待翻译…" { captions[i].translated = "已停止" }
        state = reason
    }
    private func updateCaption(_ id: UUID, text: String, seconds: Double?) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        captions[index].translated = text; captions[index].translationSeconds = seconds
    }
    private func nextTranslation() {
        guard translationID == nil, !translationQueue.isEmpty else { return }
        if translationQueue.count > 8 {
            let stale = translationQueue.removeFirst()
            updateCaption(stale, text: "翻译积压，跳过旧句", seconds: nil)
            nextTranslation(); return
        }
        translationID = translationQueue.removeFirst()
        guard let caption = captions.first(where: { $0.id == translationID }) else {
            translationID = nil; nextTranslation(); return
        }
        let job = ProbeTranslationJob(captionID: caption.id, text: caption.original)
        translationJob = job
        translationTimeout?.cancel()
        translationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.translationJob?.id == job.id else { return }
            self.complete(job, result: "翻译超时，请重试", seconds: nil)
        }
    }
    func translate(_ job: ProbeTranslationJob, using session: TranslationSession) async {
        guard translationJob?.id == job.id else { return }
        let requestStart = Date()
        do {
            let result = try await session.translate(job.text)
            complete(job, result: result.targetText, seconds: Date().timeIntervalSince(requestStart))
        } catch {
            complete(job, result: "翻译失败：\(error.localizedDescription)", seconds: nil)
        }
    }
    private func complete(_ job: ProbeTranslationJob, result: String, seconds: Double?) {
        guard translationJob?.id == job.id else { return }
        translationTimeout?.cancel(); translationTimeout = nil
        if captions.first(where: { $0.id == job.captionID })?.original == job.text {
            updateCaption(job.captionID, text: result, seconds: seconds)
            translationQueue.removeAll { $0 == job.captionID }
        }
        translationJob = nil
        translationID = nil
        nextTranslation()
    }

    func testTranslation() {
        guard !running, !busy else { return }
        translationTimeout?.cancel(); translationJob = nil; translationID = nil
        captions = []; translationQueue = []; segmentIDs = [:]; segmentFirstSeen = [:]
        pendingPreview = nil; finalizedThrough = -1
        resetTiming()
        state = "固定英文自检（不采集声音）"
        receive("Don't cut yourself, princess.", key: 0, end: 1_000_000, final: false)
        publish("Don't cut yourself, princess.", key: 0, final: false)
        receive("Don't cut yourself, princess.", key: 10, end: 1_000_000, final: true)
        receive("Don't cut yourself, princess.", key: 0, end: 1_000_000, final: false)
        receive("Hello, the weather is nice today.", key: 1_100_000, end: 2_000_000, final: true)
    }
}

private struct ProbeTranslationWorker: View {
    @ObservedObject var model: ProbeModel
    let job: ProbeTranslationJob
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans")) { session in
                await model.translate(job, using: session)
            }
    }
}

struct ProbeView: View {
    @StateObject private var model = ProbeModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("系统声音 · 实时翻译验证").font(.title2.bold())
            Text("英语 → 简体中文｜本地识别 + Apple 翻译｜不采集麦克风、不保存音频").foregroundStyle(.secondary)
            Text(model.state).textSelection(.enabled)
            Text(model.translationState).font(.caption).foregroundStyle(.secondary)
            Text("低延迟预览：稳定 1 秒提前翻译，连续说话约每 2 秒更新；定稿后修正").font(.caption).foregroundStyle(.blue)
            HStack {
                Button("开始 5 分钟验证") { Task { await model.start() } }.disabled(!model.ready || model.running || model.busy)
                Button("停止") { Task { await model.stop() } }.disabled(!model.running)
                Button("固定英文自检") { model.testTranslation() }.disabled(model.running || model.busy || !model.translationReady)
                ProgressView(value: min(1, model.level * 8)).frame(width: 120)
                Text(String(format: "%.0f dB · %ds · %d 帧", 20 * log10(max(model.level, 0.000001)), model.duration, model.receivedFrames)).monospacedDigit()
            }
            Text(model.firstResult.map { String(format: "启动→首条识别：%.2fs（含播放等待，非端到端延迟）", $0) } ?? "等待首条识别结果…").font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.timingSummary).monospacedDigit()
                Text(model.timingDetail).monospacedDigit()
                Text("有声以 −50 dB 阈值抽样估计（约 250ms），音乐也会触发；视图更新时间不等于屏幕实际呈现。不是精确语音端到端延迟。")
                    .foregroundStyle(.secondary)
            }.font(.caption).textSelection(.enabled)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.captions) { caption in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(caption.original).foregroundStyle(.secondary)
                                Text(caption.translated).font(.title3)
                                Text(caption.isFinal ? "已定稿" : "预译 · 内容可能更新").font(.caption).foregroundStyle(.secondary)
                                if let wait = caption.waitSeconds {
                                    Text(String(format: "本段首条英文→提交 %.2fs", wait)).font(.caption).foregroundStyle(.secondary)
                                }
                                if let elapsed = caption.translationSeconds { Text(String(format: "翻译执行 %.2fs（不含队列等待）", elapsed)).font(.caption).foregroundStyle(.secondary) }
                            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(model.partial.isEmpty ? "等待视频中的英语语音…" : model.partial)
                            .foregroundStyle(.secondary).italic().id("live")
                    }.padding(12)
                }.background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: model.partial) { proxy.scrollTo("live", anchor: .bottom) }
            }
            Text("测试版：整个系统音源；只在内存保留最近 80 段字幕。停止会丢弃未完成的尾句。退出即清空。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 800, minHeight: 540)
            .task { await model.preflight() }
            .onChange(of: model.englishRevision) { model.englishViewUpdated() }
            .background {
                if let job = model.translationJob {
                    ProbeTranslationWorker(model: model, job: job).id(job.id)
                }
            }
            .onDisappear { Task { await model.stop() } }
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
}
@main struct LiveTranslationProbe: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("实时翻译验证 · 独立测试版") { ProbeView() }.defaultSize(width: 900, height: 620)
    }
}
