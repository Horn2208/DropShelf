import SwiftUI
import AVKit

/// Eigenständige Trim-Ansicht: AVPlayerView mit eingebauter Trim-Leiste.
/// OK in der Leiste → `onTrim(range)` (Aufrufer ruft `MediaTrim.trim`); Abbrechen → `onCancel`;
/// nicht abspielbar oder nicht kürzbar → `onError(Meldung)`. Nach dem Abbau kommt kein Aufruf mehr.
struct TrimView: NSViewRepresentable {
    let url: URL
    var onTrim: @MainActor @Sendable (CMTimeRange) -> Void
    var onCancel: @MainActor @Sendable () -> Void = {}
    var onError: @MainActor @Sendable (String) -> Void = { _ in }

    final class Coordinator { var task: Task<Void, Never>? }

    /// Nicht gesetzte Trim-Enden sind kCMTimeInvalid: dann Anfang bzw. Ende des Mediums.
    nonisolated static func trimRange(reverseEnd: CMTime, forwardEnd: CMTime, duration: CMTime) -> CMTimeRange {
        CMTimeRange(start: reverseEnd.isNumeric ? reverseEnd : .zero,
                    end: forwardEnd.isNumeric ? forwardEnd : duration)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        let item = AVPlayerItem(url: url)
        view.player = AVPlayer(playerItem: item)
        let (onTrim, onCancel, onError) = (self.onTrim, self.onCancel, self.onError)
        let name = url.lastPathComponent
        context.coordinator.task = Task { @MainActor [weak view] in
            // Trimmen geht erst, wenn das Asset geladen und abspielbar ist.
            let playable = (try? await item.asset.load(.isPlayable)) == true
            guard !Task.isCancelled else { return }  // View ist schon abgebaut: nichts mehr melden
            guard playable else {
                return onError("„\(name)“ kann nicht abgespielt werden. Die Datei ist beschädigt oder das Format wird nicht unterstützt.")
            }
            // canBeginTrimming gilt erst, wenn der Item-Status feststeht und die View im Fenster hängt.
            // Verschwindet die View, bricht `dismantleNSView` den Task ab und das Warten endet.
            while item.status == .unknown || view?.window == nil {
                guard view != nil, (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
            }
            guard let view else { return }
            guard view.canBeginTrimming else { return onError("„\(name)“ lässt sich nicht kürzen.") }
            let answer = await view.beginTrimming()
            guard !Task.isCancelled else { return }
            guard answer == .okButton else { return onCancel() }
            onTrim(Self.trimRange(reverseEnd: item.reversePlaybackEndTime,
                                  forwardEnd: item.forwardPlaybackEndTime, duration: item.duration))
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        nsView.player?.pause()
        nsView.player = nil
    }
}
