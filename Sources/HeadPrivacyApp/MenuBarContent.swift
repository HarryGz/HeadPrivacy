import AppKit
import SwiftUI
import HeadPrivacyCore

struct MenuBarContent: View {
    let controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(controller.statusText)
        if let name = controller.currentDisplayName { Text("Viewing: \(name)") }
        if controller.isCalibrationActive { Text("Calibration in progress") }
        if let error = controller.serviceError { Text(error) }
        Divider()
        if controller.isPaused {
            Button("Resume Protection", action: controller.togglePause)
                .disabled(!controller.canResumeProtection)
        } else {
            Button("Pause Protection", action: controller.togglePause)
                .disabled(!controller.canPauseProtection)
        }
        if let shortcut = controller.registeredHotkey { Text("Global shortcut: \(shortcut.displayLabel)") }
        Button("Temporarily Reveal All", action: controller.temporarilyRevealAll)
            .disabled(!controller.canTemporarilyRevealAll)
        if controller.needsMotionPermission {
            Button("Retry Motion Access", action: controller.retryMotionPermission)
            Button("Motion Access Help…", action: showSettings)
        }
        Button(controller.isCalibrationActive ? "Show Calibration…" : "Recalibrate Displays…",
               action: controller.requestRecalibration)
        Divider()
        Button("Settings…", action: showSettings).keyboardShortcut(",")
        Button("Quit HeadPrivacy", action: controller.quit).keyboardShortcut("q")
    }

    private func showSettings() {
        controller.onSettingsRequested = {
            NSApplication.shared.activate()
            openSettings()
        }
        controller.openSettings()
    }
}

extension AppController {
    var statusText: String {
        if needsMotionPermission { return "Motion access required" }
        if isCalibrationActive { return "Protection paused for calibration" }
        if calibrationRequired { return "Calibrate displays to enable protection" }
        switch status {
        case .paused: return "Protection paused"
        case .connecting: return "Connecting to AirPods…"
        case .permissionRequired: return "Motion access required"
        case .headphonesUnavailable: return "Head motion unavailable"
        case .calibrationRequired: return "Calibration required"
        case .protecting: return "Protecting all displays"
        case .viewing: return "Protection active"
        }
    }
}

extension HotkeyDescriptor {
    var displayLabel: String {
        [(HotkeyModifier.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }
}
