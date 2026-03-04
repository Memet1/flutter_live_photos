import 'dart:async';
import 'package:flutter/services.dart';

class LivePhotos {
  static const MethodChannel _channel = MethodChannel('live_photos');

  /// Generates a Live Photo natively from a local video file.
  /// [localPath] - The absolute path to the local video file.
  /// [startTime] - The exact start time in seconds (e.g., 2.533).
  /// [duration] - The exact duration in seconds (e.g., 3.000). Max for iOS Lock Screen is 3.0.
  static Future<bool> generate({
    required String localPath,
    double startTime = 0.0,
    double duration = 0.0,
  }) async {
    try {
      final bool result = await _channel.invokeMethod('generateFromLocalPath', {
        'localPath': localPath,
        'startTime': startTime,
        'duration': duration,
      });
      return result;
    } catch (e) {
      print("LivePhotos Error: $e");
      return false;
    }
  }
}
