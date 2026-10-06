// The `media` table (media.d.ts): audio / video players over AVPlayer (services/MediaPlayers.swift);
// ids are the manager's slots, stable for a player's whole life.
import Foundation
import LeCodesCore

final class MediaHost: HostMedia {
    let players = MediaPlayers()

    func createAudio(src: String, onFinished: JSCallback) -> Int32 { players.create(src, onFinished: onFinished) }
    func createVideo(src: String, onFinished: JSCallback) -> Int32 { players.create(src, onFinished: onFinished) }
    func setVolume(id: Int32, volume: Float) { players.setVolume(id, volume) }
    func setLoop(id: Int32, loop: Bool) { players.setLoop(id, loop) }
    func setPlaying(id: Int32, playing: Bool) { players.setPlaying(id, playing) }
    var time: ((Int32) -> Double)? { { [players] id in players.time(id) } }
    var setTime: ((Int32, Double) -> Void)? { { [players] id, t in players.setTime(id, t) } }
    var duration: ((Int32) -> Double)? { { [players] id in players.duration(id) } }
    var remove: ((Int32) -> Void)? { { [players] id in players.remove(id) } }

    func dispose() { players.removeAll() }
}
