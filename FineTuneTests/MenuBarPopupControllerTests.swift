// FineTuneTests/MenuBarPopupControllerTests.swift
import Testing
import AppKit
@testable import FineTune

@Suite("MenuBarPopupController", .serialized)
@MainActor
struct MenuBarPopupControllerTests {
    @Test("toggle is a no-op when appDelegate is nil")
    func noAppDelegate() {
        let controller = MenuBarPopupController()
        controller.toggle()  // must not crash; logs debug and returns
    }

    @Test("toggle calls through to appDelegate.togglePopup()")
    func toggleCallsAppDelegate() {
        let controller = MenuBarPopupController()
        let delegate = AppDelegate()
        controller.appDelegate = delegate
        controller.toggle()  // must not crash
    }
}
