import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Canal com o Dart ("comboio/native"): permissões e pequenos ajustes.
    let channel = FlutterMethodChannel(
      name: "comboio/native",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    nativeChannel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermissions":
      requestMicrophone { granted in
        result(["microphone": granted, "bluetooth": true, "notifications": true])
      }
    case "permissionStatus":
      result(["microphone": microphoneGranted(), "bluetooth": true, "notifications": true])
    case "openAppSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "setKeepScreenOn":
      let args = call.arguments as? [String: Any]
      let on = args?["on"] as? Bool ?? false
      UIApplication.shared.isIdleTimerDisabled = on
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func microphoneGranted() -> Bool {
    if #available(iOS 17.0, *) {
      return AVAudioApplication.shared.recordPermission == .granted
    }
    return AVAudioSession.sharedInstance().recordPermission == .granted
  }

  private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
    let done: (Bool) -> Void = { granted in
      DispatchQueue.main.async { completion(granted) }
    }
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted:
        done(true)
      case .denied:
        done(false)
      default:
        AVAudioApplication.requestRecordPermission { granted in done(granted) }
      }
    } else {
      let session = AVAudioSession.sharedInstance()
      switch session.recordPermission {
      case .granted:
        done(true)
      case .denied:
        done(false)
      default:
        session.requestRecordPermission { granted in done(granted) }
      }
    }
  }
}
