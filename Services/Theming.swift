import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static let havenPurple = Color(red: 139/255, green: 92/255, blue: 246/255)
    static let havenPurpleDark = Color(red: 109/255, green: 40/255, blue: 217/255)
    static let havenPurpleLight = Color(red: 167/255, green: 139/255, blue: 250/255)
    static let havenPurplePale = Color(red: 139/255, green: 92/255, blue: 246/255, opacity: 0.1)
    
    static var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }
}
