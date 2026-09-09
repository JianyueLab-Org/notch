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
            if self.nowPlaying != track {
                self.nowPlaying = track
            }
            let nextAuth = self.source.authorization
            if self.authorization != nextAuth {
                self.authorization = nextAuth
            }
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
