name: AIEarbud
options:
  bundleIdPrefix: com.nueseel
  deploymentTarget:
    iOS: "16.0"
targets:
  AIEarbud:
    type: application
    platform: iOS
    sources: [App]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.nueseel.aiearbud
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1"
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: AI Earbud
        UILaunchScreen: {}
        UIBackgroundModes: [audio]
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        NSMicrophoneUsageDescription: AI Earbud listens to your question when you press your AirPods.
        NSSpeechRecognitionUsageDescription: AI Earbud turns your spoken question into text.
