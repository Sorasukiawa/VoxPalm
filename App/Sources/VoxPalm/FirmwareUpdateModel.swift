import Foundation

extension AppModel {
    var firmwareInstallationReady: Bool {
        !isDeviceStatusPreview && voiceState == .idle && !config.voice.keepMicWarm
            && !deviceStatus.isBusy && firmwareUpdates.busyID == nil
    }

    /// 只从独立确认按钮调用；安装时暂停监听，失败后保持暂停，避免状态未定时发送按键。
    func installFirmware(for id: String) {
        guard firmwareInstallationReady, devices.contains(where: { $0.id == id }), deviceStatusPageSelection == id else { return }
        let wasPaused = isPaused
        cancelLearning(); stopIdentifying(); setPaused(true)
        MicMeter.suspendForFirmwareUpdate(true)
        let started = firmwareUpdates.install(id: id) { [weak self] succeeded in
            MicMeter.suspendForFirmwareUpdate(false)
            guard let self else { return }
            self.refreshDevices()
            if succeeded { self.setPaused(wasPaused) }
        }
        if !started { MicMeter.suspendForFirmwareUpdate(false); setPaused(wasPaused) }
    }
}
