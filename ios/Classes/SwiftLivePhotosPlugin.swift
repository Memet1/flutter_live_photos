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
        guard let localPath = args["localPath"] as? String else { result(false); return }
        let startTime = args["startTime"] as? Double ?? 0.0
        let duration = args["duration"] as? Double ?? 0.0

        let generator = LivePhotoGenerator()
        generator.generate(videoPath: localPath, startTime: startTime, duration: duration) { success in
            result(success)
        }
    } else {
        result(FlutterMethodNotImplemented)
    }
  }
}

class LivePhotoGenerator {
    let assetID = UUID().uuidString

    func generate(videoPath: String, startTime: Double, duration: Double, completion: @escaping (Bool) -> Void) {
        let sourceURL = URL(fileURLWithPath: videoPath)
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                NSLog("🍎 [LivePhotos] Error: No Photo Library Permission")
                completion(false); return
            }
            self.createAssets(sourceURL: sourceURL, startTime: startTime, duration: duration, completion: completion)
        }
    }

    private func createAssets(sourceURL: URL, startTime: Double, duration: Double, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: sourceURL)
        
        let videoDuration = asset.duration.seconds
        let safeStart = min(startTime, videoDuration)
        let safeDuration = min(duration, max(0, videoDuration - safeStart))
        
        guard safeDuration > 0.1 else {
            NSLog("🍎 [LivePhotos] Error: Video duration too short")
            completion(false); return
        }

        guard let imgURL = generateImage(asset: asset, at: safeStart) else { 
            completion(false); return 
        }
        
        let movURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(assetID).mov")
        try? FileManager.default.removeItem(at: movURL)

        writeVideoWithMetadata(asset: asset, to: movURL, startTime: safeStart, duration: safeDuration) { success in
            if success {
                self.save(img: imgURL, vid: movURL, completion: completion)
            } else { completion(false) }
        }
    }

    private func generateImage(asset: AVAsset, at time: Double) -> URL? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        guard let cgImg = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { return nil }
        
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(assetID).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, kUTTypeJPEG, 1, nil) else { return nil }
        
        // MakerNote для зв'язки з відео
        let metadata = [kCGImagePropertyMakerAppleDictionary as String: ["17": assetID]]
        CGImageDestinationAddImage(dest, cgImg, metadata as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private func writeVideoWithMetadata(asset: AVAsset, to url: URL, startTime: Double, duration: Double, completion: @escaping (Bool) -> Void) {
        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.shouldOptimizeForNetworkUse = true

            let start = CMTime(seconds: startTime, preferredTimescale: 600)
            let dur = CMTime(seconds: duration, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: dur)

            // 1. ВІДЕО ТРЕК
            guard let vTrack = asset.tracks(withMediaType: .video).first else { completion(false); return }
            let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            vIn.transform = vTrack.preferredTransform
            if writer.canAdd(vIn) { writer.add(vIn) }
            if reader.canAdd(vOut) { reader.add(vOut) }

            // 2. АУДІО ТРЕК (Синтез тиші, якщо звуку немає)
            var aIn: AVAssetWriterInput?
            var aOut: AVAssetReaderTrackOutput?
            let audioTracks = asset.tracks(withMediaType: .audio)
            
            if !audioTracks.isEmpty {
                aOut = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: nil)
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                if let aIn = aIn, writer.canAdd(aIn) { writer.add(aIn) }
                if let aOut = aOut, reader.canAdd(aOut) { reader.add(aOut) }
            } else {
                // ВІДЕО ВІД ШІ: Створюємо порожній soun атом для валідації PosterBoard!
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 64000
                ]
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aIn?.expectsMediaDataInRealTime = false
                if let aIn = aIn, writer.canAdd(aIn) { writer.add(aIn) }
            }

            // 3. МЕТАДАНІ ТРЕК
            let spec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString: "com.apple.metadata.datatype.int8"
            ]
            var desc: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: nil, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc)
            let mIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
            let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mIn)
            if writer.canAdd(mIn) { writer.add(mIn) }

            // Глобальний UUID
            let idItem = AVMutableMetadataItem()
            idItem.key = "com.apple.quicktime.content.identifier" as NSString
            idItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            idItem.value = assetID as NSString
            idItem.dataType = "com.apple.metadata.datatype.UTF-8"
            writer.metadata = [idItem]

            // СТАРТ ЗАПИСУ
            guard writer.startWriting() else { completion(false); return }
            guard reader.startReading() else { completion(false); return }
            writer.startSession(atSourceTime: start)

            // Ін'єкція 0xFF (Синхронізація)
            let mItem = AVMutableMetadataItem()
            mItem.key = "com.apple.quicktime.still-image-time" as NSString
            mItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            mItem.value = NSNumber(value: Int8(-1))
            mItem.dataType = "com.apple.metadata.datatype.int8"
            adaptor.append(AVTimedMetadataGroup(items: [mItem], timeRange: CMTimeRange(start: start, duration: CMTime(value: 1, timescale: 600))))

            // БЕЗПЕЧНИЙ СЕКВЕНТАЛЬНИЙ ЦИКЛ (Anti-Crash)
            let queue = DispatchQueue(label: "com.livephoto.muxing", qos: .userInitiated)
            queue.async {
                var videoDone = false
                var audioDone = (aOut == nil) // Якщо звуку немає, читати нічого
                
                while !videoDone || !audioDone {
                    // Захист від EXC_BAD_ACCESS: перевірка статусу перед читанням!
                    if reader.status == .failed || reader.status == .cancelled {
                        NSLog("🍎 [LivePhotos] Reader Failed: \(String(describing: reader.error))")
                        break
                    }
                    
                    var appended = false
                    
                    if !videoDone, vIn.isReadyForMoreMediaData {
                        if let buf = vOut.copyNextSampleBuffer() {
                            vIn.append(buf)
                            appended = true
                        } else {
                            vIn.markAsFinished()
                            videoDone = true
                        }
                    }
                    
                    if !audioDone, let aIn = aIn, let aOut = aOut, aIn.isReadyForMoreMediaData {
                        if let buf = aOut.copyNextSampleBuffer() {
                            aIn.append(buf)
                            appended = true
                        } else {
                            aIn.markAsFinished()
                            audioDone = true
                        }
                    }
                    
                    if !appended {
                        usleep(1000) // Мікро-пауза для стабільності CPU
                    }
                }
                
                // Фіналізація всіх треків
                if !videoDone { vIn.markAsFinished() }
                if audioTracks.isEmpty {
                    aIn?.markAsFinished() // Зберігаємо порожній аудіотрек
                } else if !audioDone {
                    aIn?.markAsFinished()
                }
                mIn.markAsFinished()
                
                writer.finishWriting {
                    DispatchQueue.main.async {
                        completion(writer.status == .completed)
                    }
                }
            }
        } catch {
            completion(false)
        }
    }

    private func save(img: URL, vid: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: img, options: nil)
            req.addResource(with: .pairedVideo, fileURL: vid, options: nil)
        }) { success, err in
            if let e = err { NSLog("🍎 [LivePhotos] Save Error: \(e.localizedDescription)") }
            completion(success)
        }
    }
}
