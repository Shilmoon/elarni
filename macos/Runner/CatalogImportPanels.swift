@preconcurrency import AVFoundation
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Vision

#if canImport(AppKit)
@MainActor
enum CatalogBackupFile {
  static func open() throws -> String {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.title = String(localized: "Restore Elarni backup")
    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var data = Data()
    while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
      guard data.count + chunk.count <= 12 * 1024 * 1024 else { throw SubscriptionError.feedTooLarge }
      data.append(chunk)
    }
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw SubscriptionError.invalidFeed }
    return text
  }

  static func save(_ text: String) throws {
    guard text.utf8.count <= 12 * 1024 * 1024 else { throw SubscriptionError.feedTooLarge }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Elarni-backup.json"
    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
    try Data(text.utf8).write(to: url, options: [.atomic])
  }
}

@MainActor
enum RoutingImportReader {
  private static var activeScanner: CameraQRScanner?

  static func file() throws -> String {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    // Closing the panel is a choice, not a failed import: the app stays silent, as for the panels above.
    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= 4 * 1024 * 1024,
          let content = String(data: data, encoding: .utf8) else {
      throw RoutingStoreError.invalidImport
    }
    return content
  }

  static func qrImage() throws -> String {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    // Closing the panel is a choice, not a failed import: the app stays silent, as for the panels above.
    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(url: url).perform([request])
    guard let content = request.results?.first?.payloadStringValue,
          content.utf8.count <= 4 * 1024 * 1024 else {
      throw RoutingStoreError.invalidImport
    }
    return content
  }

  static func camera() async throws -> String {
    let scanner = CameraQRScanner()
    activeScanner = scanner
    defer { activeScanner = nil }
    return try await scanner.scan()
  }
}

@MainActor
final class CameraQRScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, NSWindowDelegate {
  private var continuation: CheckedContinuation<String, Error>?
  private var session: AVCaptureSession?
  private var panel: NSPanel?
  private let captureQueue = DispatchQueue(label: "elarni.camera")

  func scan() async throws -> String {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCapture(allowed: true)
        case .notDetermined:
          AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            Task { @MainActor in self?.beginCapture(allowed: allowed) }
          }
        default: beginCapture(allowed: false)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }
  }

  private func beginCapture(allowed: Bool) {
    guard continuation != nil else { return }
    guard allowed else { return finish(.failure(RoutingStoreError.invalidImport)) }
    captureQueue.async {
      do {
        let session = try self.configureCapture()
        DispatchQueue.main.async {
          guard self.continuation != nil else { return }
          self.showPanel(session: session)
        }
      } catch {
        DispatchQueue.main.async { self.finish(.failure(error)) }
      }
    }
  }

  nonisolated private func configureCapture() throws -> AVCaptureSession {
    guard let camera = AVCaptureDevice.default(for: .video) else {
      throw RoutingStoreError.invalidImport
    }
    let session = AVCaptureSession()
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    let input = try AVCaptureDeviceInput(device: camera)
    guard session.canAddInput(input) else { throw RoutingStoreError.invalidImport }
    session.addInput(input)
    // Mac cameras may not expose QR metadata; Vision decodes their video frames.
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    guard session.canAddOutput(output) else { throw RoutingStoreError.invalidImport }
    session.addOutput(output)
    output.setSampleBufferDelegate(self, queue: captureQueue)
    return session
  }

  private func showPanel(session: AVCaptureSession) {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    panel.title = String(localized: "Scan QR code")
    let preview = NSView(frame: NSRect(x: 20, y: 55, width: 480, height: 325))
    preview.wantsLayer = true
    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
    previewLayer.frame = preview.bounds
    previewLayer.videoGravity = .resizeAspectFill
    preview.layer?.addSublayer(previewLayer)
    let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelScan))
    cancel.frame = NSRect(x: 220, y: 15, width: 80, height: 30)
    panel.contentView?.addSubview(preview)
    panel.contentView?.addSubview(cancel)
    self.session = session
    self.panel = panel
    panel.delegate = self
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    captureQueue.async { session.startRunning() }
  }

  nonisolated func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    do {
      guard let value = try Self.decodeFrame(image) else { return }
      Task { @MainActor in self.finish(.success(value)) }
    } catch {
      Task { @MainActor in self.finish(.failure(error)) }
    }
  }

  nonisolated static func decodeFrame(_ image: CVPixelBuffer) throws -> String? {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(cvPixelBuffer: image).perform([request])
    guard let value = request.results?.first?.payloadStringValue else { return nil }
    guard value.utf8.count <= 4 * 1024 * 1024 else { throw RoutingStoreError.invalidImport }
    return value
  }

  @objc private func cancelScan() {
    finish(.failure(CancellationError()))
  }

  func windowWillClose(_ notification: Notification) {
    finish(.failure(CancellationError()))
  }

  private func finish(_ result: Result<String, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    let session = self.session
    panel?.delegate = nil
    panel?.close()
    self.session = nil
    panel = nil
    // Start and stop share a queue; cancellation must join a queued start.
    captureQueue.async {
      session?.stopRunning()
      continuation.resume(with: result)
    }
  }
}
#endif
