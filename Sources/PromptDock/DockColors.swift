import SwiftUI

struct DockColors {
    let dark: Bool

    var background: Color { color(0xF5F5F7, 0x1C1C1E) }
    var sidebar: Color { color(0xEFEFF2, 0x17171A) }
    var surface: Color { color(0xFBFBFD, 0x242428) }
    var preview: Color { color(0xF2F3F6, 0x1E1E22) }
    var ink: Color { color(0x1D1D1F, 0xF5F5F7) }
    var body: Color { color(0x3A3A40, 0xD5D5DC) }
    var secondary: Color { color(0x5A5D68, 0xAAB0BC) }
    var accent: Color { color(0x005EBF, 0x83B8FF) }
    var action: Color { color(0x0065CF, 0x2169CC) }
    var selection: Color { color(0xE4EEFC, 0x243750) }
    var iconSelected: Color { color(0xD6E7FD, 0x2F4869) }
    var line: Color { color(0xDEDFE5, 0x36363B) }
    var outline: Color { color(0xD4D5DD, 0x4B4B53) }
    var control: Color { color(0xECECF0, 0x303036) }
    var warning: Color { color(0x9B400F, 0xFFC18A) }

    private func color(_ light: UInt32, _ darkValue: UInt32) -> Color {
        let value = dark ? darkValue : light
        return Color(.sRGB,
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255
        )
    }
}
