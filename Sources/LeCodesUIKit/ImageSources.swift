// An image's WIRE SPELLING (sdk/src/ui/UIImage.ts imageSrcWire: `svg:<markup>`, `id:<bufferId>`, a
// url) as a bitmap for a box — what a plugin's native half reads an image of its props with (the tab
// bar's icons, plugins/native-ui: a contract has no image type, an image crosses as its spelling). The
// image node's own pieces: ImageSourceKind reads the spelling, SvgDocuments renders an svg for the
// box, ImageLoader brings a url's bytes and decodes them down to the box. Public for the SDK package
// (hosts/apple/lecodes re-exports it: a half imports that module alone). Main thread: every call and
// every answer.
import UIKit

public enum ImageSources {
    /// A pending answer: after `cancel()` it never comes.
    public final class Request {
        fileprivate var token: ImageLoader.Token?
        fileprivate var isCancelled = false
        public func cancel() {
            isCancelled = true
            token?.cancel()
            token = nil
        }
    }

    /// `src` as a picture aspect-fitted into a box of `size` points, centred, at the screen's scale: an
    /// svg rendered for the box (its own colors: a caller that tints draws it as a template image), a
    /// raster buffer or a url's image drawn into it. nil = nothing to show: an empty or malformed
    /// spelling, a canvas surface or a live scene (no picture of their own outside a node), bytes that
    /// do not decode, a url that failed. Answered in the call (the request is nil then) or later, once,
    /// unless cancelled.
    @discardableResult
    public static func image(_ src: String, fitting size: CGSize, _ completion: @escaping (UIImage?) -> Void) -> Request? {
        switch ImageSourceKind.of(src) {
        case .svg(let markup):
            completion(SvgDocuments.get(markup).flatMap { SvgDocuments.bitmap($0, size: size, tint: nil) })
            return nil
        case .raster(let image):
            completion(image.map { fitted($0, into: size) })
            return nil
        case .url(let url):
            let request = Request()
            var answered = false
            let scale = UIScreen.main.scale
            let pw = Int((size.width * scale).rounded(.up)), ph = Int((size.height * scale).rounded(.up))
            request.token = ImageLoader.load(url) { source in
                guard !request.isCancelled else { return }
                request.token = nil
                guard let source else { answered = true; return completion(nil) }
                ImageLoader.decode(source, sample: ImageLoader.sampleFor(source, boxWidth: pw, boxHeight: ph)) { image in
                    guard !request.isCancelled else { return }
                    answered = true
                    completion(image.map { fitted($0, into: size) })
                }
            }
            return answered ? nil : request
        case .none, .canvas, .scene2d:
            completion(nil)
            return nil
        }
    }

    /// `image` aspect-fitted into a box of `size` points, centred, at the screen's scale.
    public static func fitted(_ image: UIImage, into box: CGSize) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return image }
        let k = min(box.width / size.width, box.height / size.height)
        let w = size.width * k, h = size.height * k
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: box, format: format).image { _ in
            image.draw(in: CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h))
        }
    }
}
