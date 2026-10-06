// The SDK's own assets on iOS (the default IBL, the uber-shader archive, the materials archive,
// the fonts): a `LeCodesResources.bundle` the app target carries (build-apple.sh stages it —
// step 6), searched before the app's main bundle. `localAsset` backs HostFetch.local so hosts never
// have to know about them; `systemBuffer` the engine's blobs, which the RUNTIME reads — the host
// hands a file over and never opens it.
import Foundation

public enum LeCodesResources {
    static let bundleName = "LeCodesResources"

    /// Bundles a host registered, searched first (a SwiftPM app target's Bundle.module is
    /// invisible to the scan below).
    private static var registered: [Bundle] = []
    public static func register(_ bundle: Bundle) { registered.append(bundle) }

    private static let candidates: [Bundle] = {
        var out: [Bundle] = []
        var seen = Set<URL>()
        func add(_ b: Bundle?) { if let b, seen.insert(b.bundleURL).inserted { out.append(b) } }
        add(Bundle.module)   // the package's own Assets/ (build-apple.sh stages them)
        if let url = Bundle.main.url(forResource: bundleName, withExtension: "bundle") { add(Bundle(url: url)) }
        add(.main)
        return out
    }()

    /// A bundled file by full name ("neutral_ibl.ktx"); nil when no bundle has it.
    public static func localAsset(_ fileName: String) -> Data? {
        let ext = (fileName as NSString).pathExtension
        let name = (fileName as NSString).deletingPathExtension
        for bundle in registered + candidates {
            // The package copies its folder whole (Assets/<file>); a host bundle carries files flat.
            for sub in ["Assets", nil] {
                if let url = bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext, subdirectory: sub) {
                    return try? Data(contentsOf: url)
                }
            }
        }
        return nil
    }

    /// The engine's built-in blobs by system id (fetch.d.ts systemBuffer): 1 = the default IBL,
    /// 2 = the ubershader archive, 3 = the materials archive — every built-in material in one zstd
    /// frame (engines/gl/materials/pack.mjs), out of which `_creator.builtinMaterial` reads by name.
    static func systemBuffer(_ id: Int32) -> Data? {
        switch id {
        case 1: return localAsset("neutral_ibl.ktx")
        case 2: return localAsset("uberarchive.bin")
        case 3: return localAsset("materials.bin")
        default: return nil
        }
    }
}
