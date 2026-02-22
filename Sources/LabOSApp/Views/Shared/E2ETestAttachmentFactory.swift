#if os(iOS)
import Foundation
import LabOSCore
import UIKit

enum E2ETestAttachmentFactory {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LABOS_E2E_ENABLE_TEST_PHOTO"] == "1"
    }

    static func makeFixturePhotoAttachment(name: String = "e2e-fixture-photo.jpg") -> ComposerAttachment? {
        guard let data = makeFixturePhotoData() else { return nil }
        return ComposerAttachment(
            displayName: name,
            mimeType: "image/jpeg",
            inlineDataBase64: data.base64EncodedString(),
            byteCount: data.count
        )
    }

    private static func makeFixturePhotoData() -> Data? {
        let size = CGSize(width: 480, height: 320)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let canvas = CGRect(origin: .zero, size: size)
            UIColor.systemBlue.setFill()
            context.fill(canvas)

            UIColor.systemYellow.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 250, y: 70, width: 170, height: 170))

            UIColor.white.withAlphaComponent(0.8).setFill()
            context.fill(CGRect(x: 26, y: 220, width: 430, height: 66))

            let title = "LABOS E2E"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            title.draw(at: CGPoint(x: 34, y: 227), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.92)
    }
}
#endif
