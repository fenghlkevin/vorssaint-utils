import AppKit
import SwiftUI
import ScreenCaptureKit
import Speech
import AVFoundation
import Translation

// Audio stays local. Only finalized text goes to explicitly selected cloud providers.
@available(macOS 26.0, *)
struct LiveSubtitleFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@available(macOS 26.0, *)
final class LiveSubtitleAudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
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

@available(macOS 26.0, *)
struct LiveSubtitleCaption: Identifiable {
    let id = UUID()
    var original: String
    var isFinal = false
    var translated = "等待翻译…"
    let recognizedAt = Date()
    var translationSeconds: Double?
    var waitSeconds: Double?
}

@available(macOS 26.0, *)
struct LiveSubtitleTranslationJob: Identifiable {
    let id = UUID()
    let captionID: UUID
    let text: String
}

@available(macOS 26.0, *)
@MainActor final class LiveSubtitleModel: ObservableObject {
    @Published var provider = UserDefaults.standard.string(forKey: "translation.live.provider") ?? "system" {
        didSet { UserDefaults.standard.set(provider, forKey: "translation.live.provider"); cloudConsent = false }
    }
    @Published var sourceLanguage = LiveSubtitleLanguage(rawValue: UserDefaults.standard.string(forKey: "translation.live.language") ?? "") ?? .english {
        didSet { ready = false; UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translation.live.language") }
    }
    @Published var cloudConsent = false
    private var remoteTask: Task<Void, Never>?
    private var remoteRunner: TranslationProcess?
    @Published var state = "尚未采集"
    @Published var ready = false
    @Published var running = false
    @Published var busy = false
    @Published var level = 0.0
    @Published var receivedFrames = 0
    @Published var partial = ""
    @Published var captions: [LiveSubtitleCaption] = []
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
        "首包音频 \(timestamp(audioReceivedAt)) → 首条原文 \(timestamp(englishReceivedAt)) → 原文视图更新 \(timestamp(englishViewAt))"
    }
    var timingDetail: String {
        var parts: [String] = []
        if let audio = audioReceivedAt, let english = englishReceivedAt {
            parts.append(String(format: "首包→原文 %.2fs（含静音）", max(0, english - audio)))
        }
        if let sound = soundReceivedAt, let english = englishReceivedAt, english >= sound {
            parts.append(String(format: "首次有声→原文 %.2fs", english - sound))
        }
        if let english = englishReceivedAt, let view = englishViewAt {
            parts.append(String(format: "首条原文→视图 %.0fms", max(0, view - english) * 1000))
        }
        if let latestViewDelay { parts.append(String(format: "最近视图等待 %.0fms", latestViewDelay * 1000)) }
        return parts.isEmpty ? "等待真实音频与识别结果；固定原文自检不计入这些指标" : parts.joined(separator: " · ")
    }
    @Published var translationState = "正在检查英→中翻译语言包…"
    @Published var translationReady = false
    @Published var translationID: UUID?
    @Published var translationJob: LiveSubtitleTranslationJob?
    @Published var duration = 0
    private var stream: SCStream?
    private var sink: LiveSubtitleAudioSink?
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
    private var latestRecognitionEnd: Int64 = -1
    private var clearedThrough: Int64 = -1
    private var translationTimeout: Task<Void, Never>?

    private func receive(_ text: String, key: Int64, end: Int64, final: Bool) {
        // A volatile result can arrive after the same audio range was finalized.
        guard end > finalizedThrough,
              LiveSubtitlePolicy.acceptAfterClear(start: key, end: end, boundary: clearedThrough) else { return }
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
        let chunks = LiveSubtitleSegments.split(text, language: sourceLanguage)
        var ids = segmentIDs[key] ?? []
        while ids.count > chunks.count {
            let removed = ids.removeLast()
            captions.removeAll { $0.id == removed }
            translationQueue.removeAll { $0 == removed }
        }
        for (offset, chunk) in chunks.enumerated() {
            var changed = false
            if offset >= ids.count {
                let caption = LiveSubtitleCaption(original: chunk)
                ids.append(caption.id); captions.append(caption); changed = true
            }
            guard let index = captions.firstIndex(where: { $0.id == ids[offset] }) else { continue }
            if captions[index].original != chunk {
                captions[index].original = chunk; changed = true
            }
            captions[index].isFinal = final
            if changed || (final && captions[index].translated == "等待语音定稿…") {
                captions[index].waitSeconds = Date().timeIntervalSince(segmentFirstSeen[key] ?? Date())
                if translationReady && LiveSubtitlePolicy.shouldTranslate(provider: provider, final: final) {
                    if !translationQueue.contains(ids[offset]) { translationQueue.append(ids[offset]) }
                } else { captions[index].translated = provider == "system" ? "未安装本地翻译语言包" : "等待语音定稿…" }
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
        let language = sourceLanguage
        let service = provider
        ready = false
        let installed = await SpeechTranscriber.installedLocales
        guard language == sourceLanguage, service == provider else { return }
        ready = SpeechTranscriber.isAvailable && installed.contains { $0.identifier.replacingOccurrences(of: "_", with: "-") == language.rawValue }
        state = ready ? "\(language.title)本地识别模型已就绪 · 不需要下载" : "缺少\(language.title)本地识别模型；未自动下载"
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: language.translationCode), to: Locale.Language(identifier: "zh-Hans"))
        guard language == sourceLanguage, service == provider else { return }
        translationReady = provider != "system" || status == .installed
        translationState = provider != "system" ? "使用翻译设置中的 API / Codex 配置；仅定稿后请求" : translationReady ? "Apple \(language.title)→中文翻译已就绪" : "\(language.title)→中文翻译语言包尚未安装，本轮不会自动下载；可先验证识别"
    }

    func start() async {
        guard AppFeature.liveSubtitles.isAvailable, !running, !busy, ready,
              LiveSubtitlePolicy.mayStart(provider: provider, consent: cloudConsent) else { return }
        busy = true
        defer { busy = false }
        generation = UUID()
        let token = generation
        captions = []; partial = ""; receivedFrames = 0; firstResult = nil; duration = 0
        resetTiming()
        translationQueue = []; translationID = nil
        translationJob = nil; translationTimeout?.cancel(); finalizedThrough = -1
        latestRecognitionEnd = -1; clearedThrough = -1
        segmentIDs = [:]; segmentFirstSeen = [:]; pendingPreview = nil
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, self.generation == token else { return }
                guard let pending = self.pendingPreview else { continue }
                let stable = Date().timeIntervalSince(self.previewChangedAt) >= 1.0
                let overdue = Date().timeIntervalSince(self.previewEmittedAt) >= 2.0
                if stable || (overdue && (self.sourceLanguage == .japanese ? pending.text.count >= 8 : pending.text.split(separator: " ").count >= 5)) {
                    if self.provider == "system" { self.publish(pending.text, key: pending.key, final: false) }
                    self.previewEmittedAt = Date()
                }
            }
        }
        state = "正在请求系统声音采集权限…"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard generation == token else { return }
            guard let display = content.displays.first else { throw LiveSubtitleFailure(message: "找不到可用显示器") }
            let transcriber = SpeechTranscriber(locale: Locale(identifier: sourceLanguage.rawValue), preset: .progressiveTranscription)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw LiveSubtitleFailure(message: "本地识别没有可用音频格式")
            }
            guard generation == token else { return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            guard generation == token else { await analyzer.cancelAndFinishNow(); return }
            let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(500))
            let sink = LiveSubtitleAudioSink(format: format, continuation: continuation)
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
                        self.latestRecognitionEnd = max(self.latestRecognitionEnd, end)
                        guard end > self.finalizedThrough,
                              LiveSubtitlePolicy.acceptAfterClear(start: key, end: end, boundary: self.clearedThrough) else { continue }
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
            guard generation == token else { await analyzer.cancelAndFinishNow(); return }
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
            guard generation == token else { try? await capture.stopCapture(); return }
            running = true
            state = "正在采集系统声音 · 原文→简体中文 · 关闭窗口即停止"
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.duration = Int(Date().timeIntervalSince(self.startedAt))

                }
            }
        } catch { await stop(reason: "无法开始：\(error.localizedDescription)；如已授权，请退出后重新打开验证程序。") }
    }

    func clearCaptions() {
        // Keep the capture/analyzer session alive, but invalidate all old translation work.
        clearedThrough = max(clearedThrough, latestRecognitionEnd)
        translationJob = nil; translationID = nil
        translationTimeout?.cancel(); translationTimeout = nil
        remoteTask?.cancel(); remoteTask = nil
        remoteRunner?.cancel(); remoteRunner = nil
        translationQueue.removeAll()
        captions.removeAll(); partial = ""
        pendingPreview = nil
        segmentIDs.removeAll(); segmentFirstSeen.removeAll()
    }

    func stop(reason: String = "已停止；音频没有保存") async {
        busy = true
        defer { busy = false }
        generation = UUID()
        remoteTask?.cancel(); remoteTask = nil
        remoteRunner?.cancel(); remoteRunner = nil
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
        for i in captions.indices where ["等待翻译…", "等待语音定稿…"].contains(captions[i].translated) { captions[i].translated = "已停止" }
        state = reason
    }
    private func updateCaption(_ id: UUID, text: String, seconds: Double?) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        captions[index].translated = text; captions[index].translationSeconds = seconds
    }
    private func nextTranslation() {
        guard translationID == nil, !translationQueue.isEmpty else { return }
        if translationQueue.count > LiveSubtitlePolicy.queueLimit(provider: provider) {
            let stale = translationQueue.removeFirst()
            updateCaption(stale, text: "翻译积压，跳过旧句", seconds: nil)
            nextTranslation(); return
        }
        translationID = translationQueue.removeFirst()
        guard let caption = captions.first(where: { $0.id == translationID }) else {
            translationID = nil; nextTranslation(); return
        }
        let job = LiveSubtitleTranslationJob(captionID: caption.id, text: caption.original)
        translationJob = job
        translationTimeout?.cancel()
        translationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.provider == "codex" ? 125 : 30))
            guard !Task.isCancelled, let self, self.translationJob?.id == job.id else { return }
            self.remoteTask?.cancel(); self.remoteRunner?.cancel()
            self.complete(job, result: "翻译超时，请重试", seconds: nil)
        }
        if provider != "system" { startRemote(job) }
    }
    private func startRemote(_ job: LiveSubtitleTranslationJob) {
        let selected = provider
        let source = sourceLanguage.translationCode
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: CodexTranslation.pathKey) ?? ""
        let model = defaults.string(forKey: CodexTranslation.modelKey) ?? ""
        let effort = defaults.string(forKey: CodexTranslation.effortKey) ?? ""
        let speed = defaults.string(forKey: CodexTranslation.speedKey) ?? ""
        let runner = TranslationProcess()
        remoteRunner = runner
        remoteTask = Task { [weak self] in
            let start = Date()
            do {
                let result: String
                if selected == "codex" {
                    result = try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            DispatchQueue.global(qos: .userInitiated).async {
                                continuation.resume(with: Result {
                                    try CodexTranslation.run(runner: runner, path: path, model: model,
                                        text: job.text, source: source, target: "zh-Hans", effort: effort, speed: speed)
                                })
                            }
                        }
                    } onCancel: { runner.cancel() }
                } else {
                    guard let id = TranslationProviderSelection.aiID(selected) else { throw LiveSubtitleFailure(message: "翻译服务不可用") }
                    let profile = try AITranslationProfiles.profile(id: id)
                    let request = try AITranslation.request(endpoint: profile.endpoint, model: profile.model,
                        key: profile.key, text: job.text, source: source, target: "zh-Hans")
                    result = try await AITranslation.send(request)
                }
                guard !Task.isCancelled else { return }
                self?.complete(job, result: result, seconds: Date().timeIntervalSince(start))
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? AITranslation.Failure)?.localizedDescription ?? "服务请求失败，请检查翻译设置、网络与额度"
                self?.complete(job, result: message, seconds: nil)
            }
        }
    }
    func translate(_ job: LiveSubtitleTranslationJob, using session: TranslationSession) async {
        guard translationJob?.id == job.id else { return }
        let requestStart = Date()
        do {
            let result = try await session.translate(job.text)
            complete(job, result: result.targetText, seconds: Date().timeIntervalSince(requestStart))
        } catch {
            complete(job, result: "翻译失败：\(error.localizedDescription)", seconds: nil)
        }
    }
    private func complete(_ job: LiveSubtitleTranslationJob, result: String, seconds: Double?) {
        guard translationJob?.id == job.id else { return }
        translationTimeout?.cancel(); translationTimeout = nil
        remoteTask = nil; remoteRunner = nil
        if captions.first(where: { $0.id == job.captionID })?.original == job.text {
            updateCaption(job.captionID, text: result, seconds: seconds)
            translationQueue.removeAll { $0 == job.captionID }
        }
        translationJob = nil
        translationID = nil
        nextTranslation()
    }

}

@available(macOS 26.0, *)
private struct LiveSubtitleTranslationWorker: View {
    @ObservedObject var model: LiveSubtitleModel
    let job: LiveSubtitleTranslationJob
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(source: Locale.Language(identifier: model.sourceLanguage.translationCode), target: Locale.Language(identifier: "zh-Hans")) { session in
                await model.translate(job, using: session)
            }
    }
}

@available(macOS 26.0, *)
struct LiveSubtitleView: View {
    @ObservedObject var model: LiveSubtitleModel
    @ObservedObject private var providers = TranslationService.shared
    @AppStorage("translation.live.rows") private var rows = 3
    @AppStorage("translation.live.showOriginal") private var showOriginal = true
    @AppStorage("translation.live.fontSize") private var fontSize = 26.0
    @AppStorage("translation.live.widthPercent") private var widthPercent = 70.0
    @AppStorage("translation.live.opacity") private var backgroundOpacity = 0.78
    @AppStorage("translation.live.floating") private var floating = true
    @State private var hovering = false
    @State private var settings = false
    @State private var diagnostics = false
    @State private var clickThrough = false

    private var count: Int { LiveSubtitlePolicy.visibleCount(rows) }
    private var size: Double { LiveSubtitlePolicy.fontSize(fontSize) }
    private var visibleCaptions: [LiveSubtitleCaption] { Array(model.captions.suffix(count)) }
    private var canStart: Bool {
        model.ready && !model.busy && LiveSubtitlePolicy.mayStart(provider: model.provider, consent: model.cloudConsent)
    }
    private var serviceTitle: String {
        if model.provider == "system" { return "Apple 本地" }
        if model.provider == "codex" { return "Codex CLI" }
        return providers.aiProfileOptions.first { TranslationProviderSelection.ai($0.id) == model.provider }?.name ?? "AI API"
    }
    var body: some View {
        VStack(spacing: 14) {
            toolbar
                .opacity(hovering || !model.running || settings ? 1 : 0)
                .allowsHitTesting(hovering || !model.running || settings)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        if visibleCaptions.isEmpty {
                            Text(model.partial.isEmpty ? (model.running ? "正在聆听…" : "准备好后，开始字幕") : model.partial)
                                .font(.system(size: size, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, minHeight: 72)
                        } else {
                            ForEach(visibleCaptions) { caption in
                                VStack(spacing: 5) {
                                    Text(caption.translated)
                                        .font(.system(size: size, weight: .semibold))
                                        .foregroundStyle(.white)
                                    if showOriginal {
                                        Text(caption.original)
                                            .font(.system(size: max(13, size * 0.64)))
                                            .foregroundStyle(.white.opacity(0.64))
                                    }
                                }
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .opacity(caption.id == visibleCaptions.last?.id ? 1 : 0.72)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(.horizontal, 10)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.englishRevision) { proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: model.captions.last?.translated) { proxy.scrollTo("latest", anchor: .bottom) }
            }
            if !model.running {
                Text(model.state).font(.caption).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(3).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(minWidth: 600, minHeight: 150)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(LiveSubtitlePolicy.opacity(backgroundOpacity)))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.2), lineWidth: 1))
        .onHover { hovering = $0 }
        .preferredColorScheme(.dark)
        .task { providers.refreshAIProfiles(); await model.preflight(); resize() }
        .onChange(of: model.sourceLanguage) { Task { await model.preflight() } }
        .onChange(of: model.provider) { Task { await model.preflight() } }
        .onChange(of: model.englishRevision) { model.englishViewUpdated() }
        .onChange(of: rows) { resize() }
        .onChange(of: fontSize) { resize() }
        .onChange(of: widthPercent) { resize() }
        .onChange(of: showOriginal) { resize() }
        .onChange(of: floating) { LiveSubtitleWindowController.shared.setFloating(floating) }
        .onReceive(NotificationCenter.default.publisher(for: .liveSubtitleInteractionRestored)) { _ in clickThrough = false }
        .background {
            if model.provider == "system", let job = model.translationJob {
                LiveSubtitleTranslationWorker(model: model, job: job).id(job.id)
            }
        }
        .onDisappear { Task { await model.stop() } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Circle().fill(model.running ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text("实时字幕").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            Menu {
                ForEach(LiveSubtitleLanguage.allCases, id: \.self) { language in
                    Button(language.title) { model.sourceLanguage = language }
                }
            } label: { Label("\(model.sourceLanguage.title) → 简体中文", systemImage: "chevron.down").font(.caption) }
                .disabled(model.running || model.busy)
            Menu {
                Button("Apple 本地") { model.provider = "system" }
                ForEach(providers.aiProfileOptions) { profile in
                    Button(profile.name) { model.provider = TranslationProviderSelection.ai(profile.id); settings = true }
                }
                Button("Codex CLI") { model.provider = "codex"; settings = true }
            } label: { Text(serviceTitle).font(.caption) }
                .disabled(model.running || model.busy)
            Spacer(minLength: 0)
            Button { floating.toggle() } label: { Image(systemName: floating ? "pin.fill" : "pin") }
                .help("窗口置顶")
            Button {
                if model.running { Task { await model.stop(reason: "已暂停 · 点击播放可重新开始") } }
                else { Task { await model.start() } }
            } label: { Image(systemName: model.running ? "pause.fill" : "play.fill") }
                .disabled(model.busy || (!model.running && !canStart))
                .help(model.running ? "暂停字幕" : "开始字幕")
            Button { model.clearCaptions() } label: { Image(systemName: "eraser") }
                .help("清屏（不中断采集，从下一段语音继续）")
                .accessibilityLabel("清屏")
                .disabled(model.busy)
            Button { settings.toggle() } label: { Image(systemName: "gearshape") }
                .help("字幕设置")
                .popover(isPresented: $settings, arrowEdge: .top) { settingsView }
            Button { LiveSubtitleWindowController.shared.close() } label: { Image(systemName: "xmark") }
                .help("关闭并停止字幕")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .frame(height: 24)
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("字幕设置").font(.headline)
                    Spacer()
                    Button { settings = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                Picker("语音语言", selection: $model.sourceLanguage) {
                    ForEach(LiveSubtitleLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(model.running || model.busy)
                Picker("翻译服务", selection: $model.provider) {
                    Text("Apple 本地").tag("system")
                    ForEach(providers.aiProfileOptions) { Text($0.name).tag(TranslationProviderSelection.ai($0.id)) }
                    Text("Codex CLI").tag("codex")
                }.disabled(model.running || model.busy)
                Text("暂停后可切换语言或服务。").font(.caption).foregroundStyle(.secondary)
                if model.provider != "system" {
                    Toggle("允许将原文发送到所选 AI 服务", isOn: $model.cloudConsent).disabled(model.running || model.busy)
                    Text("仅发送定稿文字，可能消耗费用或账户额度；Codex CLI 可能较慢。").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Picker("保留字幕条数", selection: $rows) {
                    ForEach(1...5, id: \.self) { Text("\($0) 条").tag($0) }
                }
                Text("默认最近 3 条；每条包含译文及可选原文，长句会换行。").font(.caption).foregroundStyle(.secondary)
                Toggle("显示原文", isOn: $showOriginal)
                HStack { Text("字号"); Slider(value: $fontSize, in: 18...36, step: 1); Text("\(Int(size))").monospacedDigit() }
                HStack {
                    Text("字幕宽度")
                    Slider(value: $widthPercent, in: 40...100, step: 1)
                    Text("\(Int(LiveSubtitlePolicy.widthPercent(widthPercent)))%").monospacedDigit()
                }
                Text("按字幕所在屏幕的可用宽度计算；最小 600 点。拖到另一屏幕后自动适配。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Text("背景不透明度"); Slider(value: $backgroundOpacity, in: 0.25...0.95); Text("\(Int(LiveSubtitlePolicy.opacity(backgroundOpacity) * 100))%").monospacedDigit() }
                Toggle("窗口置顶", isOn: $floating)
                Toggle("鼠标穿透", isOn: $clickThrough)
                    .onChange(of: clickThrough) {
                        if clickThrough { settings = false }
                        LiveSubtitleWindowController.shared.setClickThrough(clickThrough)
                    }
                Text("开启穿透后，从菜单栏「实时字幕 → 打开字幕窗口」恢复操作。拖动字幕背景可移动位置。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("诊断信息", isExpanded: $diagnostics) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.state)
                        Text(model.translationState)
                        Text(model.timingSummary)
                        Text(model.timingDetail)
                        Text("有声音量阈值可能被音乐触发；视图更新时间不等于屏幕实际呈现。")
                        Text(String(format: "%.0f dB · %ds · %d 帧", 20 * log10(max(model.level, 0.000001)), model.duration, model.receivedFrames))
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(20)
        }.frame(width: 370, height: 560)
    }
    private func resize() {
        let rowHeight = size * (showOriginal ? 2.5 : 1.7) + 14
        LiveSubtitleWindowController.shared.resize(height: min(640, max(190, Double(count) * rowHeight + 92)),
                                                   widthPercent: widthPercent)
    }
}

extension Notification.Name {
    static let liveSubtitleInteractionRestored = Notification.Name("VorssaintLiveSubtitleInteractionRestored")
}

@available(macOS 26.0, *)
private final class LiveSubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@available(macOS 26.0, *)
@MainActor final class LiveSubtitleWindowController: NSObject, NSWindowDelegate {
    static let shared = LiveSubtitleWindowController()
    private var window: NSWindow?
    private var model: LiveSubtitleModel?
    private var preferredHeight = 330.0
    private var adjustingFrame = false
    func show() {
        guard AppFeature.liveSubtitles.isAvailable else { return }
        if let window {
            window.ignoresMouseEvents = false
            NotificationCenter.default.post(name: .liveSubtitleInteractionRestored, object: nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = LiveSubtitleModel()
        self.model = model
        let window = LiveSubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 330),
                                      styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        window.title = "实时字幕"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 600, height: 150)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let preference = UserDefaults.standard.object(forKey: "translation.live.floating") as? Bool ?? true
        window.level = preference ? .floating : .normal
        self.window = window
        window.contentView = NSHostingView(rootView: LiveSubtitleView(model: model))
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.minY + 48))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func resize(height: Double, widthPercent: Double? = nil) {
        guard !adjustingFrame else { return }
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        adjustingFrame = true
        defer { adjustingFrame = false }
        preferredHeight = height
        let area = screen.visibleFrame
        let percent = widthPercent ?? (UserDefaults.standard.object(forKey: "translation.live.widthPercent") as? Double ?? 70)
        var frame = window.frame
        let center = frame.midX
        frame.size.width = LiveSubtitlePolicy.windowWidth(screenWidth: area.width, percent: percent)
        frame.origin.x = max(area.minX, min(center - frame.width / 2, area.maxX - frame.width))
        frame.size.height = min(height, screen.visibleFrame.height - 40)
        frame.origin.y = max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY - frame.height))
        window.setFrame(frame, display: true, animate: false)
    }
    func windowDidChangeScreen(_ notification: Notification) { resize(height: preferredHeight) }
    func windowDidChangeScreenProfile(_ notification: Notification) { resize(height: preferredHeight) }
    func setClickThrough(_ value: Bool) { window?.ignoresMouseEvents = value }
    func setFloating(_ value: Bool) { window?.level = value ? .floating : .normal }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        let closingModel = model
        Task { await closingModel?.stop() }
        window = nil; model = nil
    }
}
