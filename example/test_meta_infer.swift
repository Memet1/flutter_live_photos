import AVFoundation
import CoreMedia

func test() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test4.mov")
    try? FileManager.default.removeItem(at: url)

    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let metaInput = AVAssetWriterInput(
        mediaType: .metadata,
        outputSettings: nil,
        sourceFormatHint: nil
    )
    let metaAdaptor = AVAssetWriterInputMetadataAdaptor(
        assetWriterInput: metaInput
    )
    writer.add(metaInput)
    writer.startWriting()

    // Start session
    let sourceTime = CMTime(seconds: 1.0, preferredTimescale: 600)
    writer.startSession(atSourceTime: sourceTime)

    let anchor = AVMutableMetadataItem()
    anchor.key = "com.apple.quicktime.still-image-time" as NSString
    anchor.keySpace = AVMetadataKeySpace(rawValue: "mdta")
    anchor.value = NSNumber(value: 0)  // Int8(0) or 0
    anchor.dataType = "com.apple.metadata.datatype.int8"

    let time = CMTime(seconds: 1.0, preferredTimescale: 600)
    let range = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 600))
    let group = AVTimedMetadataGroup(
        items: [anchor],
        timeRange: range
    )
    print("Appending...")
    metaAdaptor.append(group)
    print("Appended!")
}

test()
