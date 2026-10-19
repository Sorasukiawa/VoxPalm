import Foundation
import MediaPlayer

/// 系统「正在播放」通道（MPRemoteCommandCenter）。蓝牙耳机、遥控器的 AVRCP 播放控制，
/// 系统会发给当前「正在播放」的 App，所以要先把自己登记成正在播放。
public final class RemoteCommandMonitor {
    public struct Event: Sendable {
        public let time: Double
        public let command: String
        /// 快进、快退命令带「开始 / 结束」，相当于按下和松开。
        public let phase: String?
        public let detail: String?
    }

    public var onEvent: ((Event) -> Void)?

    private var registrations: [(MPRemoteCommand, Any)] = []

    public init() {}

    deinit {
        stop()
    }

    public func start(title: String) {
        guard registrations.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let simple: [(MPRemoteCommand, String)] = [
            (center.playCommand, "play"), (center.pauseCommand, "pause"), (center.togglePlayPauseCommand, "togglePlayPause"),
            (center.stopCommand, "stop"), (center.nextTrackCommand, "nextTrack"), (center.previousTrackCommand, "previousTrack"),
            (center.changeRepeatModeCommand, "changeRepeatMode"), (center.changeShuffleModeCommand, "changeShuffleMode"),
            (center.likeCommand, "like"), (center.dislikeCommand, "dislike"), (center.bookmarkCommand, "bookmark"),
            (center.enableLanguageOptionCommand, "enableLanguageOption"), (center.disableLanguageOptionCommand, "disableLanguageOption"),
            (center.changePlaybackRateCommand, "changePlaybackRate"), (center.ratingCommand, "rating"),
        ]
        for (command, name) in simple {
            add(command) { [weak self] _ in self?.emit(name, phase: nil, detail: nil) }
        }
        for (command, name) in [(center.seekForwardCommand, "seekForward"), (center.seekBackwardCommand, "seekBackward")] {
            add(command) { [weak self] event in
                let begin = (event as? MPSeekCommandEvent)?.type == .beginSeeking
                self?.emit(name, phase: begin ? "begin" : "end", detail: nil)
            }
        }
        for (command, name) in [(center.skipForwardCommand, "skipForward"), (center.skipBackwardCommand, "skipBackward")] {
            add(command) { [weak self] event in
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 0
                self?.emit(name, phase: nil, detail: "interval=\(interval)")
            }
        }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            self?.emit("changePlaybackPosition", phase: nil, detail: "position=\(position)")
        }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: 3600.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        info.playbackState = .playing
    }

    public func stop() {
        guard !registrations.isEmpty else { return }
        for (command, token) in registrations {
            command.removeTarget(token)
        }
        registrations.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { event in
            handler(event)
            return .success
        }
        registrations.append((command, token))
    }

    private func emit(_ command: String, phase: String?, detail: String?) {
        let event = Event(time: MonotonicClock.now(), command: command, phase: phase, detail: detail)
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }
}
