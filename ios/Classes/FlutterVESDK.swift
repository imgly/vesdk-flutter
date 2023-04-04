import Flutter
import UIKit
import ImglyKit
import imgly_sdk
import AVFoundation

@available(iOS 13.0, *)
public class FlutterVESDK: FlutterIMGLY, FlutterPlugin, VideoEditViewControllerDelegate {

    // MARK: - Typealias

    /// A closure to modify a new `VideoEditViewController` before it is presented on screen.
    public typealias VESDKWillPresentBlock = (_ videoEditViewController: VideoEditViewController) -> Void

    // MARK: - Properties

    /// Set this closure to modify a new `VideoEditViewController` before it is presented on screen.
    public static var willPresentVideoEditViewController: VESDKWillPresentBlock?

    /// The `UUID` of the current editor instance.
    private var uuid: UUID?

    // MARK: - Flutter Channel

    /// Registers for the channel in order to communicate with the
    /// Flutter plugin.
    /// - Parameter registrar: The `FlutterPluginRegistrar` used to register.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_editor_sdk", binaryMessenger: registrar.messenger())
        let instance = FlutterVESDK()
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterVESDK.registrar = registrar
        FlutterVESDK.methodeChannel = channel
    }

    /// Retrieves the methods and initiates the fitting behavior.
    /// - Parameter call: The `FlutterMethodCall` containig the information about the method.
    /// - Parameter result: The `FlutterResult` to return to the Flutter plugin.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? IMGLYDictionary else { return }

        if self.result != nil {
            result(FlutterError(code: "Multiple requests.", message: "Cancelled due to multiple requests.", details: nil))
            return
        }

        if call.method == "openEditor" {
            self.openEditor(arguments: arguments, result: result)
        } else if call.method == "unlock" {
            guard let license = arguments["license"] as? String else { return }
            self.result = result
            self.unlockWithLicense(with: license)
        } else if call.method == "release" {
            result(nil)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Presenting editor

    /// Presents the video editor if available.
    ///
    /// - Parameter arguments: The arguments from the method channel request.
    /// - Parameter result: The `FlutterResult` used to communicate with the Dart layer.
    private func openEditor(arguments: IMGLYDictionary, result: @escaping FlutterResult) {
        let configuration = arguments["configuration"] as? IMGLYDictionary
        let serialization = arguments["serialization"] as? IMGLYDictionary
        let videoDictionary = arguments["video"] as? IMGLYDictionary

        if videoDictionary != nil {
            self.result = result
            let (size, valid) = convertSize(from: videoDictionary?["size"] as? IMGLYDictionary)
            var video: Video?

            if let videos = videoDictionary?["videos"] as? [String] {
                let resolvedAssets = videos.compactMap { EmbeddedAsset(from: $0).resolvedURL }
                let assets = resolvedAssets.compactMap{ URL(string: $0) }.map{ VideoSegment(url: $0) }

                if assets.count > 0 {
                    if let videoSize = size {
                        video = Video(segments: assets, size: videoSize)
                    } else {
                        if valid == true {
                            video = Video(segments: assets)
                        } else {
                            result(FlutterError(code: "Invalid video size: width and height must be greater than zero.", message: nil, details: nil))
                            return
                        }
                    }
                } else {
                    if let videoSize = size {
                        video = Video(size: videoSize)
                    } else {
                        result(FlutterError(code: "A video composition without assets must have a specific size.", message: nil, details: nil))
                        return
                    }
                }
            } else if let segments = videoDictionary?["segments"] as? [IMGLYDictionary] {
                var resolvedSegments: [VideoSegment] = []
                segments.forEach { segment in
                    guard let videoURI = segment["videoUri"] as? String, let resolvedURI = EmbeddedAsset(from: videoURI).resolvedURL, let resolvedURL = URL(string: resolvedURI) else { return }
                    let startTime = segment["startTime"] as? Double
                    let endTime = segment["endTime"] as? Double
                    let resolvedSegment = VideoSegment(url: resolvedURL, startTime: startTime, endTime: endTime)
                    resolvedSegments.append(resolvedSegment)
                }

                if resolvedSegments.count > 0 {
                    if let videoSize = size {
                        video = Video(segments: resolvedSegments, size: videoSize)
                    } else {
                        if valid == true {
                            video = Video(segments: resolvedSegments)
                        } else {
                            result(FlutterError(code: "Invalid video size: width and height must be greater than zero.", message: nil, details: nil))
                            return
                        }
                    }
                } else {
                    if let videoSize = size {
                        video = Video(size: videoSize)
                    } else {
                        result(FlutterError(code: "A video composition without assets must have a specific size.", message: nil, details: nil))
                        return
                    }
                }

            } else if let source = videoDictionary?["video"] as? String {
                if let resolvedSource = EmbeddedAsset(from: source).resolvedURL, let url = URL(string: resolvedSource) {
                    video = Video(segment: VideoSegment(url: url))
                }
            } else if let videoSize = size {
                video = Video(size: videoSize)
            }
            guard let finalVideo = video else {
                result(FlutterError(code: "Could not load video.", message: nil, details: nil))
                return
            }

            self.present(video: finalVideo, configuration: configuration, serialization: serialization)
        } else {
            result(FlutterError(code: "The video must not be null.", message: nil, details: nil))
            return
        }
    }

    /// Presents an instance of `VideoEditViewController`.
    /// - Parameter video: The `Video` to initialize the editor with.
    /// - Parameter configuration: The configuration for the editor in JSON format.
    /// - Parameter serialization: The serialization as `IMGLYDictionary`.
    private func present(video: Video, configuration: IMGLYDictionary?, serialization: IMGLYDictionary?) {
        self.uuid = UUID()
        self.present(mediaEditViewControllerBlock: { (configurationData, serializationData) -> MediaEditViewController? in

            var photoEditModel = PhotoEditModel()
            var videoEditViewController: VideoEditViewController

            if let _serialization = serializationData {
                let deserializationResult = Deserializer.deserialize(data: _serialization, imageDimensions: video.size, assetCatalog: configurationData?.assetCatalog ?? .defaultItems)
                photoEditModel = deserializationResult.model ?? photoEditModel
            }

            if let configuration = configurationData {
                videoEditViewController = VideoEditViewController.makeVideoEditViewController(videoAsset: video, configuration: configuration, photoEditModel: photoEditModel)
            } else {
                videoEditViewController = VideoEditViewController.makeVideoEditViewController(videoAsset: video, photoEditModel: photoEditModel)
            }
            videoEditViewController.modalPresentationStyle = .fullScreen
            videoEditViewController.delegate = self

            FlutterVESDK.willPresentVideoEditViewController?(videoEditViewController)

            return videoEditViewController
        }, utiBlock: { (configurationData) -> CFString in
            return (configurationData?.videoEditViewControllerOptions.videoContainerFormatUTI ?? AVFileType.mp4 as CFString)
        }, configurationData: configuration, serialization: serialization)
    }

    // MARK: - Licensing

    /// Unlocks the license from a url.
    /// - Parameter url: The URL where the license file is located.
    public override func unlockWithLicenseFile(at url: URL) {
        DispatchQueue.main.async {
            do {
                try VESDK.unlockWithLicense(from: url)
                self.result = nil
            } catch let error {
                self.handleLicenseError(with: error as NSError)
            }
        }
    }

    // MARK: - Helpers

    /// Converts a given dictionary into a `CGSize`.
    /// - Parameter dictionary: The `IMGLYDictionary` to retrieve the size from.
    /// - Returns: The converted `CGSize` if any and a `bool` indicating whether size is valid.
    private func convertSize(from dictionary: IMGLYDictionary?) -> (CGSize?, Bool) {
        if let validDictionary = dictionary {
            guard let height = validDictionary["height"] as? Double, let width = validDictionary["width"] as? Double else {
                return (nil, false)
            }
            if height > 0 && width > 0 {
                return (CGSize(width: width, height: height), true)
            }
            return (nil, false)
        } else {
            return (nil, true)
        }
    }

    /// Handles an occuring error and closes the editor.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that caused the error.
    /// - Parameter code: The error code.
    /// - Parameter message: The error message.
    /// - Parameter details: The error details.
    private func handleError(_ videoEditViewController: VideoEditViewController, code: String, message: String?, details: Any?) {
        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            self.result?(FlutterError(code: code, message: message, details: details))
            self.result = nil
            self.uuid = nil
        }
    }

    /// Serializes the given video segments.
    ///
    /// - Parameter segments: The `VideoSegment`s to serialize.
    /// - Returns: The serialized segments as `IMGLYDictionary`.
    private func serializeSegments(segments: [VideoSegment]) -> [IMGLYDictionary] {
        return segments.compactMap { segment in
            var result: IMGLYDictionary = ["videoUri": segment.url.absoluteString]

            if (segment.startTime != nil) {
                result["startTime"] = segment.startTime
            }
            if (segment.endTime != nil) {
                result["endTime"] = segment.endTime
            }
            return result
        }
    }
}

@available(iOS 13.0, *)
extension FlutterVESDK {
    /// Called if the video has been successfully exported.
    /// - Parameter videoEditViewController: The instance of `VideoEditViewController` that finished exporting
    /// - Parameter result: The `VideoEditorResult` from the editor.
    public func videoEditViewControllerDidFinish(_ videoEditViewController: VideoEditViewController, result: VideoEditorResult) {
        var serialization: Any?

        if self.serializationEnabled == true {
            guard let serializationData = videoEditViewController.serializedSettings else {
                self.handleError(videoEditViewController, code: "Serialization failed.", message: "No serialization data found.", details: nil)
                return
            }
            if self.serializationType == IMGLYConstants.kExportTypeFileURL {
                guard let exportURL = self.serializationFile else {
                    self.handleError(videoEditViewController, code: "Serialization failed.", message: "The URL must not be nil.", details: nil)
                    return
                }
                do {
                    try serializationData.IMGLYwriteToUrl(exportURL, andCreateDirectoryIfNeeded: true)
                    serialization = self.serializationFile?.absoluteString
                } catch let error {
                  self.handleError(videoEditViewController, code: "Serialization failed.", message: error.localizedDescription, details: error.localizedDescription)
                    return
                }
            } else if self.serializationType == IMGLYConstants.kExportTypeObject {
                do {
                    serialization = try JSONSerialization.jsonObject(with: serializationData, options: .init(rawValue: 0))
                } catch let error {
                  self.handleError(videoEditViewController, code: "Serialization failed.", message: error.localizedDescription, details: error.localizedDescription)
                    return
                }
            }
        }

        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            let serializedSegments = self.serializeSegments(segments: result.task.video.segments)
            var res: [String: Any?] = ["video": result.output.url.absoluteString, "hasChanges": result.status == .renderedWithChanges, "serialization": serialization, "videoSize": ["height": result.task.video.size.height, "width": result.task.video.size.width], "identifier": self.uuid?.uuidString]
            if self.serializeVideoSegments {
                res["segments"] = serializedSegments
            }
            self.result?(res)
            self.result = nil
            self.uuid = nil
        }
    }

    /// Called if the `VideoEditViewController` failed to export the video.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that failed to export the video.
    /// - Parameter error: The `VideoEditorError` that caused the failure.
    public func videoEditViewControllerDidFail(_ videoEditViewController: VideoEditViewController, error: VideoEditorError) {
      self.handleError(videoEditViewController, code: "Editor failed", message: "The editor did fail to generate the video.", details: error.localizedDescription)
    }

    /// Called if the `VideoEditViewController` was cancelled.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that has been cancelled.
    public func videoEditViewControllerDidCancel(_ videoEditViewController: VideoEditViewController) {
        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            self.result?(nil)
            self.result = nil
            self.uuid = nil
        }
    }
}
