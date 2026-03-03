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
                NSLog("🍎 [LivePhoto] ПОМИЛКА: Не передано localPath!")
                result(false)
                return
            }
            let startTime = args["startTime"] as? Double ?? 0.0
            let duration = args["duration"] as? Double ?? 0.0
            
            NSLog("🍎 [LivePhoto] СТАРТ: Запит generateFromLocalPath. Start: %f, Duration: %f", startTime, duration)
            
            let livePhotoClient = LivePhotoClient(callback: {(success) in
                NSLog("🍎 [LivePhoto] ФІНАЛЬНИЙ СТАТУС У FLUTTER: %@", success ? "TRUE" : "FALSE")
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
        if let videoURL = URL(string: rawURL) {
            let photos = PHPhotoLibrary.authorizationStatus()
            if photos == .notDetermined {
                PHPhotoLibrary.requestAuthorization({status in
                    if status == .authorized{
                        self.downloadAsync(url: videoURL, to: self.filePath(forKey: self.SRC_KEY)) { downloadedUrl in
                            self.convertMp4ToMov(mp4Path: downloadedUrl)
                        }
                    } else {
                        self.completedCallback(false)
                    }
                })
            } else {
                self.downloadAsync(url: videoURL, to: self.filePath(forKey: self.SRC_KEY)) { downloadedUrl in
                    self.convertMp4ToMov(mp4Path: downloadedUrl)
                }
            }
        }
    }

    public func runLivePhotoConvertionFromLocalPath(rawURL: String, startTime: Double = 0.0, duration: Double = 0.0) {
        if let localPath = URL(string: rawURL) {
            let photos = PHPhotoLibrary.authorizationStatus()
            let pngPath = self.filePath(forKey: STILL_KEY)!
            let outputPath = self.filePath(forKey: MOV_KEY)!
            self.deleteFile(url: pngPath)
            self.deleteFile(url: outputPath)
            
            if photos == .notDetermined {
                NSLog("🍎 [LivePhoto] Запит дозволу на фото...")
                PHPhotoLibrary.requestAuthorization({status in
                    if status == .authorized{
                        NSLog("🍎 [LivePhoto] Дозвіл отримано!")
                        self.convertMp4ToMov(mp4Path: localPath, startTime: startTime, duration: duration)
                    } else {
                        NSLog("🍎 [LivePhoto] ПОМИЛКА: Відмовлено в доступі до галереї!")
                        self.completedCallback(false)
                    }
                })
            } else if photos == .authorized || photos == .limited {
                NSLog("🍎 [LivePhoto] Дозвіл є. Переходимо до обрізки...")
                self.convertMp4ToMov(mp4Path: localPath, startTime: startTime, duration: duration)
            } else {
                NSLog("🍎 [LivePhoto] ПОМИЛКА: Немає прав на галерею")
                self.completedCallback(false)
            }
        } else {
            self.completedCallback(false)
        }
    }

    private func convertMp4ToMov(mp4Path: URL, startTime: Double = 0.0, duration: Double = 0.0) {
        NSLog("🍎 [LivePhoto] КРОК 1: Базова обрізка по часу...")
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
                    NSLog("🍎 [LivePhoto] УСПІХ КРОК 1: Відео обрізано.")
                    self.generateThumbnail(movURL: outputURL)
                    self.generateLivePhoto()
                case .failed:
                    NSLog("🍎 [LivePhoto] ПОМИЛКА КРОК 1: Експорт провалився.")
                    self.completedCallback(false)
                case .cancelled:
                    self.completedCallback(false)
                default:
                    break
                }
            }
        } else {
            self.completedCallback(false)
        }
    }
    
    private func generateLivePhoto() {
        let pngPath = self.filePath(forKey: STILL_KEY)!
        let movPath = self.filePath(forKey: MOV_KEY)!
        if #available(iOS 9.1, *) {
            NSLog("🍎 [LivePhoto] КРОК 3: Об'єднання в LivePhoto...")
            LivePhoto.generate(from: pngPath, videoURL: movPath, progress: { percent in }, completion: { livePhoto, resources in
                if let resources = resources {
                    NSLog("🍎 [LivePhoto] Збереження в галерею...")
                    LivePhoto.saveToLibrary(resources, completion: {(success) in
                        if success {
                            NSLog("🍎 [LivePhoto] ФІНІШ: УСПІШНО ЗБЕРЕЖЕНО!")
                            self.completedCallback(true)
                        } else {
                            NSLog("🍎 [LivePhoto] ПОМИЛКА ФІНІШ.")
                            self.completedCallback(false)
                        }
                    })
                } else {
                    self.completedCallback(false)
                }
            })
        }
    }
    
    private func generateThumbnail(movURL: URL?) {
        NSLog("🍎 [LivePhoto] КРОК 2: Генерація та масштабування обкладинки...")
        guard let movURL = movURL else { return }
        let asset = AVURLAsset(url: movURL, options: nil)
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        let filePath = self.filePath(forKey: STILL_KEY)
        
        if let cgImage = try? imgGenerator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil) {
            let originalImage = UIImage(cgImage: cgImage)
            NSLog("🍎 [LivePhoto] Оригінальний розмір: %@", NSCoder.string(for: originalImage.size))
            
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
                NSLog("🍎 [LivePhoto] Відмасштабовано до: %@", NSCoder.string(for: finalImage.size))
                if let filePath = filePath {
                    do {
                        self.deleteFile(url: filePath)
                        try data.write(to: filePath, options: .atomic)
                    } catch {
                        NSLog("🍎 [LivePhoto] ПОМИЛКА збереження png")
                    }
                }
            }
        }
    }
    
    private func downloadAsync(url: URL, to localUrl: URL?, completion: @escaping (_: URL) -> ()) {
        let task = URLSession.shared.downloadTask(with: URLRequest(url: url)) {(tempLocalUrl, response, error) in
            if let tempLocalUrl = tempLocalUrl, let localUrl = localUrl, error == nil {
                do {
                    self.deleteFile(url: localUrl)
                    try FileManager.default.copyItem(at: tempLocalUrl, to: localUrl)
                    completion(localUrl)
                } catch { }
            }
        }
        task.resume()
    }
    
    private func filePath(forKey key: String) -> URL? {
        let fileManager = FileManager.default
        guard let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documentURL.appendingPathComponent(key + "." + key)
    }
    
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
                creationRequest.addResource(with: .pairedVideo, fileURL: resources.pairedVideo, options: options)
                creationRequest.addResource(with: .photo, fileURL: resources.pairedImage, options: options)
            }
        }, completionHandler: { (success, error) in
            completion(success)
        })
    }
    
    private static let shared = LivePhoto()
    private static let queue = DispatchQueue(label: "com.limit-point.LivePhotoQueue", attributes: .concurrent)
    lazy private var cacheDirectory: URL? = {
        if let cacheDirectoryURL = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let fullDirectory = cacheDirectoryURL.appendingPathComponent("com.limit-point.LivePhoto", isDirectory: true)
            if !FileManager.default.fileExists(atPath: fullDirectory.absoluteString) {
                try? FileManager.default.createDirectory(at: fullDirectory, withIntermediateDirectories: true, attributes: nil)
            }
            return fullDirectory
        }
        return nil
    }()
    
    deinit { clearCache() }
    
    private func clearCache() {
        if let cacheDirectory = cacheDirectory {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }
    
    @available(iOS 9.1, *)
    public class func generate(from imageURL: URL?, videoURL: URL, progress: @escaping (CGFloat) -> Void, completion: @escaping (PHLivePhoto?, LivePhotoResources?) -> Void) {
        queue.async {
            shared.generate(from: imageURL, videoURL: videoURL, progress: progress, completion: completion)
        }
    }
    
    @available(iOS 9.1, *)
    private func generate(from imageURL: URL?, videoURL: URL, progress: @escaping (CGFloat) -> Void, completion: @escaping (PHLivePhoto?, LivePhotoResources?) -> Void) {
        guard let cacheDirectory = cacheDirectory else {
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }
        let assetIdentifier = UUID().uuidString
        guard let imageURL = imageURL, let pairedImageURL = addAssetID(assetIdentifier, toImage: imageURL, saveTo: cacheDirectory.appendingPathComponent(assetIdentifier).appendingPathExtension("jpg")) else {
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }
        
        NSLog("🍎 [LivePhoto] Транскодування відео (1080x1920 + HEVC)...")
        addAssetID(assetIdentifier, toVideo: videoURL, saveTo: cacheDirectory.appendingPathComponent(assetIdentifier).appendingPathExtension("mov"), progress: progress) { (_videoURL) in
            if let pairedVideoURL = _videoURL {
                _ = PHLivePhoto.request(withResourceFileURLs: [pairedVideoURL, pairedImageURL], placeholderImage: nil, targetSize: CGSize.zero, contentMode: .aspectFit, resultHandler: { (livePhoto: PHLivePhoto?, info: [AnyHashable : Any]) -> Void in
                    if let isDegraded = info[PHLivePhotoInfoIsDegradedKey] as? Bool, isDegraded { return }
                    DispatchQueue.main.async {
                        completion(livePhoto, (pairedImageURL, pairedVideoURL))
                    }
                })
            } else {
                DispatchQueue.main.async { completion(nil, nil) }
            }
        }
    }
    
    func addAssetID(_ assetIdentifier: String, toImage imageURL: URL, saveTo destinationURL: URL) -> URL? {
        guard let imageDestination = CGImageDestinationCreateWithURL(destinationURL as CFURL, kUTTypeJPEG, 1, nil),
            let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
            var imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [AnyHashable : Any] else { return nil }
        let assetIdentifierInfo = ["17" : assetIdentifier]
        imageProperties[kCGImagePropertyMakerAppleDictionary] = assetIdentifierInfo
        CGImageDestinationAddImageFromSource(imageDestination, imageSource, 0, imageProperties as CFDictionary)
        CGImageDestinationFinalize(imageDestination)
        return destinationURL
    }
    
    var videoReader: AVAssetReader?
    var assetWriter: AVAssetWriter?
    
    func addAssetID(_ assetIdentifier: String, toVideo videoURL: URL, saveTo destinationURL: URL, progress: @escaping (CGFloat) -> Void, completion: @escaping (URL?) -> Void) {
        
        let videoAsset = AVURLAsset(url: videoURL)
        let frameCount = videoAsset.countFrames(exact: false)
        guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
            completion(nil)
            return
        }
        
        do {
            assetWriter = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
            videoReader = try AVAssetReader(asset: videoAsset)
            let videoReaderSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA as UInt32)]
            let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
            videoReader?.add(videoReaderOutput)
            
            let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6000000,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
                ]
            ])
            videoWriterInput.transform = videoTrack.preferredTransform
            videoWriterInput.expectsMediaDataInRealTime = true
            assetWriter?.add(videoWriterInput)
            
            let assetIdentifierMetadata = metadataForAssetID(assetIdentifier)
            let stillImageTimeMetadataAdapter = createMetadataAdaptorForStillImageTime()
            let livePhotoAutoMetadataAdapter = createMetadataAdaptorForLivePhotoAuto()
            assetWriter?.metadata = [assetIdentifierMetadata]
            assetWriter?.add(stillImageTimeMetadataAdapter.assetWriterInput)
            assetWriter?.add(livePhotoAutoMetadataAdapter.assetWriterInput)
            
            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: CMTime.zero)
            
            let _stillImagePercent: Float = 0.5
            stillImageTimeMetadataAdapter.append(AVTimedMetadataGroup(items: [metadataItemForStillImageTime()],timeRange: videoAsset.makeStillImageTimeRange(percent: _stillImagePercent, inFrameCount: frameCount)))
            livePhotoAutoMetadataAdapter.append(AVTimedMetadataGroup(items: [metadataItemForLivePhotoAuto()], timeRange: videoAsset.makeStillImageTimeRange(percent: _stillImagePercent, inFrameCount: frameCount)))
            
            var writingVideoFinished = false
            var currentFrameCount = 0
            
            func didCompleteWriting() {
                guard writingVideoFinished else { return }
                assetWriter?.finishWriting {
                    if self.assetWriter?.status == .completed {
                        completion(destinationURL)
                    } else {
                        completion(nil)
                    }
                }
            }
            
            if videoReader?.startReading() ?? false {
                videoWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoWriterInputQueue")) {
                    while videoWriterInput.isReadyForMoreMediaData {
                        if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer()  {
                            currentFrameCount += 1
                            let percent:CGFloat = CGFloat(currentFrameCount)/CGFloat(max(frameCount, 1))
                            progress(percent)
                            if !videoWriterInput.append(sampleBuffer) {
                                self.videoReader?.cancelReading()
                            }
                        } else {
                            videoWriterInput.markAsFinished()
                            writingVideoFinished = true
                            didCompleteWriting()
                        }
                    }
                }
            } else {
                writingVideoFinished = true
                didCompleteWriting()
            }
        } catch {
            completion(nil)
        }
    }
    
    private func metadataForAssetID(_ assetIdentifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.content.identifier" as (NSCopying & NSObjectProtocol)?
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.value = assetIdentifier as (NSCopying & NSObjectProtocol)?
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }
    
    private func createMetadataAdaptorForStillImageTime() -> AVAssetWriterInputMetadataAdaptor {
        let spec : NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString: "com.apple.metadata.datatype.int8"
        ]
        var desc : CMFormatDescription? = nil
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc)
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }
    
    private func metadataItemForStillImageTime() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as (NSCopying & NSObjectProtocol)?
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.value = 0 as (NSCopying & NSObjectProtocol)?
        item.dataType = "com.apple.metadata.datatype.int8"
        return item
    }

    private func createMetadataAdaptorForLivePhotoAuto() -> AVAssetWriterInputMetadataAdaptor {
        let spec: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString: "mdta/com.apple.quicktime.live-photo.auto",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString: "com.apple.metadata.datatype.int8"
        ]
        var desc: CMFormatDescription? = nil
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc)
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    private func metadataItemForLivePhotoAuto() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.live-photo.auto" as (NSCopying & NSObjectProtocol)?
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.value = 1 as (NSCopying & NSObjectProtocol)?
        item.dataType = "com.apple.metadata.datatype.int8"
        return item
    }
}

fileprivate extension AVAsset {
    func countFrames(exact:Bool) -> Int {
        var frameCount = 0
        if let videoReader = try? AVAssetReader(asset: self), let videoTrack = self.tracks(withMediaType: .video).first {
            frameCount = Int(CMTimeGetSeconds(self.duration) * Float64(videoTrack.nominalFrameRate))
        }
        return frameCount
    }
    func makeStillImageTimeRange(percent:Float, inFrameCount:Int = 0) -> CMTimeRange {
        var time = self.duration
        var frameCount = inFrameCount
        if frameCount == 0 { frameCount = self.countFrames(exact: true) }
        let frameDuration = Int64(Float(time.value) / Float(max(frameCount, 1)))
        time.value = Int64(Float(time.value) * percent)
        return CMTimeRangeMake(start: time, duration: CMTimeMake(value: frameDuration, timescale: time.timescale))
    }
}
