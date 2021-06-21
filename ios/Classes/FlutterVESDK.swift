import Flutter
import UIKit
import ImglyKit
import imgly_sdk
import AVFoundation

@available(iOS 9.0, *)
public class FlutterVESDK: FlutterIMGLY, FlutterPlugin, VideoEditViewControllerDelegate {

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
            self.result?(FlutterError(code: "multiple_requests", message: "Cancelled due to multiple requests.", details: nil))
            self.result = nil
        }

        if call.method == "openEditor" {
            let configuration = arguments["configuration"] as? IMGLYDictionary
            let serialization = arguments["serialization"] as? IMGLYDictionary
            self.result = result

            var video: Video?
            if let assetObject = arguments["video"] as? String,
               let assetURL = EmbeddedAsset(from: assetObject).resolvedURL, let url = URL(string: assetURL) {
                video = Video(url: url)
            } else {
                result(FlutterError(code: "Could not load video.", message: nil, details: nil))
                return
            }

            guard let finalVideo = video else {
                result(FlutterError(code: "Could not load video.", message: nil, details: nil))
                return
            }

            self.present(video: finalVideo, configuration: configuration, serialization: serialization)
        } else if call.method == "unlock" {
            guard let license = arguments["license"] as? String else { return }
            self.result = result
            self.unlockWithLicense(with: license)
        }
    }

    // MARK: - Presenting editor

    /// Presents an instance of `VideoEditViewController`.
    /// - Parameter video: The `Video` to initialize the editor with.
    /// - Parameter configuration: The configuration for the editor in JSON format.
    /// - Parameter serialization: The serialization as `IMGLYDictionary`.
    private func present(video: Video, configuration: IMGLYDictionary?, serialization: IMGLYDictionary?) {
        self.present(mediaEditViewControllerBlock: { (configurationData, serializationData) -> MediaEditViewController? in

            var photoEditModel = PhotoEditModel()
            var videoEditViewController: VideoEditViewController

            if let _serialization = serializationData {
                let deserializationResult = Deserializer.deserialize(data: _serialization, imageDimensions: video.size, assetCatalog: configurationData?.assetCatalog ?? .shared)
                photoEditModel = deserializationResult.model ?? photoEditModel
            }

//            if let configuration = configurationData {
//                videoEditViewController = VideoEditViewController(videoAsset: video, configuration: configuration, photoEditModel: photoEditModel)
//            } else {
//                videoEditViewController = VideoEditViewController(videoAsset: video, photoEditModel: photoEditModel)
//            }
            
            videoEditViewController = VideoEditViewController(videoAsset: video, configuration: self.getTripleConfiguration(configuration: configuration), photoEditModel: photoEditModel)
            
            videoEditViewController.modalPresentationStyle = .fullScreen
            videoEditViewController.delegate = self
            return videoEditViewController

        }, utiBlock: { (configurationData) -> CFString in
            return (configurationData?.videoEditViewControllerOptions.videoContainerFormatUTI ?? AVFileType.mp4 as CFString)
        }, configurationData: configuration, serialization: serialization)
    }

    ///Added for triple mobile app ui improvements
    private func getTripleConfiguration(configuration: IMGLYDictionary?) -> Configuration{
        let tripleConfig = Configuration.init { builder in
            if let preconfigured = configuration{
                try? builder.configure(from: preconfigured)
            }
            builder.configureVideoEditViewController { options in
                options.applyButtonConfigurationClosure = { button in
                    button.setImage(UIImage.init(named: "ic_check"), for: .normal)
                }
            }
        }
        return tripleConfig
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
}

@available(iOS 9.0, *)
extension FlutterVESDK {

    /// Called if the video has been successfully exported.
    /// - Parameter videoEditViewController: The instance of `VideoEditViewController` that finished exporting
    /// - Parameter url: The `URL` where the video has been exported to.
    public func videoEditViewController(_ videoEditViewController: VideoEditViewController, didFinishWithVideoAt url: URL?) {

        var serialization: Any?

        if self.serializationEnabled == true {
            guard let serializationData = videoEditViewController.serializedSettings else {
                return
            }
            if self.serializationType == IMGLYConstants.kExportTypeFileURL {
                guard let exportURL = self.serializationFile else {
                    self.result?(FlutterError(code: "Serialization failed.", message: "The URL must not be nil.", details: nil))
                    return
                }
                do {
                    try serializationData.IMGLYwriteToUrl(exportURL, andCreateDirectoryIfNeeded: true)
                    serialization = self.serializationFile?.absoluteString
                } catch let error {
                    self.result?(FlutterError(code: "Serialization failed.", message: error.localizedDescription, details: error))
                }
            } else if self.serializationType == IMGLYConstants.kExportTypeObject {
                do {
                    serialization = try JSONSerialization.jsonObject(with: serializationData, options: .init(rawValue: 0))
                } catch let error {
                    self.result?(FlutterError(code: "Serialization failed.", message: error.localizedDescription, details: error))
                }
            }
        }

        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            let res: [String: Any?] = ["video": url?.absoluteString, "hasChanges": videoEditViewController.hasChanges, "serialization": serialization]
            self.result?(res)
        }
    }
    

    /// Called if the `VideoEditViewController` failed to export the video.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that failed to export the video.
    public func videoEditViewControllerDidFailToGenerateVideo(_ videoEditViewController: VideoEditViewController) {
        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            self.result?(FlutterError(code: "editor_failed", message: "The editor did fail to generate the video.", details: nil))
        }
    }

    /// Called if the `VideoEditViewController` was cancelled.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that has been cancelled.
    public func videoEditViewControllerDidCancel(_ videoEditViewController: VideoEditViewController) {
        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            self.result?(nil)
        }
    }
}
