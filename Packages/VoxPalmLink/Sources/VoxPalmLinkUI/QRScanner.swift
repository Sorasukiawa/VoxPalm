#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

struct ScannerSheet: View {
    let completion: (String?) -> Void
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            ZStack {
                QRScanner(onCode: { completion($0) }, onProblem: { problem = $0 })
                VStack {
                    Text(problem ?? "对准 Mac 上掌声显示的二维码")
                        .padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                    Spacer()
                }.padding()
            }
            .navigationTitle("扫码配对").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { completion(nil) } } }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onProblem: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(onCode: onCode, onProblem: onProblem)
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.close() }
}

/// 相机配置与启停串行执行；没有音频输入，也不保存帧。
private final class CameraWorker: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.sorasukiawa.VoxPalm.qr-camera")
    private var configured = false
    func start(delegate: AVCaptureMetadataOutputObjectsDelegate, failure: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if !configured {
                session.beginConfiguration(); defer { session.commitConfiguration() }
                guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                      session.canAddInput(input) else { failure(); return }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { session.removeInput(input); failure(); return }
                session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    session.removeInput(input); session.removeOutput(output); failure(); return
                }
                output.setMetadataObjectsDelegate(delegate, queue: .main); output.metadataObjectTypes = [.qr]
                configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let worker = CameraWorker()
    private var preview: AVCaptureVideoPreviewLayer?
    private let onCode: (String) -> Void
    private let onProblem: (String) -> Void
    private var visible = false
    private var finished = false
    init(onCode: @escaping (String) -> Void, onProblem: @escaping (String) -> Void) {
        self.onCode = onCode; self.onProblem = onProblem; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: worker.session); layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer); preview = layer
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumed), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); visible = true; authorize() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); close() }
    @objc private func resigned() { worker.stop() }
    @objc private func resumed() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { start() }
    }
    private func authorize() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.visible, !self.finished else { return }
                    if granted { self.start() } else { self.onProblem("相机未获授权。可返回使用长码，或在系统设置中开启相机权限。") }
                }
            }
        default: onProblem("相机未获授权。可返回使用长码，或在系统设置中开启相机权限。")
        }
    }
    private func start() {
        guard visible, !finished, UIApplication.shared.applicationState == .active else { return }
        worker.start(delegate: self) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.visible, !self.finished else { return }
                self.onProblem("相机暂时不可用，请返回使用长码。")
            }
        }
    }
    func close() { visible = false; finished = true; worker.stop() }
    deinit { NotificationCenter.default.removeObserver(self); worker.stop() }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard visible, !finished, UIApplication.shared.applicationState == .active,
              let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              code.utf8.count <= 2048 else { return }
        guard code.hasPrefix("VOXPALM1:") else { onProblem("请扫描掌声的配对二维码。"); return }
        close(); onCode(code)
    }
}
#endif
