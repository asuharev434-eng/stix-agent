import SwiftUI
import AVFoundation

struct PairingView: View {
    @EnvironmentObject private var store: RemoteChatStore
    @State private var manualCode = ""
    @State private var cameraAllowed = false
    @State private var cameraDenied = false
    @State private var scanVersion = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 32, weight: .medium)).foregroundStyle(.white)
                    Text("STIX").font(.system(size: 32, weight: .semibold)).tracking(4).foregroundStyle(.white)
                    Text("Наведите камеру на QR-код в чате на Mac")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.08))
                    if cameraAllowed {
                        QRScannerView { code in Task { await store.pair(code) } }
                            .id(scanVersion)
                            .clipShape(RoundedRectangle(cornerRadius: 26))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: cameraDenied ? "camera.fill" : "qrcode.viewfinder")
                                .font(.system(size: 48)).foregroundStyle(.white.opacity(0.55))
                            Text(cameraDenied ? "Разрешите доступ к камере в настройках iPhone" : "Открываем камеру…")
                                .font(.footnote).foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }.padding()
                    }
                    RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.55), lineWidth: 2)
                        .frame(width: 245, height: 245).allowsHitTesting(false)
                }.frame(maxWidth: 390).aspectRatio(1, contentMode: .fit)
                VStack(spacing: 9) {
                    Text("На Mac напишите /mobile").font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    Text("Оба устройства должны использовать один Apple Account для подключения через интернет.")
                        .font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                }
                Button {
                    store.useOfflineMode()
                } label: {
                    Label("Работать без Mac", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                if let error = store.error {
                    Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("Сканировать снова") { scanVersion += 1 }.foregroundStyle(.white)
                }
                HStack {
                    TextField("Или вставьте код", text: $manualCode).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().textFieldStyle(.plain).foregroundStyle(.white)
                    Button("Подключить") { Task { await store.pair(manualCode) } }
                        .disabled(manualCode.isEmpty)
                }.padding(14).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            }.padding(28)
        }
        .task { await requestCamera() }
    }

    private func requestCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { cameraAllowed = true; return }
        if status == .notDetermined { cameraAllowed = await AVCaptureDevice.requestAccess(for: .video) }
        cameraDenied = !cameraAllowed
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.scanned = scanned
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var scanned: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        preview.frame = view.bounds
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = view.bounds
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              code.hasPrefix("stixagent://pair/") else { return }
        delivered = true
        scanned?(code)
    }
}
