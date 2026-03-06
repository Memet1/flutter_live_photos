import AVFoundation
import CoreMedia

func test() {
    let stillImageTimeSpec: NSDictionary = [
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
            "mdta/com.apple.quicktime.still-image-time",
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
            "com.apple.metadata.datatype.int8",
    ]
    var metaDesc: CMFormatDescription?
    let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: nil,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [stillImageTimeSpec] as CFArray,
        formatDescriptionOut: &metaDesc
    )

    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test3.mov")
    try? FileManager.default.removeItem(at: url)

    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let metaInput = AVAssetWriterInput(
        mediaType: .metadata,
        outputSettings: nil,
        sourceFormatHint: metaDesc
    )
    let metaAdaptor = AVAssetWriterInputMetadataAdaptor(
        assetWriterInput: metaInput
    )
    writer.add(metaInput)
    writer.startWriting()

    // Start session at t=1.0s
    let sourceTime = CMTime(seconds: 1.0, preferredTimescale: 600)
    writer.startSession(atSourceTime: sourceTime)

    let anchor = AVMutableMetadataItem()
    anchor.key = "com.apple.quicktime.still-image-time" as NSString
    anchor.keySpace = AVMetadataKeySpace(rawValue: "mdta")
    anchor.value = NSNumber(value: 0)  // Int8(0) or 0
    anchor.dataType = "com.apple.metadata.datatype.int8"

    // Append metadata at t=0.5s ? (LESS THAN sourceTime)
    let badTime = CMTime(seconds: 0.5, preferredTimescale: 600)
    let range = CMTimeRange(start: badTime, duration: CMTime(value: 1, timescale: 600))
    let group = AVTimedMetadataGroup(
        items: [anchor],
        timeRange: range
    )
    print("Appending...")
    metaAdaptor.append(group)
    print("Appended!")
}

test()
