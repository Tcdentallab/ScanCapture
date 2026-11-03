import ARKit
import AVFoundation
import CoreImage
import UIKit

/// Runs an ARKit session and takes a full-resolution photo every time the
/// phone has moved or turned enough. Saves each photo plus its camera pose
/// and intrinsics to a scan folder in the app's Documents directory.
final class CaptureModel: NSObject, ObservableObject, ARSessionDelegate {

    let session = ARSession()

    // UI state (main thread only)
    @Published var isScanning = false
    @Published var shotCount = 0
    @Published var status = "Point at the face, then press Start"

    // ---- Trigger settings (change these to tune the scan) ----
    /// Take a new photo after the phone moves this far (meters).
    let minDistance: Float = 0.03
    /// Or after the phone turns this much (radians). 4 degrees.
    let minAngle: Float = 4 * .pi / 180
    /// Do not take a photo if the phone moves faster than this (m/s). Avoids blur.
    let maxLinearSpeed: Float = 0.15
    /// Do not take a photo if the phone turns faster than this (rad/s).
    let maxAngularSpeed: Float = 0.6
    // -----------------------------------------------------------

    private(set) var scanFolder: URL?
    private var lastShotPose: simd_float4x4?
    private var prevPose: simd_float4x4?
    private var prevTime: TimeInterval?
    private var isBusy = false
    private var nextIndex = 1
    private var poseLog: [[String: Any]] = []          // saveQueue only
    private let saveQueue = DispatchQueue(label: "scan.save")
    private let ciContext = CIContext()

    // MARK: - Session

    func startSession() {
        let config = ARWorldTrackingConfiguration()
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        session.delegate = self
        session.run(config)
    }

    // MARK: - Start / stop

    func startScan() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "Scan_" + formatter.string(from: Date())
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            status = "Cannot create scan folder"
            return
        }
        scanFolder = folder
        lastShotPose = nil
        nextIndex = 1
        shotCount = 0
        saveQueue.sync { poseLog = [] }
        lockCamera(true)
        isScanning = true
        status = "Scanning. Move slowly around the face."
    }

    func stopScan() {
        isScanning = false
        lockCamera(false)
        status = "Stopped. \(shotCount) photos saved."
    }

    /// Locks focus and exposure so every photo has the same look.
    private func lockCamera(_ lock: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if lock {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
            device.unlockForConfiguration()
        } catch {
            // If locking fails, the scan still works. Photos may vary in brightness.
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pose = frame.camera.transform
        defer {
            prevPose = pose
            prevTime = frame.timestamp
        }
        guard isScanning, !isBusy else { return }

        guard case .normal = frame.camera.trackingState else {
            setStatus("Tracking lost. Hold still.")
            return
        }

        // Skip if the phone moves too fast (motion blur).
        if let pp = prevPose, let pt = prevTime, frame.timestamp > pt {
            let dt = Float(frame.timestamp - pt)
            let speed = simd_distance(pose.translation, pp.translation) / dt
            let turn = angle(between: pp, pose) / dt
            if speed > maxLinearSpeed || turn > maxAngularSpeed {
                setStatus("Too fast. Slow down.")
                return
            }
        }

        // First photo, or enough movement since the last photo?
        if let last = lastShotPose {
            let moved = simd_distance(pose.translation, last.translation)
            let turned = angle(between: last, pose)
            guard moved >= minDistance || turned >= minAngle else {
                setStatus("Scanning. Move slowly around the face.")
                return
            }
        }

        capture(into: scanFolder)
    }

    // MARK: - Capture and save

    private func capture(into folder: URL?) {
        guard let folder else { return }
        isBusy = true
        session.captureHighResolutionFrame { [weak self] hiRes, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let hiRes else {
                    self.isBusy = false
                    self.setStatus("Photo failed. Try again.")
                    return
                }
                let index = self.nextIndex
                self.nextIndex += 1
                self.lastShotPose = hiRes.camera.transform
                self.saveQueue.async {
                    let ok = self.save(hiRes, index: index, folder: folder)
                    DispatchQueue.main.async {
                        if ok { self.shotCount = index }
                        self.isBusy = false
                    }
                }
            }
        }
    }

    /// Saves one JPEG and updates poses.json. Runs on saveQueue.
    private func save(_ frame: ARFrame, index: Int, folder: URL) -> Bool {
        let fileName = String(format: "img_%04d.jpg", index)
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                of: image,
                colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
              ) else { return false }
        do {
            try jpeg.write(to: folder.appendingPathComponent(fileName))
        } catch {
            return false
        }

        let k = frame.camera.intrinsics
        let t = frame.camera.transform
        let flat: [Double] = (0..<4).flatMap { c in (0..<4).map { r in Double(t[c][r]) } }
        poseLog.append([
            "file": fileName,
            "timestamp": frame.timestamp,
            "width": Int(frame.camera.imageResolution.width),
            "height": Int(frame.camera.imageResolution.height),
            "fx": Double(k[0][0]),
            "fy": Double(k[1][1]),
            "cx": Double(k[2][0]),
            "cy": Double(k[2][1]),
            "transform_column_major": flat
        ])
        if let data = try? JSONSerialization.data(withJSONObject: ["images": poseLog],
                                                  options: [.prettyPrinted]) {
            try? data.write(to: folder.appendingPathComponent("poses.json"))
        }
        return true
    }

    // MARK: - Export

    /// Makes a .zip of the current scan folder for the share sheet.
    func zipScan() -> URL? {
        guard let folder = scanFolder else { return nil }
        var result: URL?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder,
                                       options: [.forUploading],
                                       error: &coordinatorError) { zipURL in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(folder.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: zipURL, to: dest)
                result = dest
            } catch {
                result = nil
            }
        }
        return result
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        if status != text { status = text }
    }

    private func angle(between a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let qa = simd_quatf(a)
        let qb = simd_quatf(b)
        let d = abs(simd_dot(qa.vector, qb.vector))
        return 2 * acos(min(1, d))
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}
