import Flutter
import UIKit
import Foundation
import AVFoundation
import Photos
import UniformTypeIdentifiers

// ============================================================================
// MARK: - Flutter Plugin Entry Point
// ============================================================================

public class SwiftLivePhotosPlugin: NSObject, FlutterPlugin {

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
        let instance = SwiftLivePhotosPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - MethodChannel Dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "generate":
            guard let args = call.arguments as? [String: Any] else {
                result(Self.fail("Invalid arguments")); return
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
        let videoUrl  = args["videoUrl"]  as? String
        let localPath = args["localPath"] as? String
        let startTime = args["startTime"] as? Double ?? 0.0
        let duration  = args["duration"]  as? Double ?? 3.0

        // Resolve source: either download from URL or use local path.
        if let urlString = videoUrl, !urlString.isEmpty {
            guard let url = URL(string: urlString) else {
                flutterResult(Self.fail("Malformed URL: \(urlString)")); return
            }
            downloadVideo(from: url) { [weak self] downloadResult in
                switch downloadResult {
                case .success(let localURL):
                    self?.runGeneration(
                        videoPath: localURL.path,
                        startTime: startTime,
                        duration: duration,
                        cleanUpSource: true,          // delete downloaded file after use
                        flutterResult: flutterResult
                    )
                case .failure(let error):
                    flutterResult(SwiftLivePhotosPlugin.fail(
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
                completion(.failure(error)); return
            }
            guard let tempURL = tempURL else {
                completion(.failure(NSError(
                    domain: "LivePhotos",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No file received"]
                ))); return
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
            flutterResult(Self.fail("File not found: \(videoPath)")); return
        }

        // Request Photo Library permission before doing any heavy work.
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                NSLog("🍎 [LivePhotos] Photo Library permission denied (status %d)",
                      status.rawValue)
                flutterResult(SwiftLivePhotosPlugin.fail(
                    "Photo Library permission denied"
                )); return
            }

            // Create a NEW generator instance per call — owns strong refs.
            let generator = LivePhotoGenerator(sessionDir: Self.sessionDir)
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
// MARK: - LivePhotoGenerator
// ============================================================================
/// Each generation task gets its own instance so that strong references
/// (`activeAsset`, `activeReader`, `activeWriter`) survive the full lifecycle
/// of the asynchronous AVAssetReader/Writer pipeline.
///
/// This prevents ARC from deallocating mid-flight, which would cause
/// EXC_BAD_ACCESS when `copyNextSampleBuffer()` tries to read from a dead
/// reader.

final class LivePhotoGenerator {

    // MARK: - Strong Properties (ARC safety — NEVER make these local variables)
    private var activeAsset:  AVAsset?
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
            var err: NSError?
            guard asset.statusOfValue(forKey: "duration", error: &err) == .loaded,
                  asset.statusOfValue(forKey: "tracks", error: &err)  == .loaded
            else {
                completion(SwiftLivePhotosPlugin.fail(
                    "Cannot load video: \(err?.localizedDescription ?? "unknown")"
                ))
                return
            }

            let totalDuration = asset.duration.seconds
            guard totalDuration > 0.1 else {
                completion(SwiftLivePhotosPlugin.fail(
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
                completion(SwiftLivePhotosPlugin.fail(
                    "Effective duration too short "
                    + "(\(String(format: "%.3f", safeDuration))s)"
                ))
                return
            }

            // ---- 1. Generate HEIC still image at startTime ------------------
            guard let imgURL = self.generateStillImage(
                asset: asset, atSeconds: safeStart
            ) else {
                completion(SwiftLivePhotosPlugin.fail(
                    "Failed to extract still image frame"
                ))
                return
            }

            // ---- 2. Write MOV with metadata + optional silent audio ---------
            let movURL = self.sessionDir
                .appendingPathComponent("\(self.assetID).mov")
            try? FileManager.default.removeItem(at: movURL) // remove stale

            self.writeVideo(
                asset: asset,
                to: movURL,
                startTime: safeStart,
                duration: safeDuration
            ) { writeSuccess in
                guard writeSuccess else {
                    completion(SwiftLivePhotosPlugin.fail(
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
                            "success":  true,
                            "heicPath": imgURL.path,
                            "movPath":  movURL.path
                        ])
                    } else {
                        completion(SwiftLivePhotosPlugin.fail(
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
        gen.requestedTimeToleranceBefore   = .zero   // exact frame
        gen.requestedTimeToleranceAfter    = .zero

        // Request full resolution.
        if let vt = asset.tracks(withMediaType: .video).first {
            gen.maximumSize = vt.naturalSize
        }

        let requestTime = CMTime(seconds: time, preferredTimescale: 600)
        guard let cgImage = try? gen.copyCGImage(
            at: requestTime, actualTime: nil
        ) else {
            NSLog("🍎 [LivePhotos] copyCGImage failed at %.3fs", time)
            return nil
        }

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

    /// Writes a CGImage with the Apple MakerNote containing `"17": assetID`.
    private func writeImage(
        _ cgImage: CGImage, to url: URL, utType: CFString
    ) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, utType, 1, nil
        ) else { return false }

        // Apple MakerNote — links the photo to the video via a shared UUID.
        let props: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: ["17": assetID],
            kCGImageDestinationLossyCompressionQuality as String: 0.92
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
    // MARK: - Step 2 — Assemble MOV Container
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

            // moov atom at the front → required for streaming and PosterBoard.
            writer.shouldOptimizeForNetworkUse = true

            // Time range (600 timescale ≈ 1.67 ms precision — sufficient for
            // the millisecond-precision contract).
            let cmStart = CMTime(seconds: startTime, preferredTimescale: 600)
            let cmDur   = CMTime(seconds: duration,  preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: cmStart, duration: cmDur)

            // ---- VIDEO TRACK (Passthrough) ----------------------------------
            guard let videoTrack = asset.tracks(withMediaType: .video).first
            else {
                completion(false); return
            }
            let videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack, outputSettings: nil            // passthrough
            )
            let videoInput = AVAssetWriterInput(
                mediaType: .video, outputSettings: nil            // passthrough
            )
            videoInput.transform = videoTrack.preferredTransform
            guard reader.canAdd(videoOutput), writer.canAdd(videoInput)
            else { completion(false); return }
            reader.add(videoOutput)
            writer.add(videoInput)

            // ---- AUDIO TRACK (Passthrough or silent synthesis) ---------------
            var audioInput:  AVAssetWriterInput?
            var audioOutput: AVAssetReaderTrackOutput?
            let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty

            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                // Real audio → passthrough copy.
                let aOut = AVAssetReaderTrackOutput(
                    track: audioTrack, outputSettings: nil        // passthrough
                )
                let aIn  = AVAssetWriterInput(
                    mediaType: .audio, outputSettings: nil        // passthrough
                )
                if reader.canAdd(aOut) && writer.canAdd(aIn) {
                    reader.add(aOut)
                    writer.add(aIn)
                    audioOutput = aOut
                    audioInput  = aIn
                }
            } else {
                // Silent video (AI-generated) → synthesise an empty AAC track
                // so that the soun atom exists and iOS PosterBoard accepts the
                // Live Photo as a wallpaper.
                let silentSettings: [String: Any] = [
                    AVFormatIDKey:            kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey:    1,
                    AVSampleRateKey:          44100,
                    AVEncoderBitRateKey:      64000
                ]
                let aIn = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: silentSettings
                )
                aIn.expectsMediaDataInRealTime = false
                if writer.canAdd(aIn) {
                    writer.add(aIn)
                    audioInput = aIn
                }
            }

            // ---- TIMED METADATA TRACK (still-image-time) --------------------
            let metaSpec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                    as NSString:
                    "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                    as NSString:
                    "com.apple.metadata.datatype.int8"
            ]
            var metaDesc: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator:                  nil,
                metadataType:               kCMMetadataFormatType_Boxed,
                metadataSpecifications:     [metaSpec] as CFArray,
                formatDescriptionOut:       &metaDesc
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

            // ---- GLOBAL METADATA (content.identifier = UUID) ----------------
            let idItem = AVMutableMetadataItem()
            idItem.key      = "com.apple.quicktime.content.identifier" as NSString
            idItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            idItem.value    = assetID as NSString
            idItem.dataType = "com.apple.metadata.datatype.UTF-8"
            writer.metadata = [idItem]

            // ---- START PIPELINE ---------------------------------------------
            guard writer.startWriting() else {
                NSLog("🍎 [LivePhotos] writer.startWriting failed: %@",
                      String(describing: writer.error))
                completion(false); return
            }
            guard reader.startReading() else {
                NSLog("🍎 [LivePhotos] reader.startReading failed: %@",
                      String(describing: reader.error))
                writer.cancelWriting()
                completion(false); return
            }
            writer.startSession(atSourceTime: cmStart)

            // ---- Inject still-image-time anchor (0xFF / Int8(-1)) -----------
            if metaInput.isReadyForMoreMediaData {
                let anchor = AVMutableMetadataItem()
                anchor.key      = "com.apple.quicktime.still-image-time" as NSString
                anchor.keySpace = AVMetadataKeySpace(rawValue: "mdta")
                anchor.value    = NSNumber(value: Int8(-1))    // 0xFF
                anchor.dataType = "com.apple.metadata.datatype.int8"
                metaAdaptor.append(AVTimedMetadataGroup(
                    items: [anchor],
                    timeRange: CMTimeRange(
                        start:    cmStart,
                        duration: CMTime(value: 1, timescale: 600)
                    )
                ))
            }

            // ---- Async sample-copy with Serial Dispatch Queues --------------
            let finishGroup = DispatchGroup()

            // Video pump
            let videoQueue = DispatchQueue(label: "LivePhoto.video.serial")
            var videoFinished = false
            finishGroup.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    // SAFETY: check reader is still alive before reading.
                    guard reader.status == .reading else {
                        videoInput.markAsFinished()
                        if !videoFinished { videoFinished = true; finishGroup.leave() }
                        return
                    }
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        videoInput.append(sample)
                    } else {
                        videoInput.markAsFinished()
                        if !videoFinished { videoFinished = true; finishGroup.leave() }
                        return
                    }
                }
            }

            // Audio pump (only if we have a real audio output to copy from)
            if let aIn = audioInput, let aOut = audioOutput, hasAudio {
                let audioQueue = DispatchQueue(label: "LivePhoto.audio.serial")
                var audioFinished = false
                finishGroup.enter()
                aIn.requestMediaDataWhenReady(on: audioQueue) {
                    while aIn.isReadyForMoreMediaData {
                        guard reader.status == .reading else {
                            aIn.markAsFinished()
                            if !audioFinished { audioFinished = true; finishGroup.leave() }
                            return
                        }
                        if let sample = aOut.copyNextSampleBuffer() {
                            aIn.append(sample)
                        } else {
                            aIn.markAsFinished()
                            if !audioFinished { audioFinished = true; finishGroup.leave() }
                            return
                        }
                    }
                }
            } else if let aIn = audioInput, !hasAudio {
                // Synthesised silent track: nothing to feed → mark finished
                // immediately. The mere declaration of the input is enough to
                // produce the empty soun atom inside the MOV container.
                aIn.markAsFinished()
            }

            // ---- Finish writing when all pumps are done ---------------------
            finishGroup.notify(queue: .global(qos: .userInitiated)) {
                metaInput.markAsFinished()
                writer.finishWriting {
                    // Safe to release reader/writer now.
                    self.activeReader = nil
                    self.activeWriter = nil

                    switch writer.status {
                    case .completed:
                        completion(true)
                    default:
                        NSLog("🍎 [LivePhotos] Writer ended with status %d: %@",
                              writer.status.rawValue,
                              String(describing: writer.error))
                        completion(false)
                    }
                }
            }

        } catch {
            NSLog("🍎 [LivePhotos] Pipeline exception: %@",
                  error.localizedDescription)
            completion(false)
        }
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
            request.addResource(with: .photo,       fileURL: imageURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
        }) { success, error in
            if let err = error {
                NSLog("🍎 [LivePhotos] Camera Roll save error: %@",
                      err.localizedDescription)
            }
            completion(success)
        }
    }

    // MARK: - Cleanup

    private func releaseActiveRefs() {
        activeAsset  = nil
        activeReader = nil
        activeWriter = nil
    }
}
