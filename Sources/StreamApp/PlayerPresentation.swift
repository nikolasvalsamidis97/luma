import AppKit
import SwiftUI

/// Window-scoped fullscreen state; popovers must never redirect the fullscreen action.
@MainActor final class PlayerPresentation: ObservableObject {
    @Published private(set) var isFullscreen = false
    @Published private(set) var controlsVisible = true
    var isPlaying = false { didSet { revealControls() } }
    var controlsPinned = false { didSet { revealControls() } }
    var pointerOverControls = false { didSet { if pointerOverControls { revealControls() } else { scheduleHide() } } }
    private(set) weak var window: NSWindow?
    private weak var videoView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var hideTask: Task<Void, Never>?
    private var transitioning = false

    func attach(to window: NSWindow?, videoView: NSView) {
        guard let window else {
            if self.videoView === videoView { detach() }
            return
        }
        self.videoView = videoView
        guard self.window !== window else { return }
        detach()
        self.window = window; self.videoView = videoView
        window.acceptsMouseMovedEvents = true
        isFullscreen = window.styleMask.contains(.fullScreen)
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.windowChanged(notification.name) }
            })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
        revealControls()
    }
    func detach() {
        hideTask?.cancel(); hideTask = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
        window = nil; videoView = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }
    func toggleFullscreen() {
        guard let window, !transitioning else { return }
        transitioning = true; revealControls()
        window.toggleFullScreen(nil)
        // AppKit can decline a transition; do not leave the button permanently locked.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.transitioning else { return }
            self.transitioning = false
            self.isFullscreen = self.window?.styleMask.contains(.fullScreen) == true
            self.revealControls()
        }
    }
    private func windowChanged(_ name: Notification.Name) {
        transitioning = name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification
        isFullscreen = window?.styleMask.contains(.fullScreen) == true
        if name == NSWindow.didEnterFullScreenNotification { isFullscreen = true }
        if name == NSWindow.didExitFullScreenNotification { isFullscreen = false }
        pointerOverControls = false
        revealControls()
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        if event.type == .keyDown, event.keyCode == 53, isFullscreen, !controlsPinned {
            toggleFullscreen(); return nil
        }
        if event.type == .leftMouseDown, event.clickCount == 2, !controlsPinned,
           let videoView, videoView.bounds.contains(videoView.convert(event.locationInWindow, from: nil)), !pointerOverControls {
            toggleFullscreen(); return nil
        }
        if event.type == .mouseMoved || event.type == .leftMouseDown || event.type == .keyDown { revealControls() }
        return event
    }
    func revealControls() {
        if !controlsVisible { controlsVisible = true }
        NSCursor.setHiddenUntilMouseMoves(false)
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard isFullscreen, isPlaying, !controlsPinned, !pointerOverControls else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            guard let self, !Task.isCancelled, self.isFullscreen, self.isPlaying, !self.controlsPinned, !self.pointerOverControls else { return }
            self.controlsVisible = false
            if self.window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}
