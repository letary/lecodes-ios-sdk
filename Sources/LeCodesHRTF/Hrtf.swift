// Binaural audio (`audio.hrtf` in the SDK) as a product of its own, because of what it weighs: the
// MIT KEMAR filters are 184 KB of tables. The audio engine never names them — this call does — and
// a PUBLIC Swift symbol is never dead-stripped, so the call cannot live in LeCodes: it would keep
// the tables in every binary that links the SDK. A target that wants the filters links LeCodesHRTF
// and calls `engine.useHrtf()`; one that does not (the viewer's App Clip) pans instead.
import CLeCodesCore
import LeCodes

public extension LeCodesEngine {
    /// Hand the filters to the audio engine. Before `start`: the engine reads them when it starts.
    func useHrtf() { lc_audioUseHrtf() }
}
