//
//  NowPlayingController.swift
//  NotchNotch
//
//  Backend-agnostic observable wrapper the views bind to.
//

import Combine
import Foundation

@MainActor
final class NowPlayingController: ObservableObject {

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var authorization: NowPlayingAuthorization = .notRequired

    private let source: any NowPlayingSource

    var isAvailable: Bool { source.isAvailable }

    init(source: any NowPlayingSource) {
        self.source = source
    }

    func start() {
        source.onChange = { [weak self] track in
            guard let self else { return }
            self.nowPlaying = track
            // The source re-evaluates permission on every tick, so mirroring it
            // here keeps the UI current without another callback channel.
            self.authorization = self.source.authorization
        }
        source.start()
        authorization = source.authorization
    }

    func stop() {
        source.stop()
        source.onChange = nil
        nowPlaying = nil
    }

    func send(_ command: MediaCommand) {
        source.send(command)
    }

    func requestAuthorization() {
        source.requestAuthorization()
        authorization = source.authorization
    }
}
