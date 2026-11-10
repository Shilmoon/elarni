import AVFoundation
import CoreImage.CIFilterBuiltins
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum IOSImport {
  static func readText(_ url: URL, limit: Int = 4 * 1024 * 1024) throws -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= limit else { throw IOSAppError.invalidFile }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= limit, let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw IOSAppError.invalidFile }
    return text
  }

  static func decodeQR(_ data: Data) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      guard data.count <= 24 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 2560,
              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw IOSAppError.invalidFile }
      let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
      let values: Set<String>
      do {
        try VNImageRequestHandler(cgImage: image).perform([request])
        values = Set((request.results ?? []).compactMap(\.payloadStringValue))
      } catch {
        // Some Simulator runtimes ship an incomplete Vision filter bundle.
        // Core Image provides a public QR decoder without that Vision request.
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        values = Set((detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString })
        if values.isEmpty { throw error }
      }
      guard !values.isEmpty else { throw IOSAppError.invalidFile }
      return values.sorted().joined(separator: "\n")
    }.value
  }

  @MainActor static func qr(_ text: String) -> UIImage? {
    if let last = lastQR, last.text == text { return last.image }
    let generator = CIFilter.qrCodeGenerator()
    generator.message = Data(text.utf8)
    var result: UIImage?
    if let output = generator.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
       let image = CIContext().createCGImage(output, from: output.extent) { result = UIImage(cgImage: image) }
    lastQR = (text, result)
    return result
  }
  // A view asks again on every pass over its body; the code of one text is drawn once.
  @MainActor private static var lastQR: (text: String, image: UIImage?)?
}

struct TextFile: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText, .json, .data] }
  var text: String
  init(_ text: String) { self.text = text }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents, let value = String(data: data, encoding: .utf8) else { throw IOSAppError.invalidFile }
    text = value
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// A recording ZIP already on disk, saved through the Files exporter.
struct RecordingFile: FileDocument {
  static var readableContentTypes: [UTType] { [.zip] }
  var url: URL?
  init(url: URL? = nil) { self.url = url }
  init(configuration: ReadConfiguration) throws { throw IOSAppError.invalidFile }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    guard let url else { throw IOSAppError.recordingFailed }
    return try FileWrapper(url: url)
  }
}

struct SharedText: Identifiable { let id = UUID(); let title: String; let text: String }

struct ShareView: View {
  let item: SharedText
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var exporting = false
  @State private var copied = false
  var body: some View {
    NavigationStack {
      let qr = IOSImport.qr(item.text)
      AppList {
        Section {
          if let image = qr {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
              .padding(16).background(.white).clipShape(.rect(cornerRadius: 12))
              .accessibilityLabel("QR code for \(item.title)")
          } else { Text("This configuration is too large for a single QR code. Copy it or save it to Files.").foregroundStyle(AppPalette.secondary) }
        } footer: { Text("This export may contain private server credentials. Share it only with people you trust.") }
        Section {
          Button(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: "doc.on.doc") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: item.text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]); copied = true }
          ShareLink(item: item.text) { Label("Share", systemImage: "square.and.arrow.up") }
          if let qr {
            // Scanners need a light margin around the code.
            let image = Image(uiImage: UIGraphicsImageRenderer(size: CGSize(width: qr.size.width + 64, height: qr.size.height + 64)).image { context in
              UIColor.white.setFill(); context.fill(context.format.bounds); qr.draw(at: CGPoint(x: 32, y: 32))
            })
            ShareLink(item: image, preview: SharePreview(item.title, image: image)) { Label("Share QR code", systemImage: "qrcode") }
          }
          Button("Save to Files", systemImage: "folder") { exporting = true }
        }
      }
      .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .fileExporter(isPresented: $exporting, document: TextFile(item.text), contentType: .plainText, defaultFilename: "Elarni-export") { result in
        if case .failure(let error) = result { model.show(error) }
      }.appErrors()
    }
  }
}

struct QRScannerView: View {
  let completion: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var message: String?
  @State private var photo: PhotosPickerItem?
  @State private var decoding = false
  @State private var delivered = false
  @State private var imageError = false
  var body: some View {
    NavigationStack {
      ZStack {
        CameraScanner(message: $message) { value in finish(value) }.ignoresSafeArea(edges: .bottom)
        VStack {
          Spacer()
          Text(message ?? String(localized: "Point the camera at a configuration QR code."))
            .font(.callout).multilineTextAlignment(.center).padding().background(.regularMaterial, in: .rect(cornerRadius: 16)).padding()
          if message != nil { Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!).buttonStyle(.borderedProminent).padding(.bottom) }
        }
      }
      .navigationTitle("Scan QR code").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          PhotosPicker(selection: $photo, matching: .images) {
            Image(systemName: "photo").frame(width: 44, height: 44)
          }.accessibilityLabel("Import QR image").accessibilityIdentifier("qrImage").disabled(decoding || delivered)
        }
      }
      .overlay { if decoding { ProgressView("Reading QR image…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
      .task(id: photo) {
        guard let photo else { return }
        decoding = true
        defer { decoding = false; self.photo = nil }
        do {
          guard let data = try await photo.loadTransferable(type: Data.self) else { throw IOSAppError.invalidFile }
          let text = try await IOSImport.decodeQR(data)
          try Task.checkCancellation()
          finish(text)
        } catch is CancellationError {} catch { imageError = true }
      }
      .alert("Couldn’t read QR image", isPresented: $imageError) { Button("OK", role: .cancel) {} }
        message: { Text("Choose an image containing a configuration QR code, or scan with the camera.") }
    }
  }
  private func finish(_ text: String) {
    guard !delivered else { return }
    delivered = true; completion(text); dismiss()
  }
}

private struct CameraScanner: UIViewControllerRepresentable {
  @Binding var message: String?
  let completion: (String) -> Void
  func makeUIViewController(context: Context) -> ScannerController {
    let controller = ScannerController()
    controller.onMessage = { message = $0 }; controller.onValue = completion
    return controller
  }
  func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
  static func dismantleUIViewController(_ uiViewController: ScannerController, coordinator: ()) { uiViewController.stop() }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  let session = AVCaptureSession()
  let queue = DispatchQueue(label: "elarni.ios.camera")
  var onMessage: ((String) -> Void)?
  var onValue: ((String) -> Void)?
  var preview: AVCaptureVideoPreviewLayer?
  private var stopped = false // Main thread, including permission callbacks.
  private var delivered = false
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .black
    AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self, !self.stopped else { return }
        guard allowed else { self.onMessage?(String(localized: "Allow camera access in Settings to scan a QR code, or import an image.")); return }
        self.configure()
      }
    }
  }
  private func configure() {
    do {
      guard let camera = AVCaptureDevice.default(for: .video) else { throw IOSAppError.invalidFile }
      let input = try AVCaptureDeviceInput(device: camera)
      let output = AVCaptureMetadataOutput()
      guard session.canAddInput(input), session.canAddOutput(output) else { throw IOSAppError.invalidFile }
      session.addInput(input); session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
      let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill
      layer.frame = view.bounds; view.layer.addSublayer(layer); preview = layer
      queue.async { [session] in session.startRunning() }
    } catch { onMessage?(String(localized: "The camera is unavailable. Import a QR image instead.")) }
  }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
  func stop() { stopped = true; queue.async { [session] in session.stopRunning() } }
  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard !delivered, !stopped, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
    delivered = true; stop(); onValue?(value)
  }
}
