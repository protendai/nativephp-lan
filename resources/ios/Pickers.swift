import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// File and photo/video pickers for Lan.PickFiles / Lan.PickMedia.
///
/// Mirrors Android's PickFilesFragment: FilesPicking {count} as soon as the
/// user confirms (so the UI can show placeholders), then FilesPicked
/// {files: [{path, name, size}]} once everything is copied into
/// tmp/picked-documents/<uuid>/<name>. Cancelling sends FilesPicked with [].
/// The delegate is a long-lived singleton because pickers hold it weakly.
final class TumaPickers: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {

    static let shared = TumaPickers()

    private let copyQueue = DispatchQueue(label: "com.tuma.lan.pickers", qos: .userInitiated)

    // MARK: Presenting

    func presentDocuments(mimeTypes: [String]) -> Bool {
        let types = mimeTypes.compactMap { $0 == "*/*" ? UTType.item : UTType(mimeType: $0) }
        return present {
            // asCopy: iOS hands back plain files in our tmp dir, no security-scoped access needed.
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types, asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            return picker
        }
    }

    func presentMedia() -> Bool {
        return present {
            var config = PHPickerConfiguration()
            config.selectionLimit = 0 // unlimited
            config.filter = .any(of: [.images, .videos])
            config.preferredAssetRepresentationMode = .current // no transcoding of HEVC videos
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            return picker
        }
    }

    private func present(_ make: @escaping () -> UIViewController) -> Bool {
        var presented = false
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                    ?? scene.windows.first?.rootViewController else {
                semaphore.signal()
                return
            }
            while let next = top.presentedViewController { top = next }
            top.present(make(), animated: true) {
                presented = true
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 2)
        return presented
    }

    // MARK: Documents

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        LanManager.shared.dispatch("FilesPicking", ["count": urls.count])
        copyQueue.async {
            let files = urls.compactMap { self.copyIn($0, name: $0.lastPathComponent) }
            LanManager.shared.dispatch("FilesPicked", ["files": files])
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        LanManager.shared.dispatch("FilesPicked", ["files": []])
    }

    // MARK: Photos & videos

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        if results.isEmpty {
            LanManager.shared.dispatch("FilesPicked", ["files": []])
            return
        }

        LanManager.shared.dispatch("FilesPicking", ["count": results.count])

        let group = DispatchGroup()
        let lock = NSLock()
        var files: [(Int, [String: Any])] = []

        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            // Prefer the video, then the image; the first type that loads wins.
            let typeId = [UTType.movie, UTType.image]
                .map(\.identifier)
                .first { provider.hasItemConformingToTypeIdentifier($0) }
                ?? provider.registeredTypeIdentifiers.first
            guard let typeId = typeId else { continue }

            group.enter()
            // The URL is only valid inside this callback, so copy synchronously here.
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                let suggested = provider.suggestedName.map { name -> String in
                    name.contains(".") ? name : name + "." + url.pathExtension
                } ?? url.lastPathComponent
                if let file = self.copyIn(url, name: suggested) {
                    lock.lock()
                    files.append((index, file))
                    lock.unlock()
                }
            }
        }

        group.notify(queue: copyQueue) {
            let ordered = files.sorted { $0.0 < $1.0 }.map(\.1)
            LanManager.shared.dispatch("FilesPicked", ["files": ordered])
        }
    }

    // MARK: Copying

    /// Copy (or move, for our own tmp copies) into tmp/picked-documents/<uuid>/<name>.
    private func copyIn(_ source: URL, name: String) -> [String: Any]? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("picked-documents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(LanManager.sanitize(name))
            try fm.copyItem(at: source, to: destination)
            let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            return ["path": destination.path, "name": destination.lastPathComponent, "size": size]
        } catch {
            NSLog("TumaLan: could not copy picked file \(source.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
