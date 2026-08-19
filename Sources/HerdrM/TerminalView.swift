import AppKit
import HerdrKit
import SwiftTerm
import SwiftUI

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let defaultFontSize: Double = 12.5

    static func font(name: String, size: Double) -> NSFont {
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Fixed-pitch font families available on this Mac, for the settings picker.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
}

/// Hosts whichever kept-alive terminal belongs to the current selection.
///
/// The terminal itself lives in `TerminalSessionStore`, so switching agents moves an
/// already-attached view into this container instead of spawning a new `herdr agent
/// attach` (and, on a remote device, a new SSH session) every time.
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let ref: PaneRef
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    /// From SwiftUI's environment so theme switches re-render immediately.
    var dark: Bool = false
    /// When false, mouse drags always select text locally even if the TUI
    /// requested mouse reporting (Shift+drag bypasses it either way).
    var mouseReporting: Bool = true

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        let session = TerminalSessionStore.shared.session(for: ref, device: device)
        session.apply(
            fontName: fontName,
            fontSize: fontSize,
            dark: dark,
            mouseReporting: mouseReporting
        )
        container.install(session.view)
    }
}

/// Plain container whose only job is to hold one terminal view at a time.
final class TerminalContainerView: NSView {
    func install(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        for existing in subviews { existing.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        // Typing should land in the terminal straight after a switch. The sheets and the
        // ⌘K palette run in their own window, so this cannot steal their focus.
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let terminal, terminal.superview === self else { return }
            self?.window?.makeFirstResponder(terminal)
        }
    }
}
