## 1.0.2

### Fixes & Improvements
- Fully replaced `AVAssetReader` / `AVAssetWriter` with `AVAssetExportSession` for video conversion and trimming, solving `KERN_INVALID_ADDRESS` crashes.
- Implemented global metadata matching the iOS Live Wallpaper standard (`com.apple.quicktime.still-image-time` set to 0, explicit `com.apple.quicktime.creationdate`).
- Adjusted the HEIC still image frame extraction to align perfectly with the `0` timing in metadata, ensuring seamless loop start when set as a wallpaper.
- Added package version logging upon calling the `generate` function.

## 1.0.1 (Bumped from 1.0.0 due to package rename)
- Renamed package to `live_photos_plus`.

## 1.0.0 BREAKING CHANGE: Full rewrite for iOS Live Wallpaper compatibility

### Breaking Changes
- Removed `videoURL` parameter from `generate()` — use `generateFromUrl()` instead
- Removed `openSettings()` method
- `generate()` now returns `LivePhotoResult` instead of `bool`
- SDK requirement: Dart >= 3.0.0, Flutter >= 3.10.0
- iOS minimum: 13.0 (was 11.0)
- Removed Android support (Android does not support Live Photos)

### New Features
- **HEIC output** with JPEG fallback — generates wallpaper-compatible still images
- **URL support** via `generateFromUrl()` — downloads and processes video from HTTP(S) URLs
- **LivePhotoResult** — returns HEIC/MOV file paths and error details
- **saveToGallery** flag — option to generate files without saving to Camera Roll
- **cleanUp()** — cleans up all temporary files
- **Silent audio synthesis** — generates empty AAC track for mute videos (required by iOS PosterBoard)
- **Multi-format support** — MP4, MOV, M4V, 3GP, and other AVFoundation-compatible formats
- **Session-scoped temp directory** — prevents temp file leaks
- **Safe error handling** — no force-unwraps, proper error propagation

### Fixes
- Fixed memory leaks (temp files now cleaned up)
- Fixed deprecated `kUTTypeJPEG` — uses `UTType` API
- Fixed tests to match current API
- Fixed example app to match current API

## 0.6.0 Internal refactoring

## 0.4.0 BREAKING CHANGE: null safety

## 0.3.0 Added a feature to convert local mp4 file to LivePhotos

## 0.2.0 Fixed the bugs rejected when reviewed in Apple

## 0.1.0 Adding a feature to open Settings Page

## 0.0.1 Pre Release
