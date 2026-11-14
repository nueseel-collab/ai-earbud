import SwiftUI
import AVFoundation

class AirPodsWatcher: ObservableObject {
    @Published var connected = false
    @Published var deviceName = ""

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(update),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        update()
    }

    @objc func update() {
        let btTypes: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let bt = outputs.first { btTypes.contains($0.portType) }
        DispatchQueue.main.async {
            self.connected = (bt != nil)
            self.deviceName = bt?.portName ?? ""
        }
    }
}

@main
struct AIEarbudApp: App {
    @StateObject var watcher = AirPodsWatcher()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text(watcher.connected ? "AirPods connected" : "AirPods not connected")
                    .font(.title)
                Text(watcher.deviceName)
                    .foregroundColor(.gray)
            }
            .padding()
        }
    }
}
