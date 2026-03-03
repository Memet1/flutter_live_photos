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
        case "generateFromURL":
            let args = call.arguments as! [String: Any]
            guard let videoURL = args["videoURL"] as? String else {
                result(false)
                return
            }
            let livePhotoClient = LivePhotoClient(callback: {(success) in
                result(success)
            })
            livePhotoClient.runLivePhotoConvertionFromVideoURL(rawURL: videoURL)
            
        case "generateFromLocalPath":
            let args = call.arguments as! [String: Any]
            guard let localPath = args["localPath"] as? String else {
                print("🍎 [LivePhoto] ПОМИЛКА: Не передано localPath!")
                result(false)
                return
            }
            let startTime = args["startTime"] as? Double ?? 0.0
            let duration = args["duration"] as? Double ?? 0.0
            
            print("🍎 [LivePhoto] СТАРТ: Отримано запит generateFromLocalPath. Start: \(startTime), Duration: \(duration)")
            
            let livePhotoClient = LivePhotoClient(callback: {(success) in
                print("🍎 [LivePhoto] ФІНАЛЬНИЙ СТАТУС ВІДПРАВЛЕНО У FLUTTER: \(success)")
                result(success)
            })
            livePhotoClient.runLivePhotoConvertionFromLocalPath(rawURL: localPath, startTime: startTime, duration: duration)
            
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
                if #available(iOS 10.0, *) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
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
    
    public func runLivePhotoConvertionFromVideoURL(rawURL: String) {
        // ... (код завантаження з URL залишається без змін) ...
    }

    public func runLivePhotoConvertionFromLocalPath(rawURL: String, startTime: Double = 0.0, duration: Double = 0.0) {
        if let localPath = URL(string: rawURL) {
            let photos = PHPhotoLibrary.authorizationStatus()
            let pngPath = self.filePath(forKey: STILL_KEY)!
            let outputPath = self.filePath(forKey: MOV_KEY)!
            self.deleteFile(url: pngPath)
            self.deleteFile(url: outputPath)
            
            if photos == .notDetermined {
                print("🍎 [LivePhoto] Запит дозволу на доступ до фото...")
                PHPhotoLibrary.requestAuthorization({status in
                    if status == .authorized{
                        print("🍎 [LivePhoto] Дозвіл отримано!")
                        self.convertMp4ToMov(mp4Path: localPath, startTime: startTime, duration: duration)
                    } else {
                        print("🍎 [LivePhoto] ПОМИЛКА: Відмовлено в доступі до галереї!")
                        self.completedCallback(false)
                    }
                })
            } else if photos == .authorized || photos == .limited {
                print("🍎 [LivePhoto] Дозвіл на фото вже є. Переходимо до обрізки...")
                self.convertMp4ToMov(mp4Path: localPath, startTime: startTime, duration: duration)
            } else {
                print("🍎 [LivePhoto] ПОМИЛКА: Немає прав на галерею (status: \(photos.rawValue))")
                self.completedCallback(false)
            }
        } else {
            print("🍎 [LivePhoto] ПОМИЛКА: Невірний URL локального файлу")
            self.completedCallback(false)
        }
    }

    private func convertMp4ToMov(mp4Path: URL, startTime: Double = 0.0, duration: Double = 0.0) {
        print("🍎 [LivePhoto] КРОК 1: Базова обрізка по часу через AVAssetExportSession...")
        let avAsset = AVURLAsset(url: mp4Path)
        let preset = AVAssetExportPresetPassthrough
        let outFileType = AVFileType.mov
        
        if let exportSession = AVAssetExportSession(asset: avAsset, presetName: preset), let outputURL = self.filePath(forKey: MOV_KEY) {
            exportSession.outputFileType = outFileType
            exportSession.outputURL = outputURL
            self.deleteFile(url: outputURL)
            
            if startTime > 0 || duration > 0 {
                let start = CMTime(seconds: startTime, preferredTimescale: 600)
                let dur = duration > 0 ? CMTime(seconds: duration, preferredTimescale: 600) : avAsset.duration
                exportSession.timeRange = CMTimeRange(start: start, duration: dur)
            }
            
            exportSession.exportAsynchronously { () -> Void in
                switch exportSession.status {
                case .completed:
                    print("🍎 [LivePhoto] УСПІХ КРОК 1: Відео обрізано по часу.")
                    self.generateThumbnail(movURL: outputURL)
                    self.generateLivePhoto()
                case .failed:
                    print("🍎 [LivePhoto] ПОМИЛКА КРОК 1: AVAssetExportSession failed. Помилка: \(String(describing: exportSession.error?.localizedDescription))")
                    self.completedCallback(false)
                case .cancelled:
                    print("🍎 [LivePhoto] ПОМИЛКА КРОК 1: Експорт скасовано.")
                    self.completedCallback(false)
                default:
                    break
                }
            }
        } else {
            print("🍎 [LivePhoto] ПОМИЛКА: Не вдалося створити AVAssetExportSession")
            self.completedCallback(false)
        }
    }
    
    private func generateLivePhoto() {
        let pngPath = self.filePath(forKey: STILL_KEY)!
        let movPath = self.filePath(forKey: MOV_KEY)!
        if #available(iOS 9.1, *) {
            print("🍎 [LivePhoto] КРОК 3: Об'єднання картинки та відео у LivePhoto...")
            LivePhoto.generate(from: pngPath, videoURL: movPath, progress: { percent in }, completion: { livePhoto, resources in
                if let resources = resources {
                    print("🍎 [LivePhoto] УСПІХ КРОК 3: Ресурси LivePhoto згенеровано. Переходимо до збереження в галерею...")
                    LivePhoto.saveToLibrary(resources, completion: {(success) in
                        if success {
                            print("🍎 [LivePhoto] ФІНІШ: УСПІШНО ЗБЕРЕЖЕНО В ГАЛЕРЕЮ!")
                            self.completedCallback(true)
                        } else {
                            print("🍎 [LivePhoto] ПОМИЛКА ФІНІШ: Збереження в галерею провалилося.")
                            self.completedCallback(false)
                        }
                    })
                } else {
                    print("🍎 [LivePhoto] ПОМИЛКА КРОК 3: Не вдалося згенерувати ресурси LivePhoto.")
                    self.completedCallback(false)
                }
            })
        }
    }
    
    private func generateThumbnail(movURL: URL?) {
        print("🍎 [LivePhoto] КРОК 2: Генерація та масштабування обкладинки (Thumbnail)...")
        guard let movURL = movURL else {
            print("🍎 [LivePhoto] ПОМИЛКА: Немає movURL для обкладинки")
            return
        }
        let asset = AVURLAsset(url: movURL, options: nil)
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        let filePath = self.filePath(forKey: STILL_KEY)
        
        if let cgImage = try? imgGenerator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil) {
            let originalImage = UIImage(cgImage: cgImage)
            print("🍎 [LivePhoto] Оригінальний розмір обкладинки: \(originalImage.size)")
            
            let targetSize = CGSize(width: 1080, height: 1920)
            let widthRatio = targetSize.width / originalImage.size.width
            let heightRatio = targetSize.height / originalImage.size.height
            let scaleFactor = max(widthRatio, heightRatio)
            
            let scaledSize = CGSize(width: originalImage.size.width * scaleFactor, height: originalImage.size.height * scaleFactor)
            let origin = CGPoint(x: (targetSize.width - scaledSize.width) / 2.0, y: (targetSize.height - scaledSize.height) / 2.0)
            
            UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
            originalImage.draw(in: CGRect(origin: origin, size: scaledSize))
            let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            if let finalImage = scaledImage, let data = finalImage.pngData() {
                print("🍎 [LivePhoto] Обкладинку відмасштабовано до: \(finalImage.size)")
                if let filePath = filePath {
                    do {
                        self.deleteFile(url: filePath)
                        try data.write(to: filePath, options: .atomic)
                        print("🍎 [LivePhoto] УСПІХ КРОК 2: Обкладинку збережено локально.")
                    } catch let err {
                        print("🍎 [LivePhoto] ПОМИЛКА КРОК 2: Не вдалося зберегти png: \(err.localizedDescription)")
                    }
                }
            }
        } else {
            print("🍎 [LivePhoto] ПОМИЛКА КРОК 2: copyCGImage провалився.")
        }
    }
    
    // ... (допоміжні функції downloadAsync, filePath, copy, deleteFile залишаються без змін) ...
    private func downloadAsync(url: URL, to localUrl: URL?, completion: @escaping (_: URL) -> ()) { /* ... */ }
    private func filePath(forKey key: String) -> URL? {
        let fileManager = FileManager.default
        guard let documentURL = fileManager.urls(for: .documentDirectory, in: FileManager.SearchPathDomainMask.userDomainMask).first else { return nil }
        return documentURL.appendingPathComponent(key + "." + key)
    }
    private func copy(_ atPathName: URL, toPathName: URL) { /* ... */ }
    private func deleteFile(url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(atPath: url.path)
        }
    }
}

class LivePhoto {
    typealias LivePhotoResources = (pairedImage: URL, pairedVideo: URL)
    
    public class func saveToLibrary(_ resources: LivePhotoResources, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            if #available(iOS 9.1, *) {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                creationRequest.addResource(with: PHAssetResourceType.pairedVideo, fileURL: resources.pairedVideo, options: options)
                creationRequest.addResource(with: PHAssetResourceType.photo, fileURL: resources.pairedImage, options: options)
            }
        }, completionHandler: { (success, error) in
            if let error = error {
                print("🍎 [LivePhoto] PHPhotoLibrary ЗБІЙ: \(error.localizedDescription)")
            }
            completion(success)
        })
    }
    
    private static let shared = LivePhoto()
    private static let queue = DispatchQueue(label: "com.limit-point.LivePhotoQueue", attributes: .concurrent)
    lazy private var cacheDirectory: URL? = {
        if let cacheDirectoryURL = try?
