import AVFoundation
import Flutter
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

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
            name: "live_photos",
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
        PHPhotoLibrary.requestAuthorization { status in
            let isGranted: Bool
            if #available(iOS 14, *) {
                isGranted = status == .authorized || status == .limited
            } else {
                isGranted = status == .authorized
            }
            guard isGranted else {
                NSLog(
                    "🍎 [LivePhotos] Photo Library permission denied (status %d)",
                    status.rawValue)
                flutterResult(
                    SwiftLivePhotosPlusPlugin.fail(
                        "Photo Library permission denied"
                    ))
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

    /// Exact PTS of the extracted still frame — set by generateStillImage(),
    /// consumed by writeVideo() for the still-image-time anchor.
    private var exactStillImageTime: CMTime = .zero

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

            // ---- 1. Generate HEIC still image at the MIDDLE of the clip -----
            // Using the middle frame as key photo matches Apple's own behaviour.
            // generateStillImage() captures the EXACT PTS into self.exactStillImageTime
            // so the still-image-time anchor is microsecond-accurate.
            let stillTimeSeconds = safeStart + safeDuration / 2.0
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

            // ---- 2. Write MOV with HEVC re-encode + metadata ----------------
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
                ) { saveSuccess in
                    // Release heavy objects now that everything is persisted.
                    self.releaseActiveRefs()

                    if saveSuccess {
                        completion([
                            "success": true,
                            "heicPath": imgURL.path,
                            "movPath": movURL.path,
                        ])
                    } else {
                        completion(
                            SwiftLivePhotosPlusPlugin.fail(
                                "Failed to save to Camera Roll"
                            ))
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
        // Capture actualTime — the real PTS of the decoded frame.
        var actualTime: CMTime = .zero
        guard
            let cgImage = try? gen.copyCGImage(
                at: requestTime, actualTime: &actualTime
            )
        else {
            NSLog("🍎 [LivePhotos] copyCGImage failed at %.3fs", time)
            return nil
        }

        // Store the exact frame PTS for still-image-time metadata sync.
        self.exactStillImageTime = actualTime
        NSLog(
            "🍎 [LivePhotos] Still frame captured at exact PTS: %.6fs (requested %.3fs)",
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

    /// Writes a CGImage with Apple MakerNote (key 17 = assetID) and TIFF device tags.
    private func writeImage(
        _ cgImage: CGImage, to url: URL, utType: CFString
    ) -> Bool {
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, utType, 1, nil
            )
        else { return false }

        // TIFF device tags — PosterBoard checks these to confirm the image
        // originates from an Apple device. Without them, wallpaper motion is blocked.
        let tiffDict: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: "iPhone",
        ]

        // Apple MakerNote — links the photo to the video via a shared UUID.
        // Key must be integer 17 to match how the native camera writes it.
        let props: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: [17: assetID],
            kCGImagePropertyTIFFDictionary as String: tiffDict,
            kCGImageDestinationLossyCompressionQuality as String: 0.92,
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
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
    // MARK: - Step 2 — Assemble MOV Container (HEVC Re-encode)
    // =========================================================================

    private func writeVideo(
        asset: AVAsset,
        to outputURL: URL,
        startTime: Double,
        duration: Double,
        completion: @escaping (Bool) -> Void
    ) {
        do {
            // ---- Reader / Writer (kept as Strong Properties) ----------------
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            self.activeReader = reader
            self.activeWriter = writer

            // moov atom at the front for PosterBoard compatibility.
            writer.shouldOptimizeForNetworkUse = true

            // Time range (600 timescale ≈ 1.67 ms precision).
            let cmStart = CMTime(seconds: startTime, preferredTimescale: 600)
            let cmDur = CMTime(seconds: duration, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: cmStart, duration: cmDur)

            // ---- VIDEO TRACK (HEVC Re-encode) --------------------------------
            guard let videoTrack = asset.tracks(withMediaType: .video).first
            else {
                completion(false)
                return
            }

            // Reader output: decompress to raw pixel buffers
            let videoReaderSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack, outputSettings: videoReaderSettings
            )
            videoOutput.alwaysCopiesSampleData = false

            // Determine video dimensions respecting the transform.
            // Round to even numbers for HEVC macroblock alignment (16×16 or 8×8).
            let naturalSize = videoTrack.naturalSize
            let transform = videoTrack.preferredTransform
            let transformedSize = naturalSize.applying(transform)
            let videoWidth = (Int(abs(transformedSize.width)) / 2) * 2
            let videoHeight = (Int(abs(transformedSize.height)) / 2) * 2

            // Detect source frame rate — preserve it instead of forcing 30fps.
            let sourceFrameRate = videoTrack.nominalFrameRate
            let targetFrameRate: Int = sourceFrameRate > 0 ? Int(round(sourceFrameRate)) : 30

            // Estimate a reasonable bitrate (aim for good quality)
            let estimatedBitRate: Int = videoWidth * videoHeight * 6
            // Cap at reasonable range
            let bitRate = max(2_000_000, min(estimatedBitRate, 20_000_000))

            NSLog(
                "🍎 [LivePhotos] Video: %dx%d @ %dfps, bitrate=%d",
                videoWidth, videoHeight, targetFrameRate, bitRate)

            let videoWriterSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoExpectedSourceFrameRateKey: targetFrameRate,
                    AVVideoMaxKeyFrameIntervalKey: targetFrameRate,
                ] as [String: Any],
            ]

            let videoInput = AVAssetWriterInput(
                mediaType: .video, outputSettings: videoWriterSettings
            )
            videoInput.expectsMediaDataInRealTime = false
            // Apply the track transform so orientation is preserved
            videoInput.transform = videoTrack.preferredTransform

            guard reader.canAdd(videoOutput), writer.canAdd(videoInput)
            else {
                NSLog("🍎 [LivePhotos] Cannot add video reader/writer")
                completion(false)
                return
            }
            reader.add(videoOutput)
            writer.add(videoInput)

            // ---- NO AUDIO TRACK ------------------------------------------------
            // Reference Live Photos (from iOS itself) have NO audio track.
            // Adding a synthetic silent audio track can break wallpaper compatibility.
            // If the source has audio, we intentionally skip it.

            // ---- TIMED METADATA TRACK 1: still-image-time -------------------
            // This track contains the still-image-time anchor point AND the
            // live-photo-still-image-transform key (matching reference structure).
            let stillImageTimeSpec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                    as NSString:
                    "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                    as NSString:
                    "com.apple.metadata.datatype.int8",
            ]
            let stillImageTransformSpec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                    as NSString:
                    "mdta/com.apple.quicktime.live-photo-still-image-transform",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                    as NSString:
                    "com.apple.metadata.datatype.int8",
            ]
            var metaDesc: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: nil,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [stillImageTimeSpec, stillImageTransformSpec] as CFArray,
                formatDescriptionOut: &metaDesc
            )
            let metaInput = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: metaDesc
            )
            let metaAdaptor = AVAssetWriterInputMetadataAdaptor(
                assetWriterInput: metaInput
            )
            if writer.canAdd(metaInput) { writer.add(metaInput) }

            // ---- TIMED METADATA TRACK 2: live-photo-info --------------------
            // Reference MOV has a per-frame LivePhotoInfo metadata track.
            // We create a minimal version with stub data.
            let livePhotoInfoSpec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                    as NSString:
                    "mdta/com.apple.quicktime.live-photo-info",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                    as NSString:
                    kCMMetadataBaseDataType_RawData as NSString,
            ]
            var lpiMetaDesc: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: nil,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [livePhotoInfoSpec] as CFArray,
                formatDescriptionOut: &lpiMetaDesc
            )
            let lpiMetaInput = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: lpiMetaDesc
            )
            let lpiMetaAdaptor = AVAssetWriterInputMetadataAdaptor(
                assetWriterInput: lpiMetaInput
            )
            if writer.canAdd(lpiMetaInput) { writer.add(lpiMetaInput) }

            // ---- GLOBAL METADATA --------------------------------------------
            // content.identifier = UUID (links to HEIC MakerApple key 17)
            let idItem = AVMutableMetadataItem()
            idItem.key = "com.apple.quicktime.content.identifier" as NSString
            idItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            idItem.value = assetID as NSString
            idItem.dataType = "com.apple.metadata.datatype.UTF-8"

            // Device metadata — reference files always include these.
            // PosterBoard verifies device origin for wallpaper eligibility.
            let makeItem = AVMutableMetadataItem()
            makeItem.key = "com.apple.quicktime.make" as NSString
            makeItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            makeItem.value = "Apple" as NSString
            makeItem.dataType = "com.apple.metadata.datatype.UTF-8"

            let modelItem = AVMutableMetadataItem()
            modelItem.key = "com.apple.quicktime.model" as NSString
            modelItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            modelItem.value = "iPhone" as NSString
            modelItem.dataType = "com.apple.metadata.datatype.UTF-8"

            let softwareItem = AVMutableMetadataItem()
            softwareItem.key = "com.apple.quicktime.software" as NSString
            softwareItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            let osVersion = UIDevice.current.systemVersion
            softwareItem.value = osVersion as NSString
            softwareItem.dataType = "com.apple.metadata.datatype.UTF-8"

            let dateItem = AVMutableMetadataItem()
            dateItem.key = "com.apple.quicktime.creationdate" as NSString
            dateItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            dateItem.value = formatter.string(from: Date()) as NSString
            dateItem.dataType = "com.apple.metadata.datatype.UTF-8"

            writer.metadata = [idItem, makeItem, modelItem, softwareItem, dateItem]

            // ---- START PIPELINE ---------------------------------------------
            guard writer.startWriting() else {
                NSLog(
                    "🍎 [LivePhotos] writer.startWriting failed: %@",
                    String(describing: writer.error))
                completion(false)
                return
            }
            guard reader.startReading() else {
                NSLog(
                    "🍎 [LivePhotos] reader.startReading failed: %@",
                    String(describing: reader.error))
                writer.cancelWriting()
                completion(false)
                return
            }
            writer.startSession(atSourceTime: cmStart)

            // ---- Inject still-image-time anchor at EXACT extracted frame PTS --
            // Uses self.exactStillImageTime captured during still image generation,
            // ensuring microsecond-level sync between the HEIC key frame and MOV anchor.
            // Duration is 1 tick at timescale 600 to match reference format.
            if metaInput.isReadyForMoreMediaData {
                let anchor = AVMutableMetadataItem()
                anchor.key = "com.apple.quicktime.still-image-time" as NSString
                anchor.keySpace = AVMetadataKeySpace(rawValue: "mdta")
                anchor.value = NSNumber(value: 0)
                anchor.dataType = "com.apple.metadata.datatype.int8"

                metaAdaptor.append(
                    AVTimedMetadataGroup(
                        items: [anchor],
                        timeRange: CMTimeRange(
                            start: self.exactStillImageTime,
                            duration: CMTime(value: 1, timescale: 600)
                        )
                    ))
            }

            // ---- Inject live-photo-info stub data ----------------------------
            // The reference file has per-frame LivePhotoInfo. We write a minimal
            // set of entries covering the video duration from the still-image-time
            // to the end (matching reference which starts after a small offset).
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
            let clipEndTime = CMTimeAdd(cmStart, cmDur)
            // Start LPI data slightly after the clip start (matching reference pattern)
            let lpiStartTime = CMTimeAdd(cmStart, frameDuration)

            if lpiMetaInput.isReadyForMoreMediaData {
                // Generate minimal LivePhotoInfo entries from just after clip start
                // to just before clip end.
                var currentLpiTime = lpiStartTime
                while CMTimeCompare(currentLpiTime, clipEndTime) < 0 {
                    let infoItem = AVMutableMetadataItem()
                    infoItem.key = "com.apple.quicktime.live-photo-info" as NSString
                    infoItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
                    // Minimal LivePhotoInfo stub: version=3, all zeros for stabilization data
                    // This matches the structure iOS expects (binary float array).
                    infoItem.value = Self.createMinimalLivePhotoInfoData() as NSData
                    infoItem.dataType = kCMMetadataBaseDataType_RawData as String

                    let appendSuccess = lpiMetaAdaptor.append(
                        AVTimedMetadataGroup(
                            items: [infoItem],
                            timeRange: CMTimeRange(
                                start: currentLpiTime,
                                duration: frameDuration
                            )
                        ))
                    if !appendSuccess {
                        NSLog(
                            "🍎 [LivePhotos] Failed to append LPI metadata at %.3fs",
                            currentLpiTime.seconds)
                        break
                    }
                    currentLpiTime = CMTimeAdd(currentLpiTime, frameDuration)
                }
            }

            // ---- Async sample-copy with Serial Dispatch Queues --------------
            let finishGroup = DispatchGroup()

            // Video pump (decode + re-encode to HEVC)
            let videoQueue = DispatchQueue(label: "LivePhoto.video.serial")
            var videoFinished = false
            finishGroup.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    guard reader.status == .reading else {
                        videoInput.markAsFinished()
                        if !videoFinished {
                            videoFinished = true
                            finishGroup.leave()
                        }
                        return
                    }
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        videoInput.append(sample)
                    } else {
                        videoInput.markAsFinished()
                        if !videoFinished {
                            videoFinished = true
                            finishGroup.leave()
                        }
                        return
                    }
                }
            }

            // ---- Finish writing when all pumps are done ---------------------
            finishGroup.notify(queue: .global(qos: .userInitiated)) {
                metaInput.markAsFinished()
                lpiMetaInput.markAsFinished()
                writer.finishWriting {
                    // Safe to release reader/writer now.
                    self.activeReader = nil
                    self.activeWriter = nil

                    switch writer.status {
                    case .completed:
                        NSLog("🍎 [LivePhotos] MOV written successfully (HEVC)")
                        completion(true)
                    default:
                        NSLog(
                            "🍎 [LivePhotos] Writer ended with status %d: %@",
                            writer.status.rawValue,
                            String(describing: writer.error))
                        completion(false)
                    }
                }
            }

        } catch {
            NSLog(
                "🍎 [LivePhotos] Pipeline exception: %@",
                error.localizedDescription)
            completion(false)
        }
    }

    // MARK: - Minimal LivePhotoInfo Data

    /// Creates minimal binary LivePhotoInfo stub data matching the format
    /// used by iOS reference Live Photos. The structure is a binary blob
    /// containing stabilization/gyroscope data. For synthetic Live Photos,
    /// we write identity/zero values.
    private static func createMinimalLivePhotoInfoData() -> Data {
        // Reference format analysis shows 28 float32 values per entry.
        // Structure: version(int32=3), timestamp(float32), flags, stabilization matrix fields
        // For synthetic content, all stabilization values are identity/zero.
        var data = Data()

        // Version: 3 (matches reference)
        var version: Int32 = 3
        data.append(Data(bytes: &version, count: 4))

        // Timestamp: 0 (relative to frame)
        var timestamp: Float32 = 0.0
        data.append(Data(bytes: &timestamp, count: 4))

        // Remaining fields: zeros (identity stabilization)
        // Reference shows ~26 more float values; we pad with zeros
        let remainingFloats = 26
        for _ in 0..<remainingFloats {
            var zero: Float32 = 0.0
            data.append(Data(bytes: &zero, count: 4))
        }

        return data
    }

    // =========================================================================
    // MARK: - Step 3 — Save to PHPhotoLibrary
    // =========================================================================

    private func saveToCameraRoll(
        imageURL: URL,
        videoURL: URL,
        completion: @escaping (Bool) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: imageURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
        }) { success, error in
            if let err = error {
                NSLog(
                    "🍎 [LivePhotos] Camera Roll save error: %@",
                    err.localizedDescription)
            }
            completion(success)
        }
    }

    // MARK: - Cleanup

    private func releaseActiveRefs() {
        activeAsset = nil
        activeReader = nil
        activeWriter = nil
    }
}
