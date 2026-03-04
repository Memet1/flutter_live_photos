import AVFoundation
import MobileCoreServices
import Photos
import ImageIO

internal class LivePhotoGenerator {
    
    // Використовуємо послідовну чергу для синхронізації доступу до рідера та райтера
    private let workQueue = DispatchQueue(label: "dev.mebelok.vivashot.processing")
    private var assetReader: AVAssetReader?
    private var assetWriter: AVAssetWriter?
    
    // Метод для створення Live Photo, сумісного зі шпалерами
    func createLivePhoto(videoURL: URL, imageURL: URL, outputVideoURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        let assetIdentifier = UUID().uuidString
        
        // Крок 1: Оновлення метаданих зображення
        guard let imageData = try? Data(contentsOf: imageURL),
              let updatedImageData = injectMetadataToImage(data: imageData, assetIdentifier: assetIdentifier) else {
            completion(false, NSError(domain: "LivePhotoError", code: 1, userInfo:))
            return
        }
        
        do {
            try updatedImageData.write(to: imageURL)
        } catch {
            completion(false, error)
            return
        }
        
        // Крок 2: Перекодування відео з додаванням UUID та Timed Metadata
        processVideo(sourceURL: videoURL, targetURL: outputVideoURL, assetIdentifier: assetIdentifier) { success in
            completion(success, nil)
        }
    }
    
    private func processVideo(sourceURL: URL, targetURL: URL, assetIdentifier: String, completion: @escaping (Bool) -> Void) {
        let asset = AVAsset(url: sourceURL)
        
        // Завантажуємо треки перед ініціалізацією рідера
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError? = nil
            guard asset.statusOfValue(forKey: "tracks", error: &error) ==.loaded,
                  let videoTrack = asset.tracks(withMediaType:.video).first else {
                completion(false)
                return
            }
            
            do {
                self.assetReader = try AVAssetReader(asset: asset)
                self.assetWriter = try AVAssetWriter(outputURL: targetURL, fileType:.mov)
                
                // Налаштування виходу відео (декодування)
                let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings:)
                self.assetReader?.add(readerOutput)
                
                // Налаштування входу відео (кодування)
                let videoSettings: =
                let writerInput = AVAssetWriterInput(mediaType:.video, outputSettings: videoSettings)
                writerInput.transform = videoTrack.preferredTransform
                self.assetWriter?.add(writerInput)
                
                // Додавання глобального ідентифікатора (ОБОВ'ЯЗКОВО для шпалер)
                let identifierItem = AVMutableMetadataItem()
                identifierItem.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
                identifierItem.keySpace =.quickTimeMetadata
                identifierItem.value = assetIdentifier as NSString
                identifierItem.dataType = kCMMetadataBaseDataType_UTF8 as String
                self.assetWriter?.metadata = [identifierItem]
                
                // Створення доріжки Timed Metadata для синхронізації шпалер
                let timedMetadataSpec: =
                
                var formatDescription: CMFormatDescription?
                CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                    allocator: kCFAllocatorDefault,
                    metadataType: kCMMetadataFormatType_Boxed,
                    metadataSpecifications: as CFArray,
                    formatDescriptionOut: &formatDescription
                )
                
                let metadataInput = AVAssetWriterInput(mediaType:.metadata, outputSettings: nil, sourceFormatHint: formatDescription)
                let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
                self.assetWriter?.add(metadataInput)
                
                // Початок читання та запису
                self.assetReader?.startReading()
                self.assetWriter?.startWriting()
                self.assetWriter?.startSession(atSourceTime:.zero)
                
                writerInput.requestMediaDataWhenReady(on: self.workQueue) {
                    while writerInput.isReadyForMoreMediaData {
                        // КЛЮЧОВЕ ВИПРАВЛЕННЯ: Безпечне вилучення рідера та перевірка його стану
                        guard let reader = self.assetReader, reader.status ==.reading else {
                            writerInput.markAsFinished()
                            return
                        }
                        
                        if let buffer = readerOutput.copyNextSampleBuffer() {
                            writerInput.append(buffer)
                            
                            // Додаємо мітку часу "заморозки" шпалер для кожного кадру
                            // (Apple Wallpaper Engine вибере найбільш релевантний кадр)
                            let stillImageItem = AVMutableMetadataItem()
                            stillImageItem.key = "com.apple.quicktime.still-image-time" as NSString
                            stillImageItem.keySpace =.quickTimeMetadata
                            stillImageItem.value = -1 as NSNumber
                            stillImageItem.dataType = kCMMetadataBaseDataType_SInt8 as String
                            
                            let presentationTime = CMSampleBufferGetPresentationTimeStamp(buffer)
                            let metadataGroup = AVTimedMetadataGroup(items: [stillImageItem], timeRange: CMTimeRange(start: presentationTime, duration:.invalid))
                            metadataAdaptor.append(metadataGroup)
                        } else {
                            writerInput.markAsFinished()
                            metadataInput.markAsFinished()
                            
                            self.assetWriter?.finishWriting {
                                completion(self.assetWriter?.status ==.completed)
                                // Очищення посилань для запобігання витоку пам'яті
                                self.assetReader = nil
                                self.assetWriter = nil
                            }
                            break
                        }
                    }
                }
            } catch {
                completion(false)
            }
        }
    }
    
    private func injectMetadataToImage(data: Data, assetIdentifier: String) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) else { return nil }
        
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, uti, 1, nil) else { return nil }
        
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any]?? [:]
        let makerApple: = ["17": assetIdentifier]
        properties = makerApple
        
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        if CGImageDestinationFinalize(destination) {
            return outputData as Data
        }
        return nil
    }
}
