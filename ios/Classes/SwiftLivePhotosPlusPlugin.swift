import AVFoundation
import Flutter
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

// ============================================================================
// MARK: - Flutter Plugin Entry Point
// ============================================================================

public class SwiftLivePhotosPlusPlugin: NSObject, FlutterPlugin {

    /// Dedicated subdirectory inside NSTemporaryDirectory for all generated files.
    /// Using a fixed subdirectory makes bulk cleanup trivial.
    private static let sessionDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live_photos_session", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )
        return dir
    }()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "live_photos_plus",
            binaryMessenger: registrar.messenger()
        )
        let instance = SwiftLivePhotosPlusPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - MethodChannel Dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "generate":
            guard let args = call.arguments as? [String: Any] else {
                result(Self.fail("Invalid arguments"))
                return
            }
            handleGenerate(args: args, flutterResult: result)

        case "cleanUp":
            handleCleanUp(flutterResult: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - generate

    private func handleGenerate(args: [String: Any], flutterResult: @escaping FlutterResult) {
        let videoUrl = args["videoUrl"] as? String
        let localPath = args["localPath"] as? String
        let startTime = args["startTime"] as? Double ?? 0.0
        let duration = args["duration"] as? Double ?? 3.0

        // Resolve source: either download from URL or use local path.
        if let urlString = videoUrl, !urlString.isEmpty {
            guard let url = URL(string: urlString) else {
                flutterResult(Self.fail("Malformed URL: \(urlString)"))
                return
            }
            downloadVideo(from: url) { [weak self] downloadResult in
                switch downloadResult {
                case .success(let localURL):
                    self?.runGeneration(
                        videoPath: localURL.path,
                        startTime: startTime,
                        duration: duration,
                        cleanUpSource: true,  // delete downloaded file after use
                        flutterResult: flutterResult
                    )
                case .failure(let error):
                    flutterResult(
                        SwiftLivePhotosPlusPlugin.fail(
                            "Download failed: \(error.localizedDescription)"
                        ))
                }
            }
        } else if let path = localPath, !path.isEmpty {
            runGeneration(
                videoPath: path,
                startTime: startTime,
                duration: duration,
                cleanUpSource: false,
                flutterResult: flutterResult
            )
        } else {
            flutterResult(Self.fail("Either videoUrl or localPath must be provided."))
        }
    }

    // MARK: - cleanUp

    private func handleCleanUp(flutterResult: @escaping FlutterResult) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(
                at: Self.sessionDir,
                includingPropertiesForKeys: nil
            ) {
                for file in contents {
                    try? fm.removeItem(at: file)
                }
            }
            DispatchQueue.main.async { flutterResult(nil) }
        }
    }

    // MARK: - Download

    private func downloadVideo(
        from url: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let tempURL = tempURL else {
                completion(
                    .failure(
                        NSError(
                            domain: "LivePhotos",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No file received"]
                        )))
                return
            }
            // Move to session directory with a unique name.
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let dest = Self.sessionDir
                .appendingPathComponent("dl_\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                completion(.success(dest))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    // MARK: - Orchestrator

    private func runGeneration(
        videoPath: String,
        startTime: Double,
        duration: Double,
        cleanUpSource: Bool,
        flutterResult: @escaping FlutterResult
    ) {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            flutterResult(Self.fail("File not found: \(videoPath)"))
            return
        }

        // Request Photo Library permission before doing any heavy work.
        func continueWithGrant(_ isGranted: Bool) {
            guard isGranted else {
                NSLog("🍎 [LivePhotos] Photo Library permission denied")
                flutterResult(SwiftLivePhotosPlusPlugin.fail("Photo Library permission denied"))
                return
            }
            // Create a NEW generator instance per call — owns strong refs.
            let generator = LivePhotoPlusGenerator(sessionDir: Self.sessionDir)
            generator.run(
                videoPath: videoPath,
                startTime: startTime,
                duration: duration
            ) { resultMap in
                // Clean up the downloaded source file if it was a URL job.
                if cleanUpSource {
                    try? FileManager.default.removeItem(atPath: videoPath)
                }
                flutterResult(resultMap)
            }
        }

        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continueWithGrant(status == .authorized || status == .limited)
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                continueWithGrant(status == .authorized)
            }
        }
    }

    // MARK: - Helpers

    static func fail(_ message: String) -> [String: Any] {
        NSLog("🍎 [LivePhotos] Error: %@", message)
        return ["success": false, "error": message]
    }
}

// ============================================================================
// MARK: - LivePhotoPlusGenerator
// ============================================================================
/// Each generation task gets its own instance so that strong references
/// (`activeAsset`, `activeReader`, `activeWriter`) survive the full lifecycle
/// of the asynchronous AVAssetReader/Writer pipeline.

final class LivePhotoPlusGenerator {

    // MARK: - Strong Properties (ARC safety — NEVER make these local variables)
    private var activeAsset: AVAsset?
    private var activeReader: AVAssetReader?
    private var activeWriter: AVAssetWriter?

    /// Shared UUID that binds the still image and the video together.
    private let assetID = UUID().uuidString

    /// Directory where generated HEIC / MOV files are placed.
    private let sessionDir: URL

    init(sessionDir: URL) {
        self.sessionDir = sessionDir
    }

    // MARK: - Public entry point

    func run(
        videoPath: String,
        startTime: Double,
        duration: Double,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let sourceURL = URL(fileURLWithPath: videoPath)

        // Load asset with precise timing enabled — important for millisecond
        // accuracy of startTime / duration.
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        self.activeAsset = asset

        // Pre-load required keys asynchronously.
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { [self] in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSError?
                guard asset.statusOfValue(forKey: "duration", error: &err) == .loaded,
                    asset.statusOfValue(forKey: "tracks", error: &err) == .loaded
                else {
                    completion(
                        SwiftLivePhotosPlusPlugin.fail(
                            "Cannot load video: \(err?.localizedDescription ?? "unknown")"
                        ))
                    return
                }

                let totalDuration = asset.duration.seconds
                guard totalDuration > 0.1 else {
                    completion(
                        SwiftLivePhotosPlusPlugin.fail(
                            "Video too short (\(String(format: "%.3f", totalDuration))s)"
                        ))
                    return
                }

                // ---- Safe bounds ------------------------------------------------
                let safeStart = min(max(startTime, 0), max(0, totalDuration - 0.1))
                var safeDuration = duration
                if safeDuration <= 0 { safeDuration = min(3.0, totalDuration - safeStart) }
                safeDuration = min(safeDuration, totalDuration - safeStart)

                guard safeDuration > 0.1 else {
                    completion(
                        SwiftLivePhotosPlusPlugin.fail(
                            "Effective duration too short "
                                + "(\(String(format: "%.3f", safeDuration))s)"
                        ))
                    return
                }

                // ---- 1. Generate HEIC still image near the START of the clip -----
                let stillTimeSeconds = safeStart + min(0.1, safeDuration / 2.0)
                guard
                    let imgURL = self.generateStillImage(
                        asset: asset, atSeconds: stillTimeSeconds
                    )
                else {
                    completion(
                        SwiftLivePhotosPlusPlugin.fail(
                            "Failed to extract still image frame"
                        ))
                    return
                }

                // ---- 2. Write MOV with passthrough video + timed metadata track --
                let movURL = self.sessionDir
                    .appendingPathComponent("\(self.assetID).mov")
                try? FileManager.default.removeItem(at: movURL)  // remove stale

                self.writeVideo(
                    asset: asset,
                    to: movURL,
                    startTime: safeStart,
                    duration: safeDuration
                ) { writeSuccess in
                    guard writeSuccess else {
                        completion(
                            SwiftLivePhotosPlusPlugin.fail(
                                "Failed to assemble video container"
                            ))
                        return
                    }

                    // ---- 3. Save HEIC + MOV pair into PHPhotoLibrary ------------
                    self.saveToCameraRoll(
                        imageURL: imgURL, videoURL: movURL
                    ) { saveSuccess, errorMsg in
                        // Release heavy objects now that everything is persisted.
                        self.releaseActiveRefs()

                        if saveSuccess {
                            completion([
                                "success": true,
                                "heicPath": imgURL.path,
                                "movPath": movURL.path,
                            ])
                        } else {
                            let errStr = errorMsg ?? "Failed to save to Camera Roll"
                            completion(
                                SwiftLivePhotosPlusPlugin.fail(errStr)
                            )
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // MARK: - Step 1 — Still Image (HEIC with JPEG fallback)
    // =========================================================================

    private func generateStillImage(asset: AVAsset, atSeconds time: Double) -> URL? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        // Request full resolution — must match final MOV dimensions.
        if let vt = asset.tracks(withMediaType: .video).first {
            gen.maximumSize = vt.naturalSize
        }

        let requestTime = CMTime(seconds: time, preferredTimescale: 600)
        var actualTime: CMTime = .zero
        guard
            let cgImage = try? gen.copyCGImage(
                at: requestTime, actualTime: &actualTime
            )
        else {
            NSLog("🍎 [LivePhotos] copyCGImage failed at %.3fs", time)
            return nil
        }

        NSLog(
            "🍎 [LivePhotos] Still frame captured at PTS: %.6fs (requested %.3fs)",
            actualTime.seconds, time)

        // Prefer HEIC; fall back to JPEG on older hardware.
        let heicURL = sessionDir.appendingPathComponent("\(assetID).heic")
        if writeImage(cgImage, to: heicURL, utType: heicUTType()) {
            return heicURL
        }
        NSLog("🍎 [LivePhotos] HEIC encoding unavailable, falling back to JPEG")
        let jpegURL = sessionDir.appendingPathComponent("\(assetID).jpg")
        if writeImage(cgImage, to: jpegURL, utType: jpegUTType()) {
            return jpegURL
        }
        return nil
    }

    /// Writes a CGImage with Apple MakerNote (key 17 = assetID) and EXIF dimensions.
    private func writeImage(
        _ cgImage: CGImage, to url: URL, utType: CFString
    ) -> Bool {
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, utType, 1, nil
            )
        else { return false }

        // MakerNote key "17" links the HEIC to the MOV via shared UUID.
        // EXIF dimensions are required by PHAssetCreationRequest validation.
        let metadata: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: [
                "17": assetID
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifPixelXDimension as String: cgImage.width,
                kCGImagePropertyExifPixelYDimension as String: cgImage.height
            ],
            kCGImageDestinationLossyCompressionQuality as String: 0.92,
        ]

        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private func heicUTType() -> CFString {
        if #available(iOS 14.0, *) { return UTType.heic.identifier as CFString }
        return "public.heic" as CFString
    }

    private func jpegUTType() -> CFString {
        if #available(iOS 14.0, *) { return UTType.jpeg.identifier as CFString }
        return "public.jpeg" as CFString
    }

    // =========================================================================
    // MARK: - Step 2 — Assemble MOV Container
    // Passthrough video (no re-encode) + timed still-image-time metadata track.
    // AVAssetWriter is required because AVAssetExportSession cannot write
    // timed metadata tracks, which PosterBoard needs for Live Wallpapers.
    // =========================================================================

    private func writeVideo(
        asset: AVAsset,
        to outputURL: URL,
        startTime: Double,
        duration: Double,
        completion: @escaping (Bool) -> Void
    ) {
        let cmStart = CMTime(seconds: startTime, preferredTimescale: 600)
        let cmDur   = CMTime(seconds: duration,  preferredTimescale: 600)
        let timeRange = CMTimeRange(start: cmStart, duration: cmDur)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            NSLog("🍎 [LivePhotos] No video track found")
            completion(false)
            return
        }

        do {
            // ---- Reader (passthrough — nil outputSettings = compressed samples) ----
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = timeRange

            let videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack, outputSettings: nil  // nil = passthrough, no decode
            )
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                NSLog("🍎 [LivePhotos] Cannot add videoOutput to reader")
                completion(false)
                return
            }
            reader.add(videoOutput)

            // ---- Writer -------------------------------------------------------
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            writer.shouldOptimizeForNetworkUse = true  // moov atom at front

            // Keep strong refs so ARC doesn't release them mid-pipeline
            self.activeReader = reader
            self.activeWriter = writer

            // Video input: passthrough — sourceFormatHint tells writer the codec
            guard let videoFormatDesc = videoTrack.formatDescriptions.first as? CMFormatDescription else {
                NSLog("🍎 [LivePhotos] No format description on video track")
                completion(false)
                return
            }
            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,  // nil = passthrough, no re-encode
                sourceFormatHint: videoFormatDesc
            )
            videoInput.transform = videoTrack.preferredTransform
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else {
                NSLog("🍎 [LivePhotos] Cannot add videoInput to writer")
                completion(false)
                return
            }
            writer.add(videoInput)

            // ---- Timed metadata track: still-image-time -----------------------
            // PosterBoard requires a timed NRT Metadata track with
            // com.apple.quicktime.still-image-time = -1 at t=0.
            // Value -1 signals that the still image is a separate HEIC component
            // (as opposed to a frame extracted from the video).
            let stillImageTimeSpec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                    "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                    "com.apple.metadata.datatype.int8",
            ]
            var metaDesc: CMFormatDescription?
            let specStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [stillImageTimeSpec] as CFArray,
                formatDescriptionOut: &metaDesc
            )
            guard specStatus == noErr, let metaDesc = metaDesc else {
                NSLog("🍎 [LivePhotos] Failed to create metadata format desc: %d", specStatus)
                completion(false)
                return
            }
            let metaInput = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: metaDesc
            )
            let metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
            guard writer.canAdd(metaInput) else {
                NSLog("🍎 [LivePhotos] Cannot add metaInput to writer")
                completion(false)
                return
            }
            writer.add(metaInput)

            // ---- Global QuickTime metadata (movie-level keys box) --------------
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            let creationDateStr = isoFormatter.string(from: Date())

            func makeGlobalItem(_ key: String, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
                let item = AVMutableMetadataItem()
                item.keySpace = .quickTimeMetadata
                item.key = key as NSString
                item.value = value
                return item
            }
            writer.metadata = [
                makeGlobalItem("com.apple.quicktime.content.identifier", assetID as NSString),
                makeGlobalItem("com.apple.quicktime.make",               "Apple" as NSString),
                makeGlobalItem("com.apple.quicktime.model",              "iPhone" as NSString),
                makeGlobalItem("com.apple.quicktime.software",           UIDevice.current.systemVersion as NSString),
                makeGlobalItem("com.apple.quicktime.creationdate",       creationDateStr as NSString),
            ]

            // ---- Start session ------------------------------------------------
            writer.startWriting()
            reader.startReading()
            // startSession must match the PTS of the first sample from the reader.
            // When reader.timeRange starts at cmStart, samples arrive with their
            // original PTS (e.g. 5.0s). Using cmStart here maps them to output t=0.
            writer.startSession(atSourceTime: cmStart)

            // ---- Inject still-image-time timed sample at cmStart --------------
            // The sample MUST be appended before markAsFinished().
            // Duration of 1/600s matches the reference file structure.
            // timeRange must be in source-time coordinates (cmStart → output t=0).
            let anchor = AVMutableMetadataItem()
            anchor.key = "com.apple.quicktime.still-image-time" as NSString
            anchor.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            anchor.value = NSNumber(value: Int8(-1))           // -1 = separate HEIC component
            anchor.dataType = kCMMetadataBaseDataType_SInt8 as String
            let metaGroup = AVTimedMetadataGroup(
                items: [anchor],
                timeRange: CMTimeRange(
                    start: cmStart,
                    duration: CMTime(value: 1, timescale: 600)
                )
            )
            if metaAdaptor.append(metaGroup) {
                NSLog("🍎 [LivePhotos] still-image-time metadata appended successfully")
            } else {
                NSLog("🍎 [LivePhotos] WARNING: metaAdaptor.append returned false")
            }
            metaInput.markAsFinished()

            // ---- Pump video samples asynchronously ----------------------------
            let group = DispatchGroup()
            group.enter()
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "live.photos.video")) {
                while videoInput.isReadyForMoreMediaData {
                    if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                        videoInput.append(sampleBuffer)
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                if reader.status == .completed {
                    writer.finishWriting {
                        let ok = writer.status == .completed
                        if !ok {
                            NSLog(
                                "🍎 [LivePhotos] Writer finished with error: %@",
                                writer.error?.localizedDescription ?? "unknown")
                        }
                        completion(ok)
                    }
                } else {
                    NSLog(
                        "🍎 [LivePhotos] Reader ended with status %d, error: %@",
                        reader.status.rawValue,
                        reader.error?.localizedDescription ?? "none")
                    writer.cancelWriting()
                    completion(false)
                }
            }

        } catch {
            NSLog("🍎 [LivePhotos] writeVideo setup error: %@", error.localizedDescription)
            completion(false)
        }
    }

    // =========================================================================
    // MARK: - Step 3 — Save to PHPhotoLibrary
    // =========================================================================

    private func saveToCameraRoll(
        imageURL: URL,
        videoURL: URL,
        completion: @escaping (Bool, String?) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = Date()

            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false

            request.addResource(with: .photo, fileURL: imageURL, options: options)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
        }) { success, error in
            if let err = error as NSError? {
                let msg =
                    err.localizedDescription.isEmpty
                    ? "Error \(err.domain) \(err.code)" : err.localizedDescription
                NSLog(
                    "🍎 [LivePhotos] Camera Roll save error: %@ (Domain: %@, Code: %d)",
                    msg, err.domain, err.code)
                completion(false, "(\(err.code)) \(msg)")
            } else if let err = error {
                NSLog(
                    "🍎 [LivePhotos] Camera Roll save error: %@",
                    err.localizedDescription)
                completion(false, err.localizedDescription)
            } else {
                completion(success, nil)
            }
        }
    }

    // MARK: - Cleanup

    private func releaseActiveRefs() {
        activeAsset = nil
        activeReader = nil
        activeWriter = nil
    }
}
