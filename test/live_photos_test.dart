import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_photos_plus/live_photos.dart';

void main() {
  const MethodChannel channel = MethodChannel('live_photos');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'generate':
          final args = methodCall.arguments as Map;
          final localPath = args['localPath'] as String?;
          final videoUrl = args['videoUrl'] as String?;

          if (localPath != null && localPath.isNotEmpty) {
            return {
              'success': true,
              'heicPath': '/tmp/live_photos_session/test.heic',
              'movPath': '/tmp/live_photos_session/test.mov',
            };
          }
          if (videoUrl != null && videoUrl.isNotEmpty) {
            return {
              'success': true,
              'heicPath': '/tmp/live_photos_session/url.heic',
              'movPath': '/tmp/live_photos_session/url.mov',
            };
          }
          return {'success': false, 'error': 'No source'};

        case 'cleanUp':
          return null;

        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // ---------------------------------------------------------------------------
  // LivePhotoResult
  // ---------------------------------------------------------------------------

  group('LivePhotoResult', () {
    test('fromMap — success case', () {
      final r = LivePhotoResult.fromMap({
        'success': true,
        'heicPath': '/a.heic',
        'movPath': '/a.mov',
      });
      expect(r.success, true);
      expect(r.heicPath, '/a.heic');
      expect(r.movPath, '/a.mov');
      expect(r.error, isNull);
    });

    test('fromMap — failure case', () {
      final r = LivePhotoResult.fromMap({
        'success': false,
        'error': 'boom',
      });
      expect(r.success, false);
      expect(r.heicPath, isNull);
      expect(r.error, 'boom');
    });

    test('fromMap — missing keys defaults to false', () {
      final r = LivePhotoResult.fromMap({});
      expect(r.success, false);
    });

    test('toString is readable', () {
      final r = LivePhotoResult(success: true, heicPath: '/x.heic');
      expect(r.toString(), contains('success: true'));
      expect(r.toString(), contains('/x.heic'));
    });
  });

  // ---------------------------------------------------------------------------
  // Dart-side validation (these never reach native code)
  // ---------------------------------------------------------------------------

  group('LivePhotos.generate() — Dart validation', () {
    test('error when neither videoUrl nor localPath provided', () async {
      final r = await LivePhotos.generate();
      expect(r.success, false);
      expect(r.error, contains('Either'));
    });

    test('error when BOTH videoUrl and localPath provided', () async {
      final r = await LivePhotos.generate(
        videoUrl: 'https://example.com/v.mp4',
        localPath: '/some/path.mp4',
      );
      expect(r.success, false);
      expect(r.error, contains('not both'));
    });

    test('error for non-http URL', () async {
      final r = await LivePhotos.generate(videoUrl: 'ftp://bad.com/v.mp4');
      expect(r.success, false);
      expect(r.error, contains('http'));
    });

    test('error for malformed URL', () async {
      final r = await LivePhotos.generate(videoUrl: 'not a url at all');
      expect(r.success, false);
      expect(r.error, contains('Invalid URL'));
    });

    test('error for file not found', () async {
      final r = await LivePhotos.generate(
        localPath: '/nonexistent/video.mp4',
      );
      expect(r.success, false);
      expect(r.error, contains('not found'));
    });

    test('error for negative startTime', () async {
      final r = await LivePhotos.generate(
        videoUrl: 'https://example.com/v.mp4',
        startTime: -1.0,
      );
      expect(r.success, false);
      expect(r.error, contains('startTime'));
    });

    test('error for zero/negative duration', () async {
      final r = await LivePhotos.generate(
        videoUrl: 'https://example.com/v.mp4',
        duration: 0.0,
      );
      expect(r.success, false);
      expect(r.error, contains('duration'));
    });
  });

  // ---------------------------------------------------------------------------
  // cleanUp
  // ---------------------------------------------------------------------------

  group('LivePhotos.cleanUp()', () {
    test('completes without error', () async {
      await LivePhotos.cleanUp(); // should not throw
    });
  });
}
