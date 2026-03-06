import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Result of a Live Photo generation operation.
class LivePhotoResult {
  /// Whether the generation was successful.
  final bool success;

  /// Path to the generated HEIC still image (null on failure).
  final String? heicPath;

  /// Path to the generated MOV video (null on failure).
  final String? movPath;

  /// Error message if the generation failed.
  final String? error;

  const LivePhotoResult({
    required this.success,
    this.heicPath,
    this.movPath,
    this.error,
  });

  factory LivePhotoResult.fromMap(Map<dynamic, dynamic> map) {
    return LivePhotoResult(
      success: map['success'] as bool? ?? false,
      heicPath: map['heicPath'] as String?,
      movPath: map['movPath'] as String?,
      error: map['error'] as String?,
    );
  }

  @override
  String toString() =>
      'LivePhotoResult(success: $success, heicPath: $heicPath, '
      'movPath: $movPath, error: $error)';
}

/// Generates iOS-wallpaper-compatible Live Photos from video files or URLs.
///
/// Outputs a HEIC still image + MOV video pair with proper Apple metadata
/// (MakerNote, content.identifier, still-image-time) for use as Live Wallpapers
/// on iOS 17 and iOS 18 (PosterBoard Engine).
///
/// Supported input formats: MP4, MOV, M4V, 3GP, and other
/// AVFoundation-compatible containers.
class LivePhotosPlus {
  static const MethodChannel _channel = MethodChannel('live_photos_plus');

  /// Generates a Live Photo from either a remote [videoUrl] or a [localPath].
  ///
  /// Exactly one of [videoUrl] or [localPath] must be provided.
  ///
  /// - [videoUrl]:   Direct HTTP/HTTPS link to a .mp4 or .mov video.
  ///                 The native side downloads it to a temporary directory first.
  /// - [localPath]:  Absolute path to a video file already on disk.
  /// - [startTime]:  Start time **in seconds** (millisecond precision, e.g. 1.250).
  ///                 Defaults to 0.0.
  /// - [duration]:   Duration **in seconds** (millisecond precision, e.g. 3.000).
  ///                 Defaults to 3.0 (recommended for wallpapers).
  ///
  /// Returns a [LivePhotoResult] describing the outcome.
  ///
  /// ```dart
  /// // From a URL (AI-generated video from Runway/Luma)
  /// final result = await LivePhotos.generate(
  ///   videoUrl: 'https://example.com/ai_video.mp4',
  ///   startTime: 0.0,
  ///   duration: 3.0,
  /// );
  ///
  /// // From a local file
  /// final result = await LivePhotos.generate(
  ///   localPath: '/path/to/video.mov',
  ///   startTime: 1.5,
  ///   duration: 2.5,
  /// );
  ///
  /// if (result.success) {
  ///   print('HEIC: ${result.heicPath}');
  ///   print('MOV:  ${result.movPath}');
  /// } else {
  ///   print('Error: ${result.error}');
  /// }
  /// ```
  static Future<LivePhotoResult> generate({
    String? videoUrl,
    String? localPath,
    double startTime = 0.0,
    double duration = 3.0,
  }) async {
    // ---- Dart-side validation ------------------------------------------

    final bool hasUrl = videoUrl != null && videoUrl.isNotEmpty;
    final bool hasPath = localPath != null && localPath.isNotEmpty;

    if (!hasUrl && !hasPath) {
      return const LivePhotoResult(
        success: false,
        error: 'Either videoUrl or localPath must be provided.',
      );
    }

    if (hasUrl && hasPath) {
      return const LivePhotoResult(
        success: false,
        error: 'Provide only one of videoUrl or localPath, not both.',
      );
    }

    // Validate URL
    if (hasUrl) {
      final uri = Uri.tryParse(videoUrl);
      if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
        return LivePhotoResult(
          success: false,
          error: 'Invalid URL (must be http or https): $videoUrl',
        );
      }
    }

    // Validate local file existence
    if (hasPath && !File(localPath).existsSync()) {
      return LivePhotoResult(
        success: false,
        error: 'File not found: $localPath',
      );
    }

    if (startTime < 0) {
      return const LivePhotoResult(
        success: false,
        error: 'startTime must be >= 0.',
      );
    }

    if (duration <= 0) {
      return const LivePhotoResult(
        success: false,
        error: 'duration must be > 0.',
      );
    }

    // ---- Call native ----------------------------------------------------

    try {
      final result = await _channel.invokeMethod('generate', {
        if (hasUrl) 'videoUrl': videoUrl,
        if (hasPath) 'localPath': localPath,
        'startTime': startTime,
        'duration': duration,
      });
      return LivePhotoResult.fromMap(Map<dynamic, dynamic>.from(result));
    } on PlatformException catch (e) {
      return LivePhotoResult(
        success: false,
        error: 'PlatformException: ${e.message}',
      );
    } catch (e) {
      return LivePhotoResult(
        success: false,
        error: 'Unexpected error: $e',
      );
    }
  }

  /// Removes all temporary files created by previous `generate()` calls.
  ///
  /// Call this after the user has finished working with the generated files
  /// (e.g., after confirming the wallpaper looks correct).
  static Future<void> cleanUp() async {
    try {
      await _channel.invokeMethod('cleanUp');
    } catch (_) {
      // Silently ignore cleanup errors.
    }
  }
}
