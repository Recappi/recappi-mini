import Foundation

/// Phase 2 — explicit lifecycle for the live-caption transcriber
/// owned by `AudioRecorder`. Lifted out of a plain optional field so
/// `stopRecording` can pattern-match on a `.transitioning` case and
/// drain captions from BOTH the outgoing and incoming transcribers
/// instead of losing the outgoing one to the restart's stop-await.
///
/// The cases mirror the architecture-analysis design:
/// - `.none` — no transcriber is active. Initial state, and the state
///   `reset()` returns to.
/// - `.running(transcriber, locale, generation)` — a single
///   transcriber is the active provider. Used by the receive loop and
///   by `reconnectLiveCaptionsNow`.
/// - `.transitioning(from, to, transitionTask, generation)` — a
///   `restartLiveCaptions(...)` is in flight. `from` is the previous
///   transcriber whose entries have already been snapshotted into
///   `RecordingCaptionStore` (its `transitionTask` is doing the
///   bounded WebSocket close handshake). `to` is `nil` until
///   `startLiveCaptionProvider` has returned with the new transcriber;
///   stop-then-start order is preserved so two near-simultaneous
///   `/sessions` claim POSTs never hit the backend (see the existing
///   restart-chain comment in `AudioRecorder.restartLiveCaptions`).
/// - `.stopping(transcriber)` — a `stopRecording` is in flight; the
///   transcriber's close handshake hasn't returned yet. After it
///   returns the state transitions to `.none`.
///
/// The associated payload is a `LiveCaptionProvider` sum type that concretely
/// identifies the active backend provider. Phase 3d removed the previous `Any?`
/// boxing after deleting the legacy `BackendRealtimeLiveCaptionTranscriber`;
/// task #186 later made backend Realtime the only production provider.
///
/// `@MainActor` because every read/write is from `AudioRecorder`,
/// which is itself `@MainActor`.

/// Concrete provider identity for the live-caption pipeline. A `.testSentinel`
/// case keeps the DEBUG hooks driving the AudioRecorder restart state machine
/// usable without standing up real I/O.
@MainActor
enum LiveCaptionProvider {
    case backend(RealtimeLiveCaptionActor)
#if DEBUG
    case testSentinel(AnyObject)
#endif

#if DEBUG
    /// Underlying identity (the actor / transcriber / sentinel) hashed
    /// by `ObjectIdentifier`. Used by stub hooks in tests to map a
    /// captured provider back to a scripted set of entries.
    var debugIdentity: ObjectIdentifier {
        switch self {
        case .backend(let actor):
            return ObjectIdentifier(actor)
        case .testSentinel(let object):
            return ObjectIdentifier(object)
        }
    }

    /// Convenience: returns the underlying instance as `AnyObject` so
    /// the DEBUG hooks installed by tests can compare identities or
    /// type-cast back to a sentinel they injected.
    var debugAnyObject: AnyObject {
        switch self {
        case .backend(let actor):
            return actor
        case .testSentinel(let object):
            return object
        }
    }
#endif
}

#if DEBUG
/// Phase 2 — wide-shape test fixture for the live-caption lifecycle
/// hooks. Tests construct one of these, fill in the three closures,
/// and hand it to `AudioRecorder.installPhase2LiveCaptionHooksFor-
/// Testing(_:)`. Closure signatures intentionally mirror the
/// production helpers (`drainEntriesForTransition`, `stop(saveTo:)`,
/// `startLiveCaptionProvider`) so a test can drive the same control
/// flow without standing up real network I/O.
@MainActor
final class StubLiveCaptionLifecycleHooks {
    var drainEntries: (@MainActor (LiveCaptionProvider?) -> [LiveCaptionEntry]) = { _ in [] }
    var stop: (@MainActor (LiveCaptionProvider?) async -> Void) = { _ in }
    var start: (@MainActor (String) -> Void) = { _ in }
}
#endif

@MainActor
enum LiveCaptionState {
    case none
    case running(provider: LiveCaptionProvider, locale: String, generation: UInt64)
    case transitioning(
        from: LiveCaptionProvider?,
        to: LiveCaptionProvider?,
        transitionTask: Task<Void, Never>,
        generation: UInt64
    )
    case stopping(provider: LiveCaptionProvider?)

    /// Convenience accessor used by legacy readers
    /// (`canReconnectLiveCaptions`, `reconnectLiveCaptionsNow`, the
    /// UI test path) that still need the active provider as an
    /// optional. Production now carries only the backend actor here.
    var activeProvider: LiveCaptionProvider? {
        switch self {
        case .none:
            return nil
        case .running(let provider, _, _):
            return provider
        case .transitioning(_, let to, _, _):
            // `to` is `nil` while the old provider's close handshake
            // is in flight (stop-then-start ordering).
            return to
        case .stopping(let provider):
            return provider
        }
    }
}
