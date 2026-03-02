#if os(iOS)
@preconcurrency import AVFoundation
import AudioToolbox
import SwiftUI
import UIKit

struct QRCodeScannerSheet: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onScanned = onScanned
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

final class QRCodeScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmitResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let captureSession, !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let captureSession, captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        _ = output
        _ = connection
        guard !didEmitResult else { return }
        guard let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              object.type == .qr,
              let value = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return
        }
        didEmitResult = true
        captureSession?.stopRunning()
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onScanned?(value)
    }

    private func configureCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.setupCaptureSession()
                    } else {
                        self.onError?("Camera access is required to scan Hub QR.")
                    }
                }
            }
        case .denied, .restricted:
            onError?("Camera access is disabled. Enable it in iOS Settings.")
        @unknown default:
            onError?("Unable to access camera for QR scanning.")
        }
    }

    private func setupCaptureSession() {
        guard captureSession == nil else {
            if let captureSession, !captureSession.isRunning {
                captureSession.startRunning()
            }
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            onError?("Unable to start camera for QR scanning.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            onError?("Unable to read QR metadata from camera.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)

        captureSession = session
        previewLayer = layer
        session.startRunning()
    }
}
#endif
