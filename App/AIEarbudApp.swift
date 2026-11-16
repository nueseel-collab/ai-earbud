import SwiftUI
import UIKit
import AVFoundation
import Speech
import MediaPlayer

struct VoiceOption: Identifiable {
    let id: String
    let label: String
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Assistant: NSObject, ObservableObject {
    @Published var apiKey: String { didSet { UserDefaults.standard.set(apiKey, forKey: "gkey") } }
    @Published var langCode: String { didSet { UserDefaults.standard.set(langCode, forKey: "lang") } }
    @Published var shortMode: Bool { didSet { UserDefaults.standard.set(shortMode, forKey: "short") } }
    @Published var mode: Int { didSet { UserDefaults.standard.set(mode, forKey: "mode") } }
    @Published var voiceID: String { didSet { UserDefaults.standard.set(voiceID, forKey: "voiceid") } }
    @Published var city: String { didSet { UserDefaults.standard.set(city, forKey: "city") } }
    @Published var tavilyKey: String { didSet { UserDefaults.standard.set(tavilyKey, forKey: "tkey") } }
    @Published var autoStart: Bool { didSet { UserDefaults.standard.set(autoStart, forKey: "autostart") } }
    @Published var heard = ""
    @Published var answer = ""
    @Published var status = "Tap Start, then press an AirPod stem once to ask."
    @Published var running = false
    @Published var listening = false
    @Published var lastPress = "none yet"
    @Published var pressCount = 0

    private let model = "gemini-3.5-flash-lite"
    private let synth = AVSpeechSynthesizer()
    private var engine = AVAudioEngine()
    private var player: AVAudioPlayer?
    private var beepPlayer: AVAudioPlayer?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var latestText = ""
    private var history: [[String: Any]] = []
    private var remoteTokens: [(MPRemoteCommand, Any)] = []
    private var starting = false
    private var thinking = false

    // The audio thread reads this, so access goes through a lock.
    private let lock = NSLock()
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?

    // mode 0 = always-on mic using the iPhone mic, 1 = always-on mic using the AirPods mic,
    // 2 = mic only while a question is being asked (AirPods mic),
    // 3 = hybrid: iPhone mic while idle, AirPods mic only while a question is being asked
    private var keepMic: Bool { mode != 2 }
    private var phoneMic: Bool { mode == 0 || mode == 3 }
    private var hybrid: Bool { mode == 3 }
    private var waitingForAirPods = false
    private var didAutoStart = false

    override init() {
        let d = UserDefaults.standard
        apiKey = d.string(forKey: "gkey") ?? ""
        langCode = d.string(forKey: "lang") ?? "en-US"
        shortMode = d.object(forKey: "short") as? Bool ?? true
        mode = d.object(forKey: "mode") as? Int ?? 0
        voiceID = d.string(forKey: "voiceid") ?? ""
        city = d.string(forKey: "city") ?? ""
        tavilyKey = d.string(forKey: "tkey") ?? ""
        autoStart = d.object(forKey: "autostart") as? Bool ?? true
        super.init()
    }

    private func setCurrentRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        liveRequest = r
        lock.unlock()
    }

    private func currentRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return liveRequest
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

    // Called when the app opens: press Start automatically, once per launch.
    func autoStartIfNeeded() {
        guard autoStart, !didAutoStart, !running else { return }
        didAutoStart = true
        status = "Auto-starting..."
        start()
    }

    private func setPlaybackMode() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setActive(true)
        } catch {
            status = "Audio error: \(error.localizedDescription)"
        }
        if let p = player, !p.isPlaying { p.play() }
    }

    private func setCaptureMode() {
        do {
            let s = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = phoneMic
                ? [.allowBluetoothA2DP]
                : [.allowBluetooth, .allowBluetoothA2DP]
            try s.setCategory(.playAndRecord, mode: .default, options: options)
            try s.setActive(true)
            if phoneMic, let builtIn = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? s.setPreferredInput(builtIn)
            }
        } catch {
            status = "Audio error: \(error.localizedDescription)"
        }
        if let p = player, !p.isPlaying { p.play() }
    }

    private func activate() {
        guard !running else { return }
        if keepMic { setCaptureMode() } else { setPlaybackMode() }
        startSilentPlayer()
        setupRemote()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(engineConfigChanged(_:)),
                                               name: .AVAudioEngineConfigurationChange, object: nil)
        running = true
        if keepMic {
            status = "Starting microphone..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.running else { return }
                if self.startEngine() {
                    if self.hybrid {
                        self.status = "Ready (hybrid). Press the stem once, wait for the beep, then ask."
                    } else {
                        let which = self.phoneMic ? "iPhone mic" : "AirPods mic"
                        self.status = "Ready (\(which) on, screen lock OK). Press an AirPod stem once to ask."
                    }
                }
            }
        } else {
            status = "Ready. Press an AirPod stem once to ask."
        }
    }

    func stop() {
        waitingForAirPods = false
        silenceTimer?.invalidate()
        setCurrentRequest(nil)
        if listening {
            listening = false
            request?.endAudio()
            task?.cancel()
        }
        if engine.isRunning { stopEngine() }
        starting = false
        thinking = false
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

    // MARK: AirPods connection and mic switching

    private func bluetoothConnected() -> Bool {
        let bt: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { bt.contains($0.portType) }
    }

    // Hybrid mode: true = use the AirPods mic (call-style link), false = back to the iPhone mic.
    private func applyHybrid(airpodsMic: Bool) {
        do {
            let s = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = airpodsMic
                ? [.allowBluetooth, .allowBluetoothA2DP]
                : [.allowBluetoothA2DP]
            try s.setCategory(.playAndRecord, mode: .default, options: options)
            try s.setActive(true)
            if airpodsMic {
                if let bt = s.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                    try s.setPreferredInput(bt)
                } else {
                    status = "AirPods mic not available."
                }
            } else if let b = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try s.setPreferredInput(b)
            }
        } catch {
            status = "Audio switch error: \(error.localizedDescription)"
        }
    }

    private func restoreIdle() {
        guard running else { return }
        if keepMic { setCaptureMode() } else { setPlaybackMode() }
        if keepMic && !engine.isRunning {
            if startEngine() {
                status = "AirPods back. Ready. Press the stem once to ask."
            }
        } else {
            status = "AirPods back. Ready. Press the stem once to ask."
        }
    }

    // MARK: Microphone engine

    private func startEngine() -> Bool {
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            status = "Microphone not ready. Tap Stop, then Start again."
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Audio is only used while a question is being asked. Otherwise it is dropped.
            self?.currentRequest()?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = "Mic error: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    private func stopEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    @objc private func engineConfigChanged(_ n: Notification) {
        DispatchQueue.main.async {
            guard self.running, self.keepMic, !self.engine.isRunning else { return }
            if self.startEngine() {
                self.status = "Microphone restarted. Press an AirPod stem once to ask."
            }
        }
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

    // A short tone played through the app's own audio, so it reaches the AirPods.
    private func beepWav(freq: Double) -> Data {
        let rate = 16000
        let count = rate * 15 / 100
        let bytes = count * 2
        var d = Data()
        func u32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + bytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(bytes))
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let fade = min(1.0, Double(i) / 160.0, Double(count - i) / 160.0)
            let v = sin(2.0 * Double.pi * freq * t) * 0.6 * fade
            u16(UInt16(bitPattern: Int16(v * 32767)))
        }
        return d
    }

    private func playBeep(freq: Double) {
        do {
            beepPlayer = try AVAudioPlayer(data: beepWav(freq: freq))
            beepPlayer?.volume = 1.0
            beepPlayer?.prepareToPlay()
            beepPlayer?.play()
        } catch {
            // If the tone cannot play, the app still works; there is just no cue.
        }
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        let all: [(MPRemoteCommand, String)] = [
            (c.playCommand, "play"),
            (c.pauseCommand, "pause"),
            (c.togglePlayPauseCommand, "toggle play/pause"),
            (c.nextTrackCommand, "next track"),
            (c.previousTrackCommand, "previous track")
        ]
        remoteTokens = []
        for (cmd, name) in all {
            cmd.isEnabled = true
            let token = cmd.addTarget { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.pressCount += 1
                    self.lastPress = "\(name) #\(self.pressCount)"
                    self.trigger()
                }
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
            DispatchQueue.main.async {
                guard self.running else { return }
                if self.keepMic { self.setCaptureMode() } else { self.setPlaybackMode() }
                if self.keepMic && !self.engine.isRunning {
                    if self.startEngine() {
                        self.status = "Microphone restarted. Press an AirPod stem once to ask."
                    }
                }
            }
        }
    }

    @objc private func routeChanged(_ n: Notification) {
        guard running,
              let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: v) else { return }
        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async {
                if !self.bluetoothConnected() {
                    self.waitingForAirPods = true
                    self.status = "AirPods not connected (out of range?). Waiting for them..."
                }
            }
        } else if reason == .newDeviceAvailable {
            DispatchQueue.main.async {
                if self.waitingForAirPods && self.bluetoothConnected() {
                    self.waitingForAirPods = false
                    self.restoreIdle()
                }
            }
        }
    }

    // MARK: Ask

    func trigger() {
        if starting || thinking { return }
        if !bluetoothConnected() {
            waitingForAirPods = true
            status = "AirPods not connected. Waiting for them..."
            return
        }
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

        if keepMic {
            guard engine.isRunning else {
                status = "Microphone is not running. Open the app, tap Stop, then Start."
                return
            }
            if hybrid {
                starting = true
                status = "Switching to AirPods mic..."
                applyHybrid(airpodsMic: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.beginHybridCapture(with: rec)
                }
                return
            }
            let req = makeRequest()
            beginRecognition(with: rec, req: req)
            return
        }

        starting = true
        status = "Starting microphone..."
        setCaptureMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.beginCapture(with: rec)
        }
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        setCurrentRequest(req)
        return req
    }

    private func beginHybridCapture(with rec: SFSpeechRecognizer) {
        guard running else {
            starting = false
            return
        }
        if !engine.isRunning {
            if !startEngine() {
                starting = false
                applyHybrid(airpodsMic: false)
                return
            }
        }
        status = "Beep, then speak..."
        playBeep(freq: 880)
        // Wait for the beep to finish so it is not picked up as speech.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            self.starting = false
            guard self.running else { return }
            let req = self.makeRequest()
            self.beginRecognition(with: rec, req: req)
        }
    }

    private func beginCapture(with rec: SFSpeechRecognizer) {
        starting = false
        guard running else { return }
        let req = makeRequest()
        if !startEngine() {
            setCurrentRequest(nil)
            request = nil
            setPlaybackMode()
            return
        }
        beginRecognition(with: rec, req: req)
    }

    private func beginRecognition(with rec: SFSpeechRecognizer, req: SFSpeechAudioBufferRecognitionRequest) {
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
        setCurrentRequest(nil)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if !keepMic {
            stopEngine()
            setPlaybackMode()
        } else if hybrid {
            applyHybrid(airpodsMic: false)
        }
        let q = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            status = "Did not hear anything. Press again to ask."
            return
        }
        status = "Thinking..."
        answer = "..."
        thinking = true
        if hybrid {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.playBeep(freq: 600)
            }
        }
        Task { await respond(q) }
    }

    private func respond(_ question: String) async {
        do {
            let text = try await callGemini(question)
            await MainActor.run {
                self.thinking = false
                self.answer = text
                self.status = "Ready. Press an AirPod stem once to ask."
                self.speak(text)
            }
        } catch {
            await MainActor.run {
                self.thinking = false
                self.answer = ""
                self.status = "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Voice

    private func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    // Installed voices for the chosen language, best quality first.
    // The old novelty and robot voices are left out.
    func availableVoices() -> [VoiceOption] {
        let prefix = String(langCode.prefix(2))
        let list = AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language.hasPrefix(prefix) && !v.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
        }
        let sorted = list.sorted { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }
        return sorted.map { v in
            VoiceOption(id: v.identifier, label: "\(v.name) - \(v.language) - \(qualityName(v.quality))")
        }
    }

    private func pickVoice() -> AVSpeechSynthesisVoice? {
        let prefix = String(langCode.prefix(2))
        if !voiceID.isEmpty,
           let chosen = AVSpeechSynthesisVoice(identifier: voiceID),
           chosen.language.hasPrefix(prefix) {
            return chosen
        }
        let best = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == langCode && !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice.") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return best ?? AVSpeechSynthesisVoice(language: langCode)
    }

    private func sampleText() -> String {
        switch String(langCode.prefix(2)) {
        case "ru": return "Привет! Вот так я звучу. Спрашивайте меня о чём угодно."
        case "sv": return "Hej! Så här låter jag. Fråga mig vad som helst."
        default: return "Hi! This is how I sound. Ask me anything you like."
        }
    }

    func testVoice() {
        if !running {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default, options: [])
            try? s.setActive(true)
        }
        synth.stopSpeaking(at: .immediate)
        speak(sampleText())
    }

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = pickVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.pitchMultiplier = 1.0
        synth.speak(u)
    }

    // MARK: Live information (weather and web search)

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchJSON(_ url: URL, post body: [String: Any]? = nil, bearer: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if let body = body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let b = bearer {
            req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(message: "Unreadable response")
        }
        return json
    }

    private func weatherText(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61, 63, 65: return "rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95, 96, 99: return "thunderstorm"
        default: return "unknown conditions"
        }
    }

    // Free weather data from Open-Meteo (no key needed).
    private func weatherSummary(city: String) async throws -> String {
        var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        g.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        let geo = try await fetchJSON(g.url!)
        guard let r = (geo["results"] as? [[String: Any]])?.first,
              let lat = (r["latitude"] as? NSNumber)?.doubleValue,
              let lon = (r["longitude"] as? NSNumber)?.doubleValue else {
            return "No place named \(city) was found."
        }
        let place = [r["name"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")

        var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        f.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "3")
        ]
        let w = try await fetchJSON(f.url!)
        let cur = w["current"] as? [String: Any] ?? [:]
        let daily = w["daily"] as? [String: Any] ?? [:]

        func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
        func nums(_ any: Any?) -> [Double?] {
            ((any as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }

        var lines: [String] = []
        var now = "Weather for \(place). Right now:"
        if let c = num(cur["weather_code"]) { now += " \(weatherText(Int(c)))," }
        if let t = num(cur["temperature_2m"]) { now += " \(Int(t.rounded())) degrees Celsius" }
        if let a = num(cur["apparent_temperature"]) { now += " (feels like \(Int(a.rounded())))" }
        if let wind = num(cur["wind_speed_10m"]) { now += ", wind \(Int(wind.rounded())) km/h" }
        if let p = num(cur["precipitation"]), p > 0 { now += ", precipitation \(p) mm" }
        lines.append(now)

        let days = (daily["time"] as? [String]) ?? []
        let maxT = nums(daily["temperature_2m_max"])
        let minT = nums(daily["temperature_2m_min"])
        let rain = nums(daily["precipitation_probability_max"])
        let codes = nums(daily["weather_code"])
        let labels = ["Today", "Tomorrow", "In two days"]
        for i in 0..<min(days.count, 3) {
            var s = "\(labels[i]):"
            if i < codes.count, let c = codes[i] { s += " \(weatherText(Int(c)))," }
            if i < minT.count, let lo = minT[i], i < maxT.count, let hi = maxT[i] {
                s += " low \(Int(lo.rounded())), high \(Int(hi.rounded())) degrees"
            }
            if i < rain.count, let p = rain[i] { s += ", chance of rain or snow \(Int(p.rounded())) percent" }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    // Web search through Tavily (needs the free key from the settings).
    private func webSearch(_ query: String) async throws -> String {
        let url = URL(string: "https://api.tavily.com/search")!
        let body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            "max_results": 3,
            "include_answer": true
        ]
        let json = try await fetchJSON(url, post: body, bearer: trimmed(tavilyKey))
        if let detail = json["detail"] as? [String: Any], let m = detail["error"] as? String {
            throw AppError(message: m)
        }
        if let detail = json["detail"] as? String {
            throw AppError(message: detail)
        }
        var lines: [String] = []
        if let a = json["answer"] as? String, !a.isEmpty {
            lines.append("Summary: \(a)")
        }
        if let results = json["results"] as? [[String: Any]] {
            for r in results.prefix(3) {
                let title = r["title"] as? String ?? ""
                let content = r["content"] as? String ?? ""
                lines.append("- \(title): \(String(content.prefix(400)))")
            }
        }
        return lines.isEmpty ? "No results found." : lines.joined(separator: "\n")
    }

    // MARK: Asking the AI

    private func generate(system: String, contents: [[String: Any]]) async throws -> String {
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
        req.setValue(trimmed(apiKey), forHTTPHeaderField: "x-goog-api-key")
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
        let clean = trimmed(text)
        return clean.isEmpty ? "(no answer)" : clean
    }

    private func callGemini(_ question: String) async throws -> String {
        let tavilyOn = !trimmed(tavilyKey).isEmpty
        let cityText = trimmed(city).isEmpty ? "unknown" : trimmed(city)
        let shortStyle = "You are a friendly voice assistant in the user's earbud while they talk to someone. Answer in one or two short sentences. No lists, no markdown, no links. Reply in the language the user speaks."
        let fullStyle = "You are a friendly voice assistant in the user's earbud. Explain clearly and fully, like a patient guide. No lists, no markdown, no links, because your answer is read aloud. Reply in the language the user speaks."
        let style = shortMode ? shortStyle : fullStyle

        let baseRules = " Rules: (1) When asked what a word or thing means, start with the plain dictionary-style meaning, then add a short example only if it helps. (2) The user's text comes from speech recognition and can contain mishearings. If a phrase looks odd or does not make sense, say you may have misheard and ask them to repeat, instead of guessing. (3) If the user states something that is wrong, politely correct it. Never agree just to be agreeable, and never open with praise like 'spot on' or 'great question'. (5) Never invent facts. If you are not sure, say so. Today is \(Date().formatted()). The user's city is \(cityText)."

        let lookupRule: String
        if tavilyOn {
            lookupRule = " (4) You have no direct internet access. If the question needs live or very recent information (weather, news, scores, prices, current events, who currently holds a position), do NOT answer from memory. Reply with exactly one line and nothing else: 'WEATHER: <city>' for weather (use the user's city if they did not name one), or 'SEARCH: <short web search query in English>' for anything else live."
        } else {
            lookupRule = " (4) You have no direct internet access. If the question needs live or very recent information (news, scores, prices, current events), say plainly that you can't check that live. For weather, reply with exactly one line and nothing else: 'WEATHER: <city>' (use the user's city if they did not name one)."
        }

        var contents = history
        contents.append(["role": "user", "parts": [["text": question]]])

        let first = try await generate(system: style + baseRules + lookupRule, contents: contents)
        let firstLine = (first.components(separatedBy: "\n").first ?? first)
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = firstLine.uppercased()
        let wantsWeather = upper.hasPrefix("WEATHER:")
        let wantsSearch = tavilyOn && upper.hasPrefix("SEARCH:")

        var finalText = first
        if wantsWeather || wantsSearch {
            await MainActor.run { self.status = "Looking it up..." }
            let argument = trimmed(String(firstLine.dropFirst(wantsWeather ? 8 : 7)))
            var data = ""
            do {
                if wantsWeather {
                    data = try await weatherSummary(city: argument.isEmpty ? cityText : argument)
                } else {
                    data = try await webSearch(argument)
                }
            } catch {
                data = "The lookup failed: \(error.localizedDescription)"
            }

            let afterRule = " (4) Live data from a lookup is provided in the conversation. Use it to answer. If it does not contain the answer, say so plainly. Never read out links and never mention that you searched."
            var contents2 = history
            contents2.append(["role": "user", "parts": [["text": question]]])
            contents2.append(["role": "model", "parts": [["text": firstLine]]])
            contents2.append(["role": "user", "parts": [["text": "Live data (may be imperfect):\n\(data)\n\nUsing this data, answer my last question briefly in plain spoken language, in the language I spoke."]]])
            finalText = try await generate(system: style + baseRules + afterRule, contents: contents2)
        }

        history.append(["role": "user", "parts": [["text": question]]])
        history.append(["role": "model", "parts": [["text": finalText]]])
        if history.count > 12 { history.removeFirst(2) }
        return finalText
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

                TextField("My city, for weather (e.g. Stockholm)", text: $a.city)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                SecureField("Tavily key (optional, for news and other live info)", text: $a.tavilyKey)
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

                Toggle("Auto-start when the app opens", isOn: $a.autoStart)

                Text("Mode (change before Start):").font(.caption).foregroundColor(.gray)
                Picker("Mode", selection: $a.mode) {
                    Text("Hybrid: phone mic idle, AirPods mic on press (new)").tag(3)
                    Text("Always-on, iPhone mic only (phone must be near)").tag(0)
                    Text("Always-on, AirPods mic (stem gives tone)").tag(1)
                    Text("Mic only on press, AirPods mic (screen on)").tag(2)
                }
                .pickerStyle(.menu)
                .disabled(a.running)

                Text("Voice:").font(.caption).foregroundColor(.gray)
                Picker("Voice", selection: $a.voiceID) {
                    Text("Auto (best available)").tag("")
                    ForEach(a.availableVoices()) { v in
                        Text(v.label).tag(v.id)
                    }
                }
                .pickerStyle(.menu)

                Button("Test voice") { a.testVoice() }
                    .buttonStyle(.bordered)

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

                Text("Last button press: \(a.lastPress)")
                    .font(.footnote)
                    .foregroundColor(.orange)

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
        .onAppear { a.autoStartIfNeeded() }
    }
}

@main
struct AIEarbudApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
