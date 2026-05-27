// FineTune/Shortcuts/MenuBarPopupController.swift
import AppKit
import os

/// Toggles the FineTune menu-bar popup from outside the SwiftUI scene chain
/// (e.g. when a global hotkey fires).
///
/// Uses a direct reference to AppDelegate's togglePopup() method, set during
/// FineTuneApp.init.
@MainActor
protocol MenuBarPopupControlling: AnyObject {
    func toggle()
}

@MainActor
final class MenuBarPopupController: MenuBarPopupControlling {
    private static let logger = Logger(
        subsystem: "com.finetuneapp.FineTune",
        category: "MenuBarPopupController"
    )

    /// Direct reference to the AppDelegate, set by FineTuneApp.init.
    weak var appDelegate: AppDelegate?

    func toggle() {
        guard let appDelegate = appDelegate else {
            Self.logger.debug("toggle: appDelegate not wired yet; ignoring")
            return
        }
        appDelegate.togglePopup()
    }
}
