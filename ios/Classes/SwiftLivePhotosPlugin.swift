import Flutter
import UIKit
import Foundation
import AVFoundation
import Photos
import MobileCoreServices

public class SwiftLivePhotosPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "live_photos", binaryMessenger: registrar.messenger())
        let instance = SwiftLivePhotosPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "generateFromLocalPath" {
            let args = call.arguments as! [String: Any]
            guard let localPath = args["localPath"] as? String else {
                result(false)
                return
            }
            let startTime = args["startTime"] as? Double ?? 0.0
            let duration = args["duration"] as? Double ?? 0.0
            
            NSLog("🍎 [LivePhoto] СТАРТ: Бронебійна версія. Start: %f, Duration: %f", startTime, duration)
            
            let client = LivePhotoClient { success in
                NSLog("🍎 [LivePhoto] ФІНАЛ: %@", success ? "Успіх" : "Помилка")
                result(success)
            }
            client.process(rawURL: localPath, startTime: startTime, duration: duration)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
}

class LivePhotoClient {
    let completedCallback: ((Bool) -> Void)
    let assetID = UUID().uuidString
    
    init(callback: @escaping (Bool) -> Void) {
        completedCallback = callback
    }

    func process(rawURL: String, startTime: Double, duration: Double) {
        let sourceURL = URL(fileURLWithPath: rawURL)
        
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                NSLog("🍎 [LivePhoto] Немає прав на галерею")
                self.completedCallback(false)
                return
            }
            self.trimVideo(sourceURL: sourceURL, startTime: startTime, duration: duration)
        }
    }

    // 1. БЕЗПЕЧНА ОБРІЗКА (AVAssetExportSession)
    private func trimVideo(sourceURL: URL, startTime: Double, duration: Double) {
        let asset = AVURLAsset(url: sourceURL)
        let trimmedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_trimmed.mov")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            self.completedCallback(false)
            return
        }
        
        exportSession.outputURL = trimmedURL
        exportSession.outputFileType = .mov
        
        if startTime > 0 || duration > 0 {
            let start = CMTime(seconds: startTime, preferredTimescale: 600)
            let dur = duration > 0 ? CMTime(seconds: duration, preferredTimescale: 600) : asset.duration
            exportSession.timeRange = CMTimeRange(start: start, duration: dur)
        }
        
        exportSession.exportAsynchronously {
            if exportSession.status == .completed {
                NSLog("🍎 [LivePhoto] Відео успішно обрізано")
                self.generateResources(trimmedVideoURL: trimmedURL)
            } else {
                NSLog("🍎 [LivePhoto] Помилка обрізки: \(String(describing: exportSession.error))")
                self.completedCallback(false)
            }
        }
    }

    // 2. ГЕНЕРАЦІЯ КАРТИНКИ І МЕТАДАНИХ
    private func generateResources(trimmedVideoURL: URL) {
        let asset = AVURLAsset(url: trimmedVideoURL)
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        
        let jpgURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(assetID).jpg")
        let finalMovURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(assetID).mov")
        
        // Робимо скріншот першого кадру
        guard let cgImage = try? imgGenerator.copyCGImage(at: .zero, actualTime: nil) else {
            self.completedCallback(false)
            return
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpgData = uiImage.jpegData(compressionQuality: 1.0) else {
            self.completedCallback(false)
            return
        }
        
        try? jpgData.write(to: jpgURL)
        
        // Додаємо Asset ID в картинку
        guard LivePhoto.addAssetID(assetID, toImage: jpgURL, saveTo: jpgURL) != nil else {
            self.completedCallback(false)
            return
        }
        
        // Додаємо Asset ID у відео (просте копіювання з додаванням метаданих)
        LivePhoto.addAssetIDToVideo(assetID, toVideo: trimmedVideoURL, saveTo: finalMovURL) { success in
            if success {
                NSLog("🍎 [LivePhoto] Метадані успішно додані. Зберігаємо в галерею...")
                LivePhoto.saveToLibrary(imageURL: jpgURL, videoURL: finalMovURL, completion: self.completedCallback)
            } else {
                self.completedCallback(false)
            }
        }
    }
}

class LivePhoto {
    static func addAssetID(_ assetID: String, toImage url: URL, saveTo: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(saveTo as CFURL, kUTTypeJPEG, 1, nil) else { return nil }
        let props = [kCGImagePropertyMakerAppleDictionary as String: ["17": assetID]]
        CGImageDestinationAddImageFromSource(destination, source, 0, props as CFDictionary)
        return CGImageDestinationFinalize(destination) ? saveTo : nil
    }

    static func addAssetIDToVideo(_ assetID: String, toVideo url: URL, saveTo: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(false)
            return
        }
        
        exportSession.outputURL = saveTo
        exportSession.outputFileType = .mov
        
        // ВАЖЛИВО: Безпечне додавання метаданих
        let metadataItem = AVMutableMetadataItem()
        metadataItem.key = "com.apple.quicktime.content.identifier" as (NSCopying & NSObjectProtocol)?
        metadataItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        metadataItem.value = assetID as (NSCopying & NSObjectProtocol)?
        metadataItem.dataType = "com.apple.metadata.datatype.UTF-8"
        
        exportSession.metadata = [metadataItem]
        
        exportSession.exportAsynchronously {
            completion(exportSession.status == .completed)
        }
    }

    static func saveToLibrary(imageURL: URL, videoURL: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            req.addResource(with: .photo, fileURL: imageURL, options: nil)
        }, completionHandler: { success, error in
            if let err = error {
                NSLog("🍎 [LivePhoto] Помилка збереження: \(err.localizedDescription)")
            }
            completion(success)
        })
    }
}
