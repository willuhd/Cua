//
//  Clipboard.swift
//  dz
//
//  Clipboard sync between the two ends.
//
//  macOS has no change notification for the pasteboard, so this polls the
//  change counter. That is the only mechanism that exists; the interval is a
//  quarter second and the cost is an integer read, so it is not a busy loop in
//  any meaningful sense. It also only runs while a session is live.
//
//  Echo suppression is by change count rather than by content: writing what we
//  just received bumps the counter, and we remember that count so the next poll
//  does not send it straight back.
//

import Cocoa

/// What travels: one pasteboard, at most one flavour at a time.
struct ClipboardPayload: Codable, Equatable {
    var text: String?
    var imagePNG: Data?
    var stamp: UInt64

    var isEmpty: Bool { (text?.isEmpty ?? true) && (imagePNG?.isEmpty ?? true) }
}

final class ClipboardSync {
    /// Called when the local pasteboard changed for a reason we did not cause.
    var onCopy: ((ClipboardPayload) -> Void)?

    private let pasteboard = NSPasteboard.general
    private var timer: DispatchSourceTimer?
    private var lastSeenChange = -1
    private var ignoreChange = -1
    private let queue = DispatchQueue(label: "dz.clipboard")

    func start(interval: TimeInterval = 0.25) {
        guard timer == nil else { return }
        lastSeenChange = pasteboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let change = pasteboard.changeCount
        guard change != lastSeenChange else { return }
        lastSeenChange = change
        if change == ignoreChange { return }
        guard let payload = read() else { return }
        onCopy?(payload)
    }

    private func read() -> ClipboardPayload? {
        var payload = ClipboardPayload(stamp: DispatchTime.now().uptimeNanoseconds / 1000)
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            payload.text = text
        } else if let png = pasteboard.data(forType: .png), !png.isEmpty {
            payload.imagePNG = png
        }
        return payload.isEmpty ? nil : payload
    }

    /// Writes a remote change without sending it back out again.
    func apply(_ payload: ClipboardPayload) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pasteboard.clearContents()
            if let text = payload.text {
                self.pasteboard.setString(text, forType: .string)
            } else if let png = payload.imagePNG {
                self.pasteboard.setData(png, forType: .png)
            }
            self.ignoreChange = self.pasteboard.changeCount
            self.lastSeenChange = self.pasteboard.changeCount
        }
    }
}
