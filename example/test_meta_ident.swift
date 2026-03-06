import AVFoundation

func test() {
    let anchor = AVMutableMetadataItem()
    anchor.identifier = AVMetadataIdentifier("mdta/com.apple.quicktime.still-image-time")
    print(anchor.key as Any)
    print(anchor.keySpace as Any)
    
    let anchor2 = AVMutableMetadataItem()
    anchor2.key = "com.apple.quicktime.still-image-time" as NSString
    anchor2.keySpace = AVMetadataKeySpace(rawValue: "mdta")
    print(anchor2.identifier as Any)
}

test()
