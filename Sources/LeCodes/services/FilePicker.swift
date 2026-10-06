// The OS file picker (device.openFilePicker) and the share sheet (device.share): PHPicker when
// `accept` names only images / videos, the document picker otherwise. Presented on the key
// window's top view controller.
import Foundation
import UIKit
import UniformTypeIdentifiers
import PhotosUI

struct PickedFile {
    let name: String
    let data: Data
}

final class FilePicker: NSObject {
    private var completion: (([PickedFile]) -> Void)?

    /// Present the picker; `completion` gets the files ([] = cancelled) on the main thread.
    func open(accept: [String], multiple: Bool, completion: @escaping ([PickedFile]) -> Void) {
        self.completion = completion
        DispatchQueue.main.async {
            guard let top = FilePicker.topViewController() else { completion([]); self.completion = nil; return }
            if let photos = self.makePhotoPicker(accept: accept, multiple: multiple) { top.present(photos, animated: true) }
            else { top.present(self.makeDocumentPicker(accept: accept, multiple: multiple), animated: true) }
        }
    }

    /// The system share sheet for a buffer (an image when it decodes as one, the bytes otherwise).
    func share(_ data: Data, _ text: String?) {
        DispatchQueue.main.async {
            guard let top = FilePicker.topViewController() else { return }
            var items: [Any] = []
            if let image = UIImage(data: data) { items.append(image) }
            else {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString).bin")
                try? data.write(to: tmp)
                items.append(tmp)
            }
            if let text, !text.isEmpty, text != "undefined" { items.append(text) }
            let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = activity.popoverPresentationController {   // iPad: a popover needs a source
                popover.sourceView = top.view
                popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            top.present(activity, animated: true)
        }
    }

    // MARK: - Private

    private func finish(_ files: [PickedFile]) {
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(files) }
    }

    private func makePhotoPicker(accept: [String], multiple: Bool) -> PHPickerViewController? {
        guard !accept.isEmpty, accept.allSatisfy({ $0 == "image/*" || $0 == "video/*" }) else { return nil }
        var config = PHPickerConfiguration()
        // A photo is stored as HEIC and a video as HEVC, which little outside Apple's own reads: the
        // system hands over JPEG / H.264 instead (what Safari does for a page's file input).
        config.preferredAssetRepresentationMode = .compatible
        config.selectionLimit = multiple ? 0 : 1
        if accept.contains("image/*") && accept.contains("video/*") { config.filter = .any(of: [.images, .videos]) }
        else if accept.contains("video/*") { config.filter = .videos }
        else { config.filter = .images }
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        return picker
    }

    private func makeDocumentPicker(accept: [String], multiple: Bool) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: FilePicker.types(accept))
        picker.allowsMultipleSelection = multiple
        picker.delegate = self
        return picker
    }

    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// `accept` as the SDK hands it over — an HTML <input accept> list ("image/*,video/*",
    /// ".jpg, .png") — split into its entries, the way Android's FilePickerHandler splits it;
    /// nil / "" = no filter.
    static func tokens(_ accept: String?) -> [String] {
        (accept ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The document picker's filter, a type per entry: ".pdf" and a bare "pdf" by extension,
    /// "application/pdf" by MIME type. A MIME type UTType does not know ("*/*", "application/*")
    /// comes back as a DYNAMIC type no file on disk carries — a filter that greys every file out —
    /// so it is dropped (an unknown EXTENSION stays: its files carry that very type). None left =
    /// any file.
    static func types(_ accept: [String]) -> [UTType] {
        let types = accept.compactMap { value -> UTType? in
            switch value {
            case "image/*": return .image
            case "video/*": return .movie
            case "audio/*": return .audio
            case "text/*": return .text
            default:
                if value.hasPrefix(".") { return UTType(filenameExtension: String(value.dropFirst())) }
                guard value.contains("/") else { return UTType(filenameExtension: value) }
                guard let type = UTType(mimeType: value), !type.isDynamic else { return nil }
                return type
            }
        }
        return types.isEmpty ? [.data] : types
    }

    private static func read(_ url: URL) -> PickedFile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return PickedFile(name: url.lastPathComponent, data: (try? Data(contentsOf: url)) ?? Data())
    }
}

extension FilePicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.map(FilePicker.read))
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
}

extension FilePicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { finish([]); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [PickedFile] = []
        for result in results {
            group.enter()
            let provider = result.itemProvider
            let identifier = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let file = FilePicker.read(url)
                lock.lock(); files.append(file); lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in self?.finish(files) }
    }
}
