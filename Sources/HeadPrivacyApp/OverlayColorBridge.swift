import AppKit
import SwiftUI
import HeadPrivacyCore

extension OverlayColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    init?(swiftUIColor: Color) {
        self.init(appKitColor: NSColor(swiftUIColor))
    }

    init?(appKitColor: NSColor) {
        guard let srgb = appKitColor.usingColorSpace(.sRGB),
              srgb.redComponent.isFinite, srgb.greenComponent.isFinite,
              srgb.blueComponent.isFinite else { return nil }
        self = OverlayColor(red: srgb.redComponent, green: srgb.greenComponent,
                            blue: srgb.blueComponent).validated()
    }
}
