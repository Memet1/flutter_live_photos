import 'dart:async';
import 'package:flutter/services.dart';

class LivePhotos {
  static const MethodChannel _channel = MethodChannel('live_photos');

  /// Генерує Live Photo. 
  /// [startTime] та [duration] передаються як double для точності до кадру (п. 4 аналізу).
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
      print("LivePhotos Plugin Error: $e");
      return false;
    }
  }
}
