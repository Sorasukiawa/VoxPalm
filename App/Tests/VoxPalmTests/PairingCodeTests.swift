import CoreImage
import Foundation
import Testing
import VoxPalmLinkNetwork
@testable import VoxPalm

@Test func 二维码能完整还原一次性长配对码() throws {
    let invitation = try PairingInvitation(hostID: UUID())
    let code = try invitation.pairingCode()
    let image = try #require(PairingCodeImage.make(code))
    let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let features = detector.features(in: CIImage(cgImage: image))
    let decoded = try #require((features.first as? CIQRCodeFeature)?.messageString)
    #expect(decoded == code)
    #expect(try PairingInvitation(code: decoded).serviceName == invitation.serviceName)
}
