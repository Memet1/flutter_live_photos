# live_photos

Generate **iOS-wallpaper-compatible Live Photos** from video files or URLs.

This is a fork of [live_photos](https://pub.dev/packages/live_photos) with full support for generating Live Photos that can be used as **iOS Live Wallpapers**.

## Features

- 🎬 **Generate from local files** — MP4, MOV, M4V, 3GP, and other AVFoundation-compatible formats
- 🌐 **Generate from URLs** — downloads and processes automatically
- 📸 **HEIC output** — generates HEIC still image (with JPEG fallback)
- 🎵 **Silent audio track** — automatically synthesized for mute videos (required by iOS PosterBoard)
- 🔗 **Apple metadata** — correct MakerNote + content.identifier + still-image-time linkage
- ⚡ **Passthrough video** — no re-encoding, preserves original quality
- 🧹 **Memory management** — session-scoped temp files with cleanup API
- 📱 **iOS only** — Live Photos are an iOS-exclusive feature

## Requirements

- iOS 13.0+
- Flutter 3.10+
- Dart 3.0+

## Setup

### 1. Add dependency

```yaml
dependencies:
  live_photos:
    git:
      url: https://github.com/YuheiNakasaka/flutter_live_photos
```

### 2. Add to Info.plist

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>To save Live Photos to your Camera Roll.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>To save Live Photos to your Camera Roll.</string>
```

## Usage

### Generate from local file

```dart
import 'package:live_photos/live_photos.dart';

final result = await LivePhotos.generate(
  localPath: '/path/to/video.mp4',
  startTime: 0.0,   // start at 0 seconds
  duration: 3.0,     // 3 second clip (recommended for wallpapers)
);

if (result.success) {
  print('HEIC: ${result.heicPath}');
  print('MOV: ${result.movPath}');
} else {
  print('Error: ${result.error}');
}
```

### Generate from URL

```dart
final result = await LivePhotos.generateFromUrl(
  videoUrl: 'https://example.com/video.mp4',
  duration: 3.0,
);

if (result.success) {
  print('Saved to Camera Roll!');
}
```

### Generate without saving to Camera Roll

```dart
final result = await LivePhotos.generate(
  localPath: '/path/to/video.mp4',
  saveToGallery: false, // only generate files
);

// Use result.heicPath and result.movPath
```

### Clean up temp files

```dart
await LivePhotos.cleanUp();
```

## API

### `LivePhotos.generate()`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `localPath` | `String` | required | Absolute path to video file |
| `startTime` | `double` | `0.0` | Start time in seconds |
| `duration` | `double` | `3.0` | Duration in seconds |
| `saveToGallery` | `bool` | `true` | Save to Camera Roll |

### `LivePhotos.generateFromUrl()`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `videoUrl` | `String` | required | HTTP(S) URL to video |
| `startTime` | `double` | `0.0` | Start time in seconds |
| `duration` | `double` | `3.0` | Duration in seconds |
| `saveToGallery` | `bool` | `true` | Save to Camera Roll |

### `LivePhotoResult`

| Property | Type | Description |
|----------|------|-------------|
| `success` | `bool` | Whether generation succeeded |
| `heicPath` | `String?` | Path to generated HEIC file |
| `movPath` | `String?` | Path to generated MOV file |
| `error` | `String?` | Error message on failure |

## Setting as Live Wallpaper

iOS does not allow apps to set wallpapers programmatically. After generating:

1. Open **Photos** app
2. Find the Live Photo
3. Tap **Share** → **Use as Wallpaper**

Or: **Settings** → **Wallpaper** → **Add New** → **Photos** → select the Live Photo.

## Supported Input Formats

AVFoundation natively supports: **MP4**, **MOV**, **M4V**, **3GP**, and other QuickTime-compatible formats.

## License

BSD License. See [LICENSE](LICENSE).