// What the linked engine archive is: the Swift side of lc_variant / lc_features (lecodes-core.h).
// build-apple.sh links ONE variant into the package (LeCodesEngine.xcframework); a host reports it
// (the project-bundle feature check the CLI's `lecodes app` reads) and the tests assert it.
import CLeCodesCore

public enum Engine {
    /// "full" | "3d" | "2d" | "core" — the variant build-apple.sh built the linked archive as.
    public static var variant: String { String(cString: lc_variant()) }

    /// The engine features compiled in: a subset of `gl physics 2d net nav audio`.
    public static var features: Set<String> {
        Set(String(cString: lc_features()).split(separator: ",").map(String.init))
    }
}
