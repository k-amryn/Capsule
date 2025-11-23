import Cocoa
import FlutterMacOS

public class FFmpegKitFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter.ffmpeg_kit", binaryMessenger: registrar.messenger)
    let instance = FFmpegKitFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Dummy implementation for macOS
    result(FlutterMethodNotImplemented)
  }
}