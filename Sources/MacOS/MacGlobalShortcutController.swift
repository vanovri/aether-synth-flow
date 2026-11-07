// MARK: - FILE: MacGlobalShortcutController.swift

import Foundation
import Observation

#if os(macOS)
import AppKit

// MARK: - Global & Local NSEvent Hotkey Monitor Controller (⌘⇧F / ⌘⇧B / ⌘⇧H / ⌘⇧])

@Observable
@MainActor
public final class MacGlobalShortcutController {
    public enum ShortcutAction: String, Sendable, CaseIterable, Identifiable {
        case toggleFocusSession     // ⌘⇧F — Start/Pause Focus Flow
        case triggerHarmonicBloom   // ⌘⇧B — Trigger Harmonic Bloom
        case toggleFloatingHUD      // ⌘⇧H — Toggle Floating Orbital HUD
        case cycleAcousticPreset    // ⌘⇧] — Cycle Audio Preset

        public var id: String { rawValue }

        public var displayLabel: String {
            switch self {
            case .toggleFocusSession: return "Start / Pause Focus Flow"
            case .triggerHarmonicBloom: return "Trigger Harmonic Bloom"
            case .toggleFloatingHUD: return "Toggle Floating Orbital HUD"
            case .cycleAcousticPreset: return "Cycle Audio Preset"
            }
        }

        public var keyComboBadge: String {
            switch self {
            case .toggleFocusSession: return "⌘⇧F"
            case .triggerHarmonicBloom: return "⌘⇧B"
            case .toggleFloatingHUD: return "⌘⇧H"
            case .cycleAcousticPreset: return "⌘⇧]"
            }
        }
    }

    public var isShortcutsEnabled: Bool = true
    public private(set) var lastTriggeredAction: ShortcutAction?

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var actionHandler: ((ShortcutAction) -> Void)?

    public init() {}

    public func registerShortcuts(onTrigger: @escaping @MainActor (ShortcutAction) -> Void) {
        unregisterShortcuts()
        self.actionHandler = onTrigger

        // 1. Global monitor when AetherSynth is in the background or over fullscreen IDEs
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let action = Self.matchShortcut(from: event) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isShortcutsEnabled else { return }
                self.lastTriggeredAction = action
                self.actionHandler?(action)
            }
        }

        // 2. Local monitor when AetherSynth Studio or Floating HUD has focus
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let action = Self.matchShortcut(from: event) else {
                return event
            }
            guard let self, self.isShortcutsEnabled else {
                return event
            }
            self.lastTriggeredAction = action
            self.actionHandler?(action)
            return nil
        }
    }

    public func unregisterShortcuts() {
        if let global = globalKeyMonitor {
            NSEvent.removeMonitor(global)
            globalKeyMonitor = nil
        }
        if let local = localKeyMonitor {
            NSEvent.removeMonitor(local)
            localKeyMonitor = nil
        }
        actionHandler = nil
    }

    nonisolated public static func matchShortcut(from event: NSEvent) -> ShortcutAction? {
        guard !event.isARepeat else { return nil }

        let relevantModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let requiredFlags: NSEvent.ModifierFlags = [.command, .shift]
        guard relevantModifiers == requiredFlags else {
            return nil
        }

        // ANSI right-bracket keyCode 30 (handles both "]" and shifted "}" across macOS keyboard layouts)
        if event.keyCode == 30 {
            return .cycleAcousticPreset
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }

        switch key {
        case "f":
            return .toggleFocusSession
        case "b":
            return .triggerHarmonicBloom
        case "h":
            return .toggleFloatingHUD
        case "]", "}":
            return .cycleAcousticPreset
        default:
            return nil
        }
    }
}
#endif
