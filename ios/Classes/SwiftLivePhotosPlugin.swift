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

        // Створюємо новий екземпляр генератора для кожної задачі
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
    
    // ВАЖЛИВО: Сильні посилання на об'єкти, щоб уникнути EXC_BAD_ACCESS (Memory Crash)
    var activeAsset: AVAsset?
    var activeReader: AVAssetReader?
    var activeWriter: AVAssetWriter?

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
        self.activeAsset = AVURLAsset(url: sourceURL)
        guard let asset = self.activeAsset else { completion(false); return }
        
        let videoDuration = asset.duration.seconds
        let safeStart = min(max(startTime, 0), videoDuration)
        let safeDuration = min(duration, max(0, videoDuration - safeStart))
        
        guard safeDuration > 0.1 else {
            NSLog("🍎 [LivePhotos] Error: Video duration too short (\(safeDuration)s)")
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
        
        // MakerNote (Apple Metadata)
        let metadata = [kCGImagePropertyMakerAppleDictionary as String: ["17": assetID]]
        CGImageDestinationAddImage(dest, cgImg, metadata as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private func writeVideoWithMetadata(asset: AVAsset, to url: URL, startTime: Double, duration: Double, completion: @escaping (Bool) -> Void) {
        do {
            self.activeReader = try AVAssetReader(asset: asset)
            self.activeWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            
            guard let reader = self.activeReader, let writer = self.activeWriter else {
                completion(false); return
            }
            
            writer.shouldOptimizeForNetworkUse = true

            let start = CMTime(seconds: startTime, preferredTimescale: 600)
            let dur = CMTime(seconds: duration, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: dur)

            // 1. ВІДЕО ТРЕК (Passthrough)
            guard let vTrack = asset.tracks(withMediaType: .video).first else { completion(false); return }
            let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            vIn.transform = vTrack.preferredTransform
            if writer.canAdd(vIn) { writer.add(vIn) }
            if reader.canAdd(vOut) { reader.add(vOut) }

            // 2. АУДІО ТРЕК (Копіюємо або генеруємо порожній для сумісності з PosterBoard)
            var aIn: AVAssetWriterInput?
            var aOut: AVAssetReaderTrackOutput?
            let audioTracks = asset.tracks(withMediaType: .audio)
            
            if let aTrack = audioTracks.first {
                // Відео має звук: копіюємо
                aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                if let aIn = aIn, writer.canAdd(aIn) { writer.add(aIn) }
                if let aOut = aOut, reader.canAdd(aOut) { reader.add(aOut) }
            } else {
                // Відео німе (від ШІ): генеруємо порожній трек для PosterBoard!
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
            guard writer.startWriting(), reader.startReading() else {
                completion(false); return
            }
            writer.startSession(atSourceTime: start)

            // Ін'єкція 0xFF (Live Photo Anchor)
            if mIn.isReadyForMoreMediaData {
                let mItem = AVMutableMetadataItem()
                mItem.key = "com.apple.quicktime.still-image-time" as NSString
                mItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
                mItem.value = NSNumber(value: Int8(-1))
                mItem.dataType = "com.apple.metadata.datatype.int8"
                adaptor.append(AVTimedMetadataGroup(items: [mItem], timeRange: CMTimeRange(start: start, duration: CMTime(value: 1, timescale: 600))))
            }

            let group = DispatchGroup()
            
            // ВАЖЛИВО: Безпечні черги
            let videoQueue = DispatchQueue(label: "com.livephoto.videoQueue")
            var videoDone = false
            
            group.enter()
            vIn.requestMediaDataWhenReady(on: videoQueue) {
                while vIn.isReadyForMoreMediaData {
                    // Захист від читання після збою
                    guard reader.status == .reading else {
                        vIn.markAsFinished()
                        if !videoDone { videoDone = true; group.leave() }
                        break
                    }
                    
                    if let buf = vOut.copyNextSampleBuffer() {
                        vIn.append(buf)
                    } else {
                        vIn.markAsFinished()
                        if !videoDone { videoDone = true; group.leave() }
                        break
                    }
                }
            }

            // Обробка аудіо
            if let aIn = aIn {
                if let aOut = aOut {
                    // Є реальний звук, копіюємо його
                    let audioQueue = DispatchQueue(label: "com.livephoto.audioQueue")
                    var audioDone = false
                    group.enter()
                    aIn.requestMediaDataWhenReady(on: audioQueue) {
                        while aIn.isReadyForMoreMediaData {
                            guard reader.status == .reading else {
                                aIn.markAsFinished()
                                if !audioDone { audioDone = true; group.leave() }
                                break
                            }
                            if let buf = aOut.copyNextSampleBuffer() {
                                aIn.append(buf)
                            } else {
                                aIn.markAsFinished()
                                if !audioDone { audioDone = true; group.leave() }
                                break
                            }
                        }
                    }
                } else {
                    // Синтезований звук: просто позначаємо як завершений, щоб Writer не чекав (уникнення таймауту)
                    aIn.markAsFinished()
                }
            }

            group.notify(queue: .main) {
                mIn.markAsFinished()
                writer.finishWriting {
                    // Очищаємо пам'ять тільки після повного завершення запису!
                    self.activeReader = nil
                    self.activeWriter = nil
                    self.activeAsset = nil
                    
                    if writer.status == .completed {
                        completion(true)
                    } else {
                        NSLog("🍎 [LivePhotos] Writer Error: \(String(describing: writer.error))")
                        completion(false)
                    }
                }
            }

        } catch {
            NSLog("🍎 [LivePhotos] Exception: \(error.localizedDescription)")
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
