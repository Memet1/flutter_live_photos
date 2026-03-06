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
    private var activeExportSession: AVAssetExportSession?


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
                // Using a frame near the start (e.g., 0.1s) matches the reference
                // implementation and aligns perfectly with `still-image-time: 0` metadata.
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

        // Store the exact frame PTS for still-image-time metadata sync, falling back if invalid.
        if actualTime.isValid && actualTime.isNumeric {
            self.exactStillImageTime = actualTime
        } else {
            self.exactStillImageTime = requestTime
        }

        NSLog(
            "🍎 [LivePhotos] Still frame captured at exact PTS: %.6fs (requested %.3fs)",
            self.exactStillImageTime.seconds, time)

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

        // Metadata identical to the reference repo implementation
        let metadata: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: [
                "17": assetID
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifPixelXDimension as String: cgImage.width,
                kCGImagePropertyExifPixelYDimension as String: cgImage.height
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone",
            ],
            "com.apple.quicktime.still-image-time": 0,
            "com.apple.quicktime.content.identifier": assetID,
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
    // MARK: - Step 2 — Assemble MOV Container (HEVC Re-encode)
    // =========================================================================

    private func writeVideo(
        asset: AVAsset,
        to outputURL: URL,
        startTime: Double,
        duration: Double,
        completion: @escaping (Bool) -> Void
    ) {
        // ---- 1. Create a Composition to Strip Audio & Trim Time ----------------
        let composition = AVMutableComposition()
        let cmStart = CMTime(seconds: startTime, preferredTimescale: 600)
        let cmDur = CMTime(seconds: duration, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: cmStart, duration: cmDur)

        do {
            if let videoTrack = asset.tracks(withMediaType: .video).first,
               let compVideoTrack = composition.addMutableTrack(
                   withMediaType: .video,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
                compVideoTrack.preferredTransform = videoTrack.preferredTransform
            } else {
                completion(false)
                return
            }
        } catch {
            NSLog("🍎 [LivePhotos] Composition error: %@", error.localizedDescription)
            completion(false)
            return
        }

        // ---- 2. Prepare Export Session (Prefer HEVC) --------------------------
        var presetName = AVAssetExportPresetHighestQuality
        if #available(iOS 11.0, *) {
            let hevcPreset = AVAssetExportPresetHEVCHighestQuality
            if AVAssetExportSession.exportPresets(compatibleWith: composition).contains(hevcPreset) {
                presetName = hevcPreset
            }
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: presetName
        ) else {
            completion(false)
            return
        }

        self.activeExportSession = exportSession
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true

        // ---- 3. Meta Data Setup (Global, matches LivePhotoCreator) ------------
        let idItem = AVMutableMetadataItem()
        idItem.keySpace = .quickTimeMetadata
        idItem.key = "com.apple.quicktime.content.identifier" as NSString
        idItem.value = self.assetID as NSString

        let stillTimeItem = AVMutableMetadataItem()
        stillTimeItem.keySpace = .quickTimeMetadata
        stillTimeItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillTimeItem.value = NSNumber(value: 0)

        let makeItem = AVMutableMetadataItem()
        makeItem.keySpace = .quickTimeMetadata
        makeItem.key = "com.apple.quicktime.make" as NSString
        makeItem.value = "Apple" as NSString

        let modelItem = AVMutableMetadataItem()
        modelItem.keySpace = .quickTimeMetadata
        modelItem.key = "com.apple.quicktime.model" as NSString
        modelItem.value = "iPhone" as NSString

        let osVersion = UIDevice.current.systemVersion
        let softwareItem = AVMutableMetadataItem()
        softwareItem.keySpace = .quickTimeMetadata
        softwareItem.key = "com.apple.quicktime.software" as NSString
        softwareItem.value = osVersion as NSString

        let dateItem = AVMutableMetadataItem()
        dateItem.keySpace = .quickTimeMetadata
        dateItem.key = "com.apple.quicktime.creationdate" as NSString
        dateItem.value = Date().description as NSString

        exportSession.metadata = [idItem, stillTimeItem, makeItem, modelItem, softwareItem, dateItem]

        // ---- 4. Export Asynchronously -----------------------------------------
        exportSession.exportAsynchronously {
            let success = (exportSession.status == .completed)
            if !success, let err = exportSession.error {
                NSLog("🍎 [LivePhotos] exportAsynchronously failed: %@", err.localizedDescription)
            }
            completion(success)
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
            request.addResource(with: .photo, fileURL: imageURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
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
        activeExportSession = nil
    }
}
