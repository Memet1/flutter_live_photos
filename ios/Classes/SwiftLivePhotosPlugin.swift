import Flutter
import UIKit
import Foundation
import AVFoundation
import Photos
import MobileCoreServices

public class SwiftLivePhotosPlusPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "live_photos_plus", binaryMessenger: registrar.messenger())
    let instance = SwiftLivePhotosPlusPlugin()
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

        NSLog("🍎 [LivePhotosPlus] Init: Processing MP4 -> MOV. start=\(startTime), dur=\(duration)")

        let client = LivePhotoGenerator()
        client.generate(videoPath: localPath, startTime: startTime, duration: duration) { success in
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
                NSLog("🍎 [LivePhotosPlus] Помилка: Немає доступу до галереї")
                completion(false)
                return
            }
            self.processAsset(sourceURL: sourceURL, startTime: startTime, duration: duration, completion: completion)
        }
    }

    private func processAsset(sourceURL: URL, startTime: Double, duration: Double, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: sourceURL)

        // 1. Генерація статичного фото (HEIC/JPEG) з Maker Note UUID
        guard let jpgURL = generateImage(from: asset, at: startTime) else {
            completion(false)
            return
        }

        let movURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(assetID).mov")
        try? FileManager.default.removeItem(at: movURL)

        // 2. Збірка правильного QuickTime контейнера (moov + mdat)
        createLivePhotoVideo(from: asset, to: movURL, startTime: startTime, duration: duration) { success in
            if success {
                self.saveToLibrary(imageURL: jpgURL, videoURL: movURL, completion: completion)
            } else {
                completion(false)
            }
        }
    }

    private func generateImage(from asset: AVAsset, at time: Double) -> URL? {
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        imgGenerator.requestedTimeToleranceBefore = .zero
        imgGenerator.requestedTimeToleranceAfter = .zero

        let cmTime = CMTime(seconds: time > 0 ? time : 0, preferredTimescale: 600)

        guard let cgImage = try? imgGenerator.copyCGImage(at: cmTime, actualTime: nil) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: 1.0) else { return nil }

        let jpgURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(assetID).jpg")
        try? data.write(to: jpgURL)

        return addAssetID(toImage: jpgURL)
    }

    private func addAssetID(toImage url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, kUTTypeJPEG, 1, nil) else { return nil }
        
        // ВАЖЛИВО: Запис UUID у kCGImagePropertyMakerAppleDictionary під ключем "17"
        let props = [kCGImagePropertyMakerAppleDictionary as String: ["17": assetID]]
        CGImageDestinationAddImageFromSource(destination, source, 0, props as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    private func createLivePhotoVideo(from asset: AVAsset, to outputURL: URL, startTime: Double, duration: Double, completion: @escaping (Bool) -> Void) {
        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            // ВАЖЛИВО (Пункт 6): Оптимізація атомів. Переносить `moov` на початок файлу для PosterBoard.
            writer.shouldOptimizeForNetworkUse = true

            let start = CMTime(seconds: startTime > 0 ? startTime : 0, preferredTimescale: 600)
            let dur = CMTime(seconds: duration > 0 ? duration : asset.duration.seconds, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: dur)

            // Відео трек (Passthrough)
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                completion(false); return
            }
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            videoInput.transform = videoTrack.preferredTransform
            videoInput.expectsMediaDataInRealTime = false
            reader.add(videoOutput)
            writer.add(videoInput)

            // ВАЖЛИВО (Пункт 3): Збереження Аудіотреку (`soun`).
            var audioOutput: AVAssetReaderTrackOutput?
            var audioInput: AVAssetWriterInput?
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                audioInput?.expectsMediaDataInRealTime = false
                reader.add(audioOutput!)
                writer.add(audioInput!)
            } else {
                NSLog("🍎 [LivePhotosPlus] ПОПЕРЕДЖЕННЯ: У вхідному mp4 відсутній звук! PosterBoard може відхилити цей файл.")
            }

            // ВАЖЛИВО (Пункт 1): Global QuickTime Metadata UUID
            let metadataItem = AVMutableMetadataItem()
            metadataItem.key = "com.apple.quicktime.content.identifier" as (NSCopying & NSObjectProtocol)?
            metadataItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            metadataItem.value = assetID as (NSCopying & NSObjectProtocol)?
            metadataItem.dataType = "com.apple.metadata.datatype.UTF-8"
            writer.metadata = [metadataItem]

            // ВАЖЛИВО (Пункт 2): Timed Metadata Track
            let metadataSpec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString: "com.apple.metadata.datatype.int8"
            ]
            var formatDesc: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [metadataSpec] as CFArray, formatDescriptionOut: &formatDesc)

            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDesc)
            metadataInput.expectsMediaDataInRealTime = false
            let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
            writer.add(metadataInput)

            writer.startWriting()
            reader.startReading()
            writer.startSession(atSourceTime: start)

            // ВАЖЛИВО (Пункт 2): Payload 0xFF (який є -1 у форматі Int8)
            let metadataValue = AVMutableMetadataItem()
            metadataValue.key = "com.apple.quicktime.still-image-time" as (NSCopying & NSObjectProtocol)?
            metadataValue.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            let payloadValue: Int8 = -1 // 0xFF
            metadataValue.value = NSNumber(value: payloadValue)
            metadataValue.dataType = "com.apple.metadata.datatype.int8"

            // Точна прив'язка до першого кадру
            let metadataTimeRange = CMTimeRange(start: start, duration: CMTime(value: 1, timescale: 600))
            let timedMetadataGroup = AVTimedMetadataGroup(items: [metadataValue], timeRange: metadataTimeRange)
            metadataAdaptor.append(timedMetadataGroup)

            // Мультиплексування (Зшивання потоків)
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .userInitiated)

            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if let buffer = videoOutput.copyNextSampleBuffer() {
                        videoInput.append(buffer)
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }

            if let aInput = audioInput, let aOutput = audioOutput {
                group.enter()
                aInput.requestMediaDataWhenReady(on: queue) {
                    while aInput.isReadyForMoreMediaData {
                        if let buffer = aOutput.copyNextSampleBuffer() {
                            aInput.append(buffer)
                        } else {
                            aInput.markAsFinished()
                            group.leave()
                            break
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                metadataInput.markAsFinished()
                writer.finishWriting {
                    completion(writer.status == .completed)
                }
            }

        } catch {
            NSLog("🍎 [LivePhotosPlus] Error: \(error.localizedDescription)")
            completion(false)
        }
    }

    private func saveToLibrary(imageURL: URL, videoURL: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            req.addResource(with: .photo, fileURL: imageURL, options: nil)
        }, completionHandler: { success, error in
            if let err = error {
                NSLog("🍎 [LivePhotosPlus] Gallery Save Error: \(err.localizedDescription)")
            } else {
                NSLog("🍎 [LivePhotosPlus] УСПІХ! Файл ідеально зібрано і збережено.")
            }
            completion(success)
        })
    }
}
