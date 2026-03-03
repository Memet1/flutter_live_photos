import Flutter
import UIKit
import Foundation
import AVFoundation
import Photos
import MobileCoreServices
import VideoToolbox

public class SwiftLivePhotosPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "live_photos", binaryMessenger: registrar.messenger())
    let instance = SwiftLivePhotosPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
        case "generateFromLocalPath":
            let args = call.arguments as! [String: Any]
            guard let localPath = args["localPath"] as? String else {
                result(false)
                return
            }
            let startTime = args["startTime"] as? Double ?? 0.0
            let duration = args["duration"] as? Double ?? 0.0
            
            NSLog("🍎 [LivePhoto] Запит: Start: %f, Duration: %f", startTime, duration)
            
            let livePhotoClient = LivePhotoClient(callback: {(success) in
                result(success)
            })
            livePhotoClient.runLivePhotoConvertionFromLocalPath(rawURL: localPath, startTime: startTime, duration: duration)
            
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        default:
            result(FlutterMethodNotImplemented)
    }
  }
}

class LivePhotoClient {
    let SRC_KEY = "mp4"
    let STILL_KEY = "png"
    let MOV_KEY = "mov"
    let completedCallback: ((Bool) -> Void)
    
    init(callback: @escaping (Bool) -> Void) {
        completedCallback = callback
    }

    public func runLivePhotoConvertionFromLocalPath(rawURL: String, startTime: Double = 0.0, duration: Double = 0.0) {
        guard let localURL = URL(string: rawURL) else {
            completedCallback(false)
            return
        }
        
        let pngPath = self.filePath(forKey: STILL_KEY)!
        let outputPath = self.filePath(forKey: MOV_KEY)!
        self.deleteFile(url: pngPath)
        self.deleteFile(url: outputPath)
        
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized || status == .limited {
                self.processVideo(at: localURL, startTime: startTime, duration: duration)
            } else {
                NSLog("🍎 [LivePhoto] Немає прав доступу")
                self.completedCallback(false)
            }
        }
    }

    private func processVideo(at url: URL, startTime: Double, duration: Double) {
        NSLog("🍎 [LivePhoto] Крок 1: Обробка відео...")
        let asset = AVURLAsset(url: url)
        
        // Генеруємо превью ТУТ, до будь-яких маніпуляцій з MOV
        self.generateThumbnail(from: asset, at: startTime)
        
        // Тепер створюємо MOV
        self.generateLivePhoto()
    }

    private func generateThumbnail(from asset: AVAsset, at time: Double) {
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        
        if let cgImage = try? imgGenerator.copyCGImage(at: cmTime, actualTime: nil) {
            let originalImage = UIImage(cgImage: cgImage)
            let targetSize = CGSize(width: 1080, height: 1920)
            
            UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
            let widthRatio = targetSize.width / originalImage.size.width
            let heightRatio = targetSize.height / originalImage.size.height
            let scale = max(widthRatio, heightRatio)
            let scaledSize = CGSize(width: originalImage.size.width * scale, height: originalImage.size.height * scale)
            originalImage.draw(in: CGRect(x: (targetSize.width - scaledSize.width)/2, y: (targetSize.height - scaledSize.height)/2, width: scaledSize.width, height: scaledSize.height))
            let finalImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            if let data = finalImage?.jpegData(compressionQuality: 0.9), let path = self.filePath(forKey: STILL_KEY) {
                try? data.write(to: path)
                NSLog("🍎 [LivePhoto] Обкладинка готова")
            }
        }
    }

    private func generateLivePhoto() {
        let pngPath = self.filePath(forKey: STILL_KEY)!
        let movPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("input.mp4") // Тимчасовий вхід
        
        // Важливо: ми використовуємо оригінальний шлях з Flutter для генерації
        // Але оскільки нам треба передати MOV_KEY шлях у плагін, ми зробимо це через метод generate
        
        // Виклик нативної бібліотеки
        LivePhoto.generate(from: pngPath, videoURL: movPath, progress: { _ in }, completion: { livePhoto, resources in
            if let res = resources {
                LivePhoto.saveToLibrary(res) { success in
                    NSLog("🍎 [LivePhoto] Результат збереження: \(success)")
                    self.completedCallback(success)
                }
            } else {
                NSLog("🍎 [LivePhoto] Не вдалося створити ресурси")
                self.completedCallback(false)
            }
        })
    }

    private func filePath(forKey key: String) -> URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("\(key).\(key == STILL_KEY ? "jpg" : "mov")")
    }

    private func deleteFile(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// Перероблений клас для стабільної роботи з HEVC
class LivePhoto {
    typealias LivePhotoResources = (pairedImage: URL, pairedVideo: URL)

    static func generate(from imageURL: URL, videoURL: URL, progress: @escaping (CGFloat) -> Void, completion: @escaping (PHLivePhoto?, LivePhotoResources?) -> Void) {
        let assetID = UUID().uuidString
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("live_photo_cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let outImg = cacheDir.appendingPathComponent("\(assetID).jpg")
        let outVid = cacheDir.appendingPathComponent("\(assetID).mov")
        
        // 1. Пишемо ID в картинку
        guard let _ = LivePhoto.addAssetID(assetID, toImage: imageURL, saveTo: outImg) else {
            completion(nil, nil); return
        }
        
        // 2. Пишемо ID в відео + HEVC 9:16
        LivePhoto.addAssetID(assetID, toVideo: videoURL, saveTo: outVid) { success in
            if success {
                PHLivePhoto.request(withResourceFileURLs: [outVid, outImg], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { lp, info in
                    if let degraded = info[PHLivePhotoInfoIsDegradedKey] as? Bool, degraded { return }
                    completion(lp, (outImg, outVid))
                }
            } else {
                completion(nil, nil)
            }
        }
    }

    static func addAssetID(_ assetID: String, toImage url: URL, saveTo: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(saveTo as CFURL, kUTTypeJPEG, 1, nil) else { return nil }
        var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any] ?? [:]
        props[kCGImagePropertyMakerAppleDictionary] = ["17": assetID]
        CGImageDestinationAddImageFromSource(destination, source, 0, props as CFDictionary)
        return CGImageDestinationFinalize(destination) ? saveTo : nil
    }

    static func addAssetID(_ assetID: String, toVideo url: URL, saveTo: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { completion(false); return }
        
        do {
            let writer = try AVAssetWriter(outputURL: saveTo, fileType: .mov)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6000000]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.transform = videoTrack.preferredTransform
            
            // Метадані QuickTime - КЛЮЧ ДО УСПІХУ
            let metadataItem = AVMutableMetadataItem()
            metadataItem.key = "com.apple.quicktime.content.identifier" as (NSCopying & NSObjectProtocol)?
            metadataItem.keySpace = .mdta
            metadataItem.value = assetID as (NSCopying & NSObjectProtocol)?
            metadataItem.dataType = "com.apple.metadata.datatype.UTF-8"
            writer.metadata = [metadataItem]
            
            writer.add(input)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            
            writer.startWriting()
            reader.startReading()
            writer.startSession(atSourceTime: .zero)
            
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "video_write")) {
                while input.isReadyForMoreMediaData {
                    if let buffer = output.copyNextSampleBuffer() {
                        input.append(buffer)
                    } else {
                        input.markAsFinished()
                        writer.finishWriting { completion(writer.status == .completed) }
                        break
                    }
                }
            }
        } catch { completion(false) }
    }

    static func saveToLibrary(_ res: LivePhotoResources, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .pairedVideo, fileURL: res.pairedVideo, options: nil)
            req.addResource(with: .photo, fileURL: res.pairedImage, options: nil)
        }, completionHandler: { success, _ in completion(success) })
    }
}
