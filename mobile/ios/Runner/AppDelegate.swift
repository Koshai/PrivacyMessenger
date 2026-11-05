import Flutter
import UIKit
import CallKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CXProviderDelegate {
  private let callChannelName = "private_messenger/calls"
  private var callChannel: FlutterMethodChannel?
  private var provider: CXProvider?
  private var activeCall: UUID?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = true
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.includesCallsInRecents = false
    let provider = CXProvider(configuration: configuration)
    provider.setDelegate(self, queue: nil)
    self.provider = provider
    let channel = FlutterMethodChannel(
      name: callChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    callChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "incoming":
        self.report(incoming: true)
        self.activateAudio()
        result(nil)
      case "ongoing":
        self.report(incoming: false)
        self.activateAudio()
        result(nil)
      case "ended":
        self.endSystemCall()
        self.deactivateAudio()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func report(incoming: Bool) {
    let id = activeCall ?? UUID()
    activeCall = id
    let update = CXCallUpdate()
    update.localizedCallerName = incoming ? "Incoming call" : "Call in progress"
    update.hasVideo = false
    update.remoteHandle = CXHandle(type: .generic, value: "call")
    if incoming {
      provider?.reportNewIncomingCall(with: id, update: update) { _ in }
    } else {
      provider?.reportCall(with: id, updated: update)
    }
  }

  private func endSystemCall() {
    guard let id = activeCall else { return }
    provider?.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
    activeCall = nil
  }

  private func activateAudio() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetooth, .allowBluetoothA2DP]
    )
    try? session.setActive(true)
  }

  private func deactivateAudio() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func providerDidReset(_ provider: CXProvider) {
    activeCall = nil
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    activeCall = nil
    callChannel?.invokeMethod("systemEnded", arguments: nil)
    deactivateAudio()
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    activateAudio()
    action.fulfill()
  }
}
