import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static let havenPurple = Color(red: 0.42, green: 0.18, blue: 0.56) // #6B2D8F
    static let havenPurpleLight = Color(red: 0.54, green: 0.30, blue: 0.69) // #8A4DB0
    static let havenPurpleDark = Color(red: 0.33, green: 0.14, blue: 0.44) // #542370
    static let havenPurplePale = Color(red: 0.42, green: 0.18, blue: 0.56).opacity(0.1)
    
    // Colors are now primarily defined here to ensure project-wide availability
    
    static var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }
}
