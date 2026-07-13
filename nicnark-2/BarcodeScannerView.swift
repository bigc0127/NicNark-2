//
//  BarcodeScannerView.swift
//  nicnark-2
//
//  Barcode scanning for can inventory.
//  Session ownership lives in file-level `BarcodeSessionController` (NOT on the
//  @MainActor UIViewController) so configure/start/stop are truly off-main under
//  SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
//

import SwiftUI
import AVFoundation

struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> BarcodeScannerViewController {
        let controller = BarcodeScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: BarcodeScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, BarcodeScannerDelegate {
        let parent: BarcodeScannerView
        init(_ parent: BarcodeScannerView) { self.parent = parent }
        func didScanBarcode(_ barcode: String) { parent.onScan(barcode) }
        func didCancel() { parent.dismiss() }
    }
}

protocol BarcodeScannerDelegate: AnyObject {
    func didScanBarcode(_ barcode: String)
    func didCancel()
}

// MARK: - Session owner (opt out of default MainActor isolation)

/// Owns `AVCaptureSession` on a private serial queue. Marked `nonisolated` so methods are
/// not MainActor under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (queue.async into MainActor
/// methods only *warns* and is not a real off-main design).
nonisolated final class BarcodeSessionController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nicnark.barcode.session")
    /// Bound only after configure; read on main for preview layer attach (AVCapture pattern).
    nonisolated(unsafe) private(set) var sessionForPreview: AVCaptureSession?
    private var session: AVCaptureSession?
    private var isConfigured = false
    private var generation: UInt64 = 0
    private var desiredRunning = false
    private weak var metadataProxy: BarcodeMetadataProxy?

    func setMetadataProxy(_ proxy: BarcodeMetadataProxy) {
        queue.async { [weak self] in self?.metadataProxy = proxy }
    }

    func requestConfigure(
        onPreviewReady: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [weak self] in
            self?.configureLocked(onPreviewReady: onPreviewReady, onError: onError)
        }
    }

    func setDesiredRunning(_ running: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = running
            if running {
                self.startLocked()
            } else {
                self.generation &+= 1
                self.stopLocked()
            }
        }
    }

    func stopForScanComplete() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    private func configureLocked(
        onPreviewReady: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        let gen = generation
        if isConfigured {
            startLocked()
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let device = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            DispatchQueue.main.async { onError("No camera available") }
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { onError("Camera input error") }
            return
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { onError("Could not add camera input") }
            return
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { onError("Could not add metadata output") }
            return
        }
        session.addOutput(metadataOutput)
        if let proxy = metadataProxy {
            metadataOutput.setMetadataObjectsDelegate(proxy, queue: DispatchQueue.main)
        }
        metadataOutput.metadataObjectTypes = [
            .ean8, .ean13, .pdf417, .qr, .code128, .code39, .code93, .upce
        ]

        session.commitConfiguration()
        guard gen == generation else { return }

        self.session = session
        self.sessionForPreview = session
        self.isConfigured = true
        DispatchQueue.main.async { onPreviewReady() }
        startLocked()
    }

    private func startLocked() {
        guard desiredRunning, let session, isConfigured, !session.isRunning else { return }
        session.startRunning()
    }

    private func stopLocked() {
        guard let session, session.isRunning else { return }
        session.stopRunning()
    }
}

/// Nonisolated metadata bridge so session queue never captures MainActor VC.
nonisolated final class BarcodeMetadataProxy: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    var onCode: (@Sendable (String) -> Void)?

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = readable.stringValue else { return }
        onCode?(value)
    }
}

// MARK: - View controller (MainActor UI only)

class BarcodeScannerViewController: UIViewController {
    weak var delegate: BarcodeScannerDelegate?

    private let sessionController = BarcodeSessionController()
    private let metadataProxy = BarcodeMetadataProxy()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        metadataProxy.onCode = { [weak self] value in
            DispatchQueue.main.async { self?.handleScannedCode(value) }
        }
        sessionController.setMetadataProxy(metadataProxy)
        requestCameraAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPreviewGeometry()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionController.setDesiredRunning(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Bumps generation + stops — cancels any in-flight start after dismiss.
        sessionController.setDesiredRunning(false)
    }

    private func requestCameraAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSessionConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.beginSessionConfigure()
                    } else {
                        self.showPermissionDeniedAlert()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDeniedAlert()
        @unknown default:
            showPermissionDeniedAlert()
        }
    }

    private func beginSessionConfigure() {
        sessionController.requestConfigure(
            onPreviewReady: { [weak self] in
                DispatchQueue.main.async { self?.attachPreview() }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async { self?.showError(message) }
            }
        )
    }

    private func handleScannedCode(_ stringValue: String) {
        guard !hasScanned else { return }
        hasScanned = true
        sessionController.stopForScanComplete()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        delegate?.didScanBarcode(stringValue)
    }

    private func attachPreview() {
        guard let session = sessionController.sessionForPreview else { return }
        previewLayer?.removeFromSuperlayer()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        applyPreviewGeometry()
    }

    private func applyPreviewGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = view.layer.bounds
        CATransaction.commit()

        guard let connection = previewLayer?.connection else { return }
        let angle: CGFloat
        switch view.window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: angle = 180
        case .landscapeRight: angle = 0
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private func setupUI() {
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        cancelButton.layer.cornerRadius = 8
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        view.addSubview(cancelButton)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),
            cancelButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        let guideView = UIView()
        guideView.layer.borderColor = UIColor.white.cgColor
        guideView.layer.borderWidth = 2
        guideView.layer.cornerRadius = 8
        guideView.backgroundColor = .clear
        view.addSubview(guideView)
        guideView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            guideView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guideView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            guideView.widthAnchor.constraint(equalToConstant: 280),
            guideView.heightAnchor.constraint(equalToConstant: 140)
        ])

        let instructionLabel = UILabel()
        instructionLabel.text = "Align barcode within frame"
        instructionLabel.textColor = .white
        instructionLabel.font = .systemFont(ofSize: 16)
        instructionLabel.textAlignment = .center
        instructionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        instructionLabel.layer.cornerRadius = 8
        instructionLabel.clipsToBounds = true
        view.addSubview(instructionLabel)
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            instructionLabel.topAnchor.constraint(equalTo: guideView.bottomAnchor, constant: 20),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.widthAnchor.constraint(equalToConstant: 200),
            instructionLabel.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    @objc private func cancelTapped() {
        sessionController.setDesiredRunning(false)
        delegate?.didCancel()
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Scanner Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.delegate?.didCancel()
        })
        present(alert, animated: true)
    }

    private func showPermissionDeniedAlert() {
        let alert = UIAlertController(
            title: "Camera Access Needed",
            message: "Enable camera access in Settings to scan barcodes.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.delegate?.didCancel()
        })
        present(alert, animated: true)
    }
}


