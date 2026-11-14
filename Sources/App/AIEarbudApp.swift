import SwiftUI
import UIKit
import AVFoundation
import Speech
import MediaPlayer

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Assistant: NSObject, ObservableObject {
    @Published var apiKey: String { didSet { UserDefaults.standard.set(apiKey, forKey: "gkey") } }
    @Published var langCode: String { didSet { UserDefaults.standard.set(langCode, forKey: "lang") } }
    @Published var shortMode: Bool { didSet { UserDefaults.standard.set(shortMode, forKey: "short") } }
    @Published var heard = ""
    @Published var answer = ""
    @Published var status = "Tap Start, then press an AirPod stem once to ask."
    @Published var running = false
    @Published var listening = false

    private let model = "gemini-3.5-flash-lite"
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var player: AVAudioPlayer?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var latestText = ""
    private var history: [[String: Any]] = []
    private var remoteTokens: [(MPRemoteCommand, Any)] = []

    override init() {
        let d = UserDefaults.standard
        apiKey = d.string(forKey: "gkey") ?? ""
        langCode = d.string(forKey: "lang") ?? "en-US"
        shortMode = d.object(forKey: "short") as? Bool ?? true
        super.init()
    }

    // MARK: Start / stop

    func start() {
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    self.status = "Speech recognition is not allowed. Turn it on in Settings > AI Earbud."
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.status = "Microphone is not allowed. Turn it on in Settings > AI Earbud."
                            return
                        }
                        self.activate()
                    }
                }
            }
        }
    }

    private func activate() {
        guard !running else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch {
            status = "Audio error: \(error.localizedDescription)"
            return
        }
        startSilentPlayer()
        setupRemote()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        running = true
        status = "Ready. Press an AirPod stem once to ask."
    }

    func stop() {
        if listening {
            silenceTimer?.invalidate()
            listening = false
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            request?.endAudio()
            task?.cancel()
        }
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        for (cmd, token) in remoteTokens {
            cmd.removeTarget(token)
            cmd.isEnabled = false
        }
        remoteTokens = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
        status = "Stopped."
    }

    // MARK: Keep-alive sound and AirPods button

    private func silentWav() -> Data {
        let rate = 8000
        let bytes = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + bytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(bytes))
        d.append(Data(repeating: 0, count: bytes))
        return d
    }

    private func startSilentPlayer() {
        do {
            player = try AVAudioPlayer(data: silentWav())
            player?.numberOfLoops = -1
            player?.volume = 0.01
            player?.play()
        } catch {
            status = "Could not start keep-alive sound: \(error.localizedDescription)"
        }
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        let all: [MPRemoteCommand] = [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
                                      c.nextTrackCommand, c.previousTrackCommand]
        remoteTokens = []
        for cmd in all {
            cmd.isEnabled = true
            let token = cmd.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.trigger() }
                return .success
            }
            remoteTokens.append((cmd, token))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "AI Earbud",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    @objc private func interrupted(_ n: Notification) {
        guard let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let t = AVAudioSession.InterruptionType(rawValue: v) else { return }
        if t == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
    }

    @objc private func routeChanged(_ n: Notification) {
        guard running,
              let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: v) == .oldDeviceUnavailable else { return }
        let bt: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let stillBT = AVAudioSession.sharedInstance().currentRoute.outputs.contains { bt.contains($0.portType) }
        if !stillBT {
            DispatchQueue.main.async {
                self.stop()
                self.status = "AirPods removed. Stopped."
            }
        }
    }

    // MARK: Ask

    func trigger() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
            return
        }
        if listening {
            finishListening()
            return
        }
        startListening()
    }

    private func startListening() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Paste your Gemini API key first."
            return
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: langCode)), rec.isAvailable else {
            status = "Speech recognition is not available."
            return
        }
        recognizer = rec
        latestText = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            status = "Microphone not ready. Try again."
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = "Mic error: \(error.localizedDescription)"
            return
        }
        listening = true
        status = "Listening..."
        armTimer(seconds: 5)

        task = rec.recognitionTask(with: req) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self = self, self.listening, let r = result else { return }
                self.latestText = r.bestTranscription.formattedString
                self.heard = self.latestText
                self.armTimer(seconds: 1.5)
            }
        }
    }

    private func armTimer(seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.finishListening()
        }
    }

    private func finishListening() {
        silenceTimer?.invalidate()
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        let q = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            status = "Did not hear anything. Press again to ask."
            return
        }
        status = "Thinking..."
        answer = "..."
        Task { await respond(q) }
    }

    private func respond(_ question: String) async {
        do {
            let text = try await callGemini(question)
            await MainActor.run {
                self.answer = text
                self.status = "Ready. Press an AirPod stem once to ask."
                self.speak(text)
            }
        } catch {
            await MainActor.run {
                self.answer = ""
                self.status = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: langCode)
        synth.speak(u)
    }

    private func callGemini(_ question: String) async throws -> String {
        let rules = " Rules: (1) When asked what a word or thing means, start with the plain dictionary-style meaning, then add a short example only if it helps. (2) The user's text comes from speech recognition and can contain mishearings. If a phrase looks odd or does not make sense, say you may have misheard and ask them to repeat, instead of guessing. (3) If the user states something that is wrong, politely correct it. Never agree just to be agreeable, and never open with praise like 'spot on' or 'great question'. (4) You have no internet access, so you cannot know live information like weather, news, prices or scores. If asked, say plainly that you can't check that live. (5) Never invent facts. If you are not sure, say so. Today is \(Date().formatted())."
        let shortStyle = "You are a friendly voice assistant in the user's earbud while they talk to someone. Answer in one or two short sentences. No lists, no markdown, no links. Reply in the language the user speaks."
        let fullStyle = "You are a friendly voice assistant in the user's earbud. Explain clearly and fully, like a patient guide. No lists, no markdown, no links, because your answer is read aloud. Reply in the language the user speaks."
        let system = (shortMode ? shortStyle : fullStyle) + rules

        var contents = history
        contents.append(["role": "user", "parts": [["text": question]]])
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": 1000, "temperature": 0.3]
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(message: "Unreadable response")
        }
        if let e = json["error"] as? [String: Any], let m = e["message"] as? String {
            throw AppError(message: m)
        }
        let candidates = json["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answerText = text.isEmpty ? "(no answer)" : text

        history.append(["role": "user", "parts": [["text": question]]])
        history.append(["role": "model", "parts": [["text": answerText]]])
        if history.count > 12 { history.removeFirst(2) }
        return answerText
    }
}

struct ContentView: View {
    @StateObject var a = Assistant()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Earbud").font(.largeTitle).bold()

                SecureField("Gemini API key", text: $a.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("Language", selection: $a.langCode) {
                    Text("English").tag("en-US")
                    Text("Русский").tag("ru-RU")
                    Text("Svenska").tag("sv-SE")
                }
                .pickerStyle(.segmented)

                Toggle("Short answers (in a conversation)", isOn: $a.shortMode)

                Button(a.running ? "Stop" : "Start") {
                    if a.running { a.stop() } else { a.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(a.running ? .red : .blue)
                .controlSize(.large)

                Button("Ask now (same as an AirPods press)") { a.trigger() }
                    .buttonStyle(.bordered)
                    .disabled(!a.running)

                Text(a.listening ? "Listening..." : a.status)
                    .font(.footnote)
                    .foregroundColor(.gray)

                Text("You said:").font(.caption).foregroundColor(.gray)
                Text(a.heard.isEmpty ? " " : a.heard)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.15)).cornerRadius(10)

                Text("AI:").font(.caption).foregroundColor(.gray)
                Text(a.answer.isEmpty ? " " : a.answer)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.15)).cornerRadius(10)
            }
            .padding()
        }
    }
}

@main
struct AIEarbudApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
