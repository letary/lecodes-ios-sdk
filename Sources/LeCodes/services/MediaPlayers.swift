// AVPlayer players behind the SDK AudioPlayer / VideoPlayer (media.d.ts). Ids are slots from 1,
// never reused (a player's id stays valid for its whole life). The `onFinished` handle of a player
// is the runtime's trampoline: BORROWED, called at every play-through end (the host loops itself
// when asked — the runtime only tracks ownership), freed on remove. A video player's frames can
// feed an engine texture (createTexture: an AVPlayerItemVideoOutput pumped into an external texture
// once per frame, before the runtime's — the frame mutates the scene ahead of beginFrame). Main
// thread only.
import Foundation
import AVFoundation
import LeCodesCore

final class MediaPlayers {
    private struct Player {
        let av: AVPlayer
        let onFinished: JSCallback
        var loop = false
    }
    private var players: [Int32: Player] = [:]
    private var nextId: Int32 = 1
    private var endObserver: NSObjectProtocol?
    /// The video outputs feeding engine textures (HostGL.createMediaPlayerTexture).
    private var outputs: [(output: AVPlayerItemVideoOutput, texture: UInt32, player: AVPlayer)] = []

    init() {
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            self?.didPlayToEnd(note.object as? AVPlayerItem)
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// A player for `src`; -1 (and the handle freed) when the URL is unusable.
    func create(_ src: String, onFinished: JSCallback) -> Int32 {
        guard let url = URL(string: src) else { Core.free(onFinished); return -1 }
        let id = nextId
        nextId += 1
        players[id] = Player(av: AVPlayer(url: url), onFinished: onFinished)
        return id
    }

    func player(_ id: Int32) -> AVPlayer? { players[id]?.av }

    func setVolume(_ id: Int32, _ volume: Float) { players[id]?.av.volume = volume }
    func setLoop(_ id: Int32, _ loop: Bool) { players[id]?.loop = loop }
    func setPlaying(_ id: Int32, _ playing: Bool) {
        guard let p = players[id] else { return }
        if playing { p.av.play() } else { p.av.pause() }
    }
    func time(_ id: Int32) -> Double {
        guard let av = players[id]?.av else { return 0 }
        let t = CMTimeGetSeconds(av.currentTime())
        return t.isNaN ? 0 : t
    }
    func setTime(_ id: Int32, _ time: Double) {
        players[id]?.av.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }
    /// 0 until the item's duration metadata is known.
    func duration(_ id: Int32) -> Double {
        guard let item = players[id]?.av.currentItem else { return 0 }
        let d = item.duration
        guard d.isValid, !d.isIndefinite else { return 0 }
        let s = CMTimeGetSeconds(d)
        return s.isNaN ? 0 : s
    }

    /// Release the player and its handle (a texture it fed stops updating; the engine owns it).
    func remove(_ id: Int32) {
        guard let p = players.removeValue(forKey: id) else { return }
        p.av.pause()
        outputs.removeAll { $0.player === p.av }
        Core.free(p.onFinished)
    }

    // MARK: - the frames as an engine texture

    /// A video player's frames as an external engine texture, pumped by `updateTextures` every
    /// frame while the player plays; 0 = no such player / item, or no engine.
    func createTexture(_ id: Int32) -> UInt32 {
        guard let player = players[id]?.av, let item = player.currentItem else { return 0 }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let texture = Core.createExternalTexture()
        guard texture != 0 else { item.remove(output); return 0 }
        outputs.append((output, texture, player))
        return texture
    }

    /// Before the runtime's frame: every playing output's new frame into its texture.
    func updateTextures() {
        for (output, texture, player) in outputs where player.timeControlStatus == .playing {
            let time = player.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            Core.updateTexture(texture, pixelBuffer: buffer)
        }
    }

    func removeAll() { for id in Array(players.keys) { remove(id) } }

    private func didPlayToEnd(_ item: AVPlayerItem?) {
        guard let item, let (id, p) = players.first(where: { $0.value.av.currentItem === item }) else { return }
        if p.loop {
            p.av.seek(to: .zero)
            p.av.play()
        }
        _ = id
        // JS last: it turns the report into loopReached (loop) or completed (no loop).
        Core.callBorrowed(p.onFinished)
    }
}
