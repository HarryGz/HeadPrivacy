import AppKit
import SwiftUI
import HeadPrivacyCore

struct SettingsView: View {
    let controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Label("General", systemImage: "gear") }
                protection.tabItem { Label("Protection", systemImage: "rectangle.lefthalf.inset.filled") }
                detection.tabItem { Label("Detection", systemImage: "waveform") }
                displays.tabItem { Label("Displays", systemImage: "display.2") }
                failure.tabItem { Label("Failure Behavior", systemImage: "exclamationmark.shield") }
            }
            if let error = controller.serviceError {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding()
            }
        }
        .frame(width: 620, height: 540)
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: binding(\.launchAtLogin))
            if controller.hotkeyError != nil || controller.loginItemError != nil {
                Button("Retry System Integration") { Task { await controller.retrySystemIntegrations() } }
            }
            Toggle("Notify when head motion is interrupted", isOn: binding(\.notificationsEnabled))
            Button("Allow Notifications…") { Task { await controller.requestNotificationAuthorization() } }
                .disabled(!controller.settings.notificationsEnabled)
            if let message = controller.notificationAuthorizationMessage { Text(message).font(.callout) }
            Section("Pause / Resume Shortcut") {
                TextField("Key (A–Z or 0–9)", text: Binding(
                    get: { controller.settings.hotkeyDescriptor.key },
                    set: { value in edit { $0.hotkeyDescriptor.key = String(value.uppercased().prefix(1)) } }))
                HStack {
                    ForEach(HotkeyModifier.allCases, id: \.self) { modifier in
                        Toggle(modifier.rawValue.capitalized, isOn: Binding(
                            get: { controller.settings.hotkeyDescriptor.modifiers.contains(modifier) },
                            set: { enabled in edit {
                                if enabled { $0.hotkeyDescriptor.modifiers.insert(modifier) }
                                else { $0.hotkeyDescriptor.modifiers.remove(modifier) }
                            } }))
                    }
                }
                Text("Use at least one modifier. Registration errors appear below.").font(.caption)
            }
            Section("Motion Access") {
                Text("Allow HeadPrivacy in System Settings → Privacy & Security → Motion & Fitness. Wear supported AirPods, then recalibrate.")
                HStack {
                    Button("Open System Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                    Button("Calibrate Displays…", action: controller.requestRecalibration)
                }
            }
        }.formStyle(.grouped)
    }

    private var protection: some View {
        Form {
            Picker("Mode", selection: binding(\.protectionMode)) {
                Text("Full screen").tag(ProtectionMode.fullScreen)
                Text("Sides").tag(ProtectionMode.sides)
            }
            Picker("Preset", selection: binding(\.visualPreset)) {
                Text("Soft").tag(VisualPreset.soft)
                Text("Translucent").tag(VisualPreset.translucent)
                Text("Privacy").tag(VisualPreset.privacy)
            }
            Section("Advanced Appearance") {
                numeric("Opacity", value: binding(\.overlayOpacity), range: 0...1)
                numeric("Tint brightness", value: binding(\.tintBrightness), range: -1...1)
                numeric("Width of each side", value: binding(\.sideWidthFraction), range: 0.1...0.45)
            }
            Text("The display you face stays clear. System materials obscure other displays without capturing their contents.").font(.callout)
        }.formStyle(.grouped)
    }

    private var detection: some View {
        Form {
            numeric("Default zone half-width (°)", value: Binding(
                get: { controller.settings.zoneHalfWidth.degrees },
                set: { degrees in edit { $0.zoneHalfWidth = .init(degrees: degrees) } }), range: 5...90, step: 1)
            Text("Used for newly calibrated displays. Existing zones are edited in Displays.").font(.caption)
            numeric("Smoothing response", value: binding(\.filterAlpha),
                    range: AppSettings.filterAlphaRange, step: 0.05)
            Text("0.05 gives maximum smoothing; 1 responds immediately.").font(.caption)
            numeric("Switch dwell (ms)", value: durationBinding(\.switchDwell), range: 0...1000, step: 10)
            numeric("Away dwell (ms)", value: durationBinding(\.awayDwell), range: 0...1000, step: 10)
            numeric("Return dwell (ms)", value: durationBinding(\.returnDwell), range: 0...1000, step: 10)
        }.formStyle(.grouped)
    }

    private var displays: some View {
        Form {
            Text(controller.statusText).font(.headline)
            Text("After launch, wake, disconnection, or a display-layout change, use full recalibration to establish a safe reference. While tracking and the full layout remain valid, you can recalibrate one display without changing the others.").font(.callout)
            Button("Recalibrate All Display Centers…", action: controller.requestRecalibration)
            ForEach(controller.displayCalibrationSummaries) { summary in
                Section(summary.display.name) {
                    Text(summary.display.id.rawValue).font(.caption).textSelection(.enabled)
                    Text(summary.isCalibrated ? "Calibrated" : "Calibration required")
                    if !summary.display.isPersistable { Text("Display identity is ambiguous. Reconnect it before calibrating.") }
                    numeric("Zone half-width (°)", value: Binding(
                        get: { summary.halfWidthDegrees ?? controller.settings.zoneHalfWidth.degrees },
                        set: { _ = controller.updateDisplayWidth(summary.id, degrees: $0) }), range: 5...90, step: 1)
                        .disabled(!summary.isCalibrated || controller.isCalibrationActive)
                    Button("Recalibrate This Display…") {
                        controller.requestDisplayRecalibration(summary.id)
                    }
                    .disabled(!controller.canRecalibrateDisplay(summary.id))
                }
            }
            if controller.activeDisplays.isEmpty { Text("No active displays.") }
        }.formStyle(.grouped)
    }

    private var failure: some View {
        Form {
            Picker("When head motion is interrupted", selection: binding(\.failurePolicy)) {
                Text("Usability-first").tag(FailurePolicy.usabilityFirst)
                Text("Protection-first").tag(FailurePolicy.protectionFirst)
            }
            Text("Usability-first reveals displays if motion stops. Protection-first obscures all displays until you pause or tracking is ready. Use the global shortcut to pause and reveal.")
            Text("Setup and guided calibration keep displays clear. This app is a privacy aid, not a screen lock. Its overlays disappear if the app quits or crashes.")
            Text("No display capture, motion history, or telemetry is stored.").font(.callout)
        }.formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { controller.settings[keyPath: keyPath] }, set: { value in edit { $0[keyPath: keyPath] = value } })
    }

    private func edit(_ change: @escaping @MainActor (inout AppSettings) -> Void) {
        Task { @MainActor in
            var value = controller.settings
            change(&value)
            await controller.updateSettings(value)
        }
    }

    private func durationBinding(_ keyPath: WritableKeyPath<AppSettings, Duration>) -> Binding<Double> {
        Binding(get: {
            let components = controller.settings[keyPath: keyPath].components
            return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        }, set: { value in edit { $0[keyPath: keyPath] = .milliseconds(value) } })
    }

    private func numeric(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0.01) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))))
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}
