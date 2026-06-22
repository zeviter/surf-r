import Foundation
import Vision
import CoreImage

/// Decode QR payload strings from an image's bytes via Vision — **no camera entitlement**. Used to
/// read an `otpauth://` or `otpauth-migration://` QR from a screenshot/photo the user supplies.
enum QRDecoder {
    static func decodeQRStrings(imageData: Data) -> [String] {
        guard let image = CIImage(data: imageData) else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}
