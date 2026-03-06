import Photos

func testSave() {
    let imgURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let vidURL = URL(fileURLWithPath: CommandLine.arguments[2])
    
    let semaphore = DispatchSemaphore(value: 0)
    
    PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, fileURL: imgURL, options: nil)
        request.addResource(with: .pairedVideo, fileURL: vidURL, options: nil)
    }) { success, error in
        print("Success: \(success)")
        if let err = error as NSError? {
            print("Error: \(err.domain) \(err.code) \(err.localizedDescription)")
        } else if let err = error {
            print("Error: \(err.localizedDescription)")
        }
        semaphore.signal()
    }
    
    semaphore.wait()
}

// Request permission first
PHPhotoLibrary.requestAuthorization { status in
    if status == .authorized {
        testSave()
    } else {
        print("Not authorized: \(status.rawValue)")
        exit(1)
    }
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
