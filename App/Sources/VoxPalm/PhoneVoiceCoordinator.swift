import Foundation
import VoxPalmLink
import VoxPalmVoice

/// 可信网络身份和语音会话的唯一绑定；不处理任意远端按键或鼠标消息。
@MainActor final class PhoneVoiceCoordinator {
    private let voice: VoiceSession
    private let allowed: () -> Bool
    private let feedback: (UUID, VoiceFeedback) -> Void
    private var current: (peer: UUID, audio: UUID)?
    private var outcome: VoiceFeedback.State?
    init(voice: VoiceSession, allowed: @escaping () -> Bool, feedback: @escaping (UUID, VoiceFeedback) -> Void) {
        self.voice = voice; self.allowed = allowed; self.feedback = feedback
    }
    func receive(_ message: LinkMessage, from peer: UUID) {
        switch message {
        case let .audioStart(id, format):
            guard allowed() else { send(peer, id, .unavailable); return }
            guard voice.settings.mode == .builtIn else { send(peer, id, .requiresBuiltIn); return }
            guard current == nil, voice.canStartVoice else { send(peer, id, .busy); return }
            current = (peer, id); outcome = nil
            if voice.beginRemoteAudio(id: id, sampleRate: format.sampleRate) { send(peer, id, .accepted) }
            else { current = nil; send(peer, id, .failed) }
        case let .audioChunk(id, _, pcm):
            guard owns(peer, id) else { return }
            if !voice.appendRemoteAudio(id: id, pcm: pcm) { cancel(peer: peer) }
        case let .audioEnd(id, _):
            guard owns(peer, id) else { return }; voice.endRemoteAudio(id: id)
        case let .audioCancel(id):
            guard owns(peer, id) else { return }; cancel(peer: peer)
        default: break
        }
    }
    func cancel(peer: UUID? = nil) {
        guard let old = current, peer == nil || old.peer == peer else { return }
        current = nil; outcome = nil
        voice.cancelRemoteAudio(id: old.audio)
        send(old.peer, old.audio, .cancelled)
    }
    func stateChanged(_ state: VoiceSession.State) {
        guard let active = current else { return }
        if state == .transcribing { send(active.peer, active.audio, .transcribing) }
        if state == .idle {
            let result = outcome ?? .cancelled
            current = nil; outcome = nil; send(active.peer, active.audio, result)
        }
    }
    func receivedOutcome(_ value: VoiceSession.Outcome) {
        guard current != nil else { return }
        switch value {
        case .inserted: outcome = .finished
        case .copied: outcome = .copied
        case .tooShort, .noAudio: outcome = .tooShort
        case .noText: outcome = .noText
        default: outcome = .failed
        }
    }
    private func owns(_ peer: UUID, _ id: UUID) -> Bool { current?.peer == peer && current?.audio == id }
    private func send(_ peer: UUID, _ id: UUID, _ state: VoiceFeedback.State) { feedback(peer, VoiceFeedback(id: id, state: state)) }
}
