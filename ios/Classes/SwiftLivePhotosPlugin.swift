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
                    NSLog("🍎 [LivePhoto] Error: localPath is missing")
                    result(false)
                    return
                }
                let startTime = args["startTime"] as? Double ?? 0.0
                let duration = args["duration"] as? Double ?? 0.0
                
                NSLog("🍎 [LivePhoto] Start Request: Start Time %f, Duration %f", startTime, duration)
                
                let livePhotoClient = LivePhotoClient(callback: {(success) in
                    NSLog("🍎 [LivePhoto] Final Status to Flutter: %@", success ? "TRUE" : "FALSE")
                    result(success)
                })
                livePhotoClient.runLivePhotoConvertionFromLocalPath(rawURL: localPath, startTime: startTime, duration: duration)
                
            default:
                result(FlutterMethodNotImplemented)
        }
    }
}

class LivePhotoClient {
    let completedCallback: ((Bool) -> Void)
    
    init(callback: @escaping (Bool) -> Void) {
        completedCallback = callback
    }

    public func runLivePhotoConvertionFromLocalPath(rawURL: String, startTime: Double = 0.0, duration: Double = 0.0) {
        let localURL = URL(fileURLWithPath: rawURL) // БЕЗПЕЧНИЙ ПАРСИНГ ШЛЯХУ
        
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized || status == .limited {
                self.processVideo(at: localURL, startTime: startTime, duration: duration)
            } else {
                NSLog("🍎 [LivePhoto] Error: Photo Library access denied")
                self.completedCallback(false)
            }
        }
    }

    private func processVideo(at url: URL, startTime: Double, duration: Double) {
        NSLog("🍎 [LivePhoto] Step 1: Processing Video & Thumbnail...")
        let asset = AVURLAsset(url: url)
        
        // 1. Отримуємо робочі шляхи
        guard let jpgPath = self.fileURL(forKey: "output", ext: "jpg"),
              let movPath = self.fileURL(forKey: "output", ext: "mov") else {
            self.completedCallback(false)
            return
        }
        
        self.deleteFile(url: jpgPath)
        self.deleteFile(url: movPath)
        
        // 2. Генеруємо превью 1080x1920
        self.generateThumbnail(from: asset, at: startTime, saveTo: jpgPath)
        
        // 3. Обрізаємо і перекодовуємо відео в 1080x1920 HEVC
        LivePhoto.processAndAddAssetID(toVideo: url, saveTo: movPath, startTime: startTime, duration: duration) { success in
            if success {
                NSLog("🍎 [LivePhoto] Step 2: Video processed successfully.")
                self.generateLivePhoto(jpgPath: jpgPath, movPath: movPath)
            } else {
                NSLog("🍎 [LivePhoto] Error: Failed to process video")
                self.completedCallback(false)
            }
        }
    }

    private func generateThumbnail(from asset: AVAsset, at time: Double, saveTo path: URL) {
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
            
            if let data = finalImage?.jpegData(compressionQuality: 0.9) {
                try? data.write(to: path)
                NSLog("🍎 [LivePhoto] Thumbnail generated at 1080x1920")
            }
        }
    }

    private func generateLivePhoto(jpgPath: URL, movPath: URL) {
        NSLog("🍎 [LivePhoto] Step 3: Generating Resources...")
        LivePhoto.generate(from: jpgPath, videoURL: movPath) { lp, resources in
            if let res = resources {
                NSLog("🍎 [LivePhoto] Step 4: Saving to Library...")
                LivePhoto.saveToLibrary(res) { success in
                    self.completedCallback(success)
                }
            } else {
                NSLog("🍎 [LivePhoto] Error: Failed to create LivePhoto resources")
                self.completedCallback(false)
            }
        }
    }

    private func fileURL(forKey key: String, ext: String) -> URL? {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("\(key).\(ext)")
    }
    
    private func deleteFile(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

class LivePhoto {
    typealias LivePhotoResources = (pairedImage: URL, pairedVideo: URL)

    static func generate(from imageURL: URL, videoURL: URL, completion: @escaping (PHLivePhoto?, LivePhotoResources?) -> Void) {
        let assetID = UUID().uuidString
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("lp_final")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let outImg = cacheDir.appendingPathComponent("\(assetID).jpg")
        let outVid = cacheDir.appendingPathComponent("\(assetID).mov")
        
        try? FileManager.default.removeItem(at: outImg)
        try? FileManager.default.removeItem(at: outVid)
        
        guard let _ = LivePhoto.addAssetID(assetID, toImage: imageURL, saveTo: outImg) else {
            completion(nil, nil); return
        }
        
        // ВАЖЛИВО: Оскільки відео вже перекодовано, ми просто додаємо AssetID (копіюємо)
        LivePhoto.addAssetIDToExistingVideo(assetID, toVideo: videoURL, saveTo: outVid) { success in
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
        let props = [kCGImagePropertyMakerAppleDictionary as String: ["17": assetID]]
        CGImageDestinationAddImageFromSource(destination, source, 0, props as CFDictionary)
        return CGImageDestinationFinalize(destination) ? saveTo : nil
    }

    // МЕТОД 1: Перекодування + Обрізка (викликається першим)
    static func processAndAddAssetID(toVideo url: URL, saveTo: URL, startTime: Double, duration: Double, completion: @escaping (Bool) -> Void) {
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
            input.expectsMediaDataInRealTime = false // БЕЗПЕКА ДЛЯ ПАМ'ЯТІ
            
            writer.add(input)
            let reader = try AVAssetReader(asset: asset)
            
            // Встановлення часу обрізки для Reader
            if startTime > 0 || duration > 0 {
                let start = CMTime(seconds: startTime, preferredTimescale: 600)
                let dur = duration > 0 ? CMTime(seconds: duration, preferredTimescale: 600) : asset.duration
                reader.timeRange = CMTimeRange(start: start, duration: dur)
            }
            
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            
            writer.startWriting()
            reader.startReading()
            writer.startSession(atSourceTime: .zero)
            
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "video_writer_queue")) {
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
    
    // МЕТОД 2: Швидке додавання метаданих (без перекодування)
    static func addAssetIDToExistingVideo(_ assetID: String, toVideo url: URL, saveTo: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { completion(false); return }
        
        do {
            let writer = try AVAssetWriter(outputURL: saveTo, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil) // Passthrough
            input.transform = videoTrack.preferredTransform
            input.expectsMediaDataInRealTime = false
            
            let metadataItem = AVMutableMetadataItem()
            metadataItem.key = "com.apple.quicktime.content.identifier" as (NSCopying & NSObjectProtocol)?
            metadataItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            metadataItem.value = assetID as (NSCopying & NSObjectProtocol)?
            metadataItem.dataType = "com.apple.metadata.datatype.UTF-8"
            writer.metadata = [metadataItem]
            
            writer.add(input)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            reader.add(output)
            
            writer.startWriting()
            reader.startReading()
            writer.startSession(atSourceTime: .zero)
            
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "metadata_writer_queue")) {
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
        }, completionHandler: { success, error in
            if !success, let err = error {
                NSLog("🍎 [LivePhoto] Gallery Save Error: %@", err.localizedDescription)
            }
            completion(success)
        })
    }
}
