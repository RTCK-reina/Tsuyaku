import Foundation
import SwiftUI
import Synchronization
// TranslationSession is not annotated for concurrency (non-Sendable with
// @concurrent methods). @preconcurrency treats it as usable across isolation
// boundaries; safety is preserved because each session is confined to one
// worker task that serves requests serially.
@preconcurrency import Translation

/// First-completion-wins flag used to implement deadlines without TaskGroup
/// (a TaskGroup waits for ALL children — a hung child would block forever).
private final class Deadline: Sendable {
    private let won = Mutex(false)
    /// Returns true exactly once, to whichever caller claims it first.
    func claim() -> Bool {
        won.withLock { w in
            if w { return false }
            w = true
            return true
        }
    }
}

/// Owns Apple Translation sessions (one per source language).
///
/// `TranslationSession` is non-`Sendable` and its `translate()` /
/// `prepareTranslation()` methods are `@concurrent`, so a session cannot be
/// stored in actor state. Two acquisition paths are supported, and in both the
/// session stays a *local variable* of the task that uses it:
///
/// - Pair already `.installed` (macOS 26+): a detached worker task creates the
///   session with `init(installedSource:)` and serves requests forever. Works
///   headless (CLI, file analysis) with no SwiftUI in sight.
/// - Pair `.supported` but not installed: a `TranslationSession.Configuration`
///   is published and the invisible `TranslationSessionsHost` view attaches a
///   `.translationTask`, which lets the system present its language-pack
///   download UI. The action closure hands the session to `runHostedWorker`,
///   where it serves the same mailbox.
///
/// Requests reach workers through an `AsyncStream` mailbox and each caller
/// enforces its own deadline, so a missing pack or hung session degrades to
/// "show original text" without ever stalling the pipeline.
@MainActor
final class TranslationBridge: ObservableObject {

    @Published var statusMessage: String?

    /// Configs for pairs that need the view-mediated session (pack download).
    @Published private(set) var configs: [String: TranslationSession.Configuration] = [:]

    /// A single queued translation request.
    private struct Request: Sendable {
        let text: String
        let done: @Sendable (String?) -> Void
    }

    /// Mailbox feeding each per-source worker.
    private var mailboxes: [String: AsyncStream<Request>.Continuation] = [:]
    private var streams: [String: AsyncStream<Request>] = [:]
    private var workers: [String: Task<Void, Never>] = [:]

    /// Target language per source, for workers started via the view path.
    private var targets: [String: String] = [:]

    /// Cached LanguageAvailability results per "src→dst" pair.
    private var pairStatus: [String: LanguageAvailability.Status] = [:]

    /// Recently produced translations, used to de-duplicate retries.
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 200

    /// Caller-side deadline: translation must never stall the live pipeline.
    private let requestTimeout: Duration = .seconds(15)

    /// Whisper/BCP-47 code → Locale.Language
    private static func lang(_ code: String) -> Locale.Language {
        Locale.Language(identifier: code)
    }

    /// Translate `text` from `source` to `target`. Returns nil on failure —
    /// callers should fall back to showing the original text.
    func translate(_ text: String, source: String, target: String) async -> String? {
        let key = "\(source)→\(target)|\(text)"
        if let hit = cache[key] { return hit }

        guard await pairSupported(source: source, target: target),
              let mailbox = mailbox(for: source, target: target)
        else { return nil }

        let deadline = Deadline()
        let result: String? = await withCheckedContinuation { cont in
            let done: @Sendable (String?) -> Void = { value in
                if deadline.claim() { cont.resume(returning: value) }
            }
            mailbox.yield(Request(text: text, done: done))
            Task {
                try? await Task.sleep(for: requestTimeout)
                done(nil)
            }
        }

        guard let result else { return nil }
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return result
    }

    /// Check (and cache) whether this language pair can be translated at all.
    private func pairSupported(source: String, target: String) async -> Bool {
        let pair = "\(source)→\(target)"
        if let cached = pairStatus[pair] { return cached != .unsupported }

        let status = await LanguageAvailability().status(
            from: Self.lang(source), to: Self.lang(target))
        pairStatus[pair] = status
        Self.dlog("availability \(pair): \(status)")

        switch status {
        case .installed:
            return true
        case .supported:
            statusMessage = "言語パック \(pair) を準備中…(初回はダウンロードが必要です)"
            return true
        case .unsupported:
            statusMessage = "未対応の言語ペア: \(pair)"
            return false
        @unknown default:
            return true
        }
    }

    /// Lazily create the mailbox and whichever worker path fits this pair.
    private func mailbox(for source: String, target: String) -> AsyncStream<Request>.Continuation? {
        if let existing = mailboxes[source] { return existing }
        targets[source] = target

        // Bounded buffer: if the pack download stalls, dropped requests just
        // surface as "show original" after their own deadline anyway.
        let (stream, continuation) = AsyncStream<Request>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        mailboxes[source] = continuation
        streams[source] = stream

        let installed = pairStatus["\(source)→\(target)"] == .installed
        if installed, #available(macOS 26.0, *) {
            // Headless-capable path: worker creates and owns its session.
            workers[source] = Task.detached { [weak self] in
                await Self.runOwnedWorker(source: source, target: target,
                                          requests: stream, owner: self)
            }
        } else {
            // View-mediated path: publishes a config; TranslationSessionsHost
            // attaches .translationTask, which can trigger the pack download UI.
            ensureConfig(source: source, target: target)
        }
        return continuation
    }

    private func ensureConfig(source: String, target: String) {
        guard configs[source] == nil else { return }
        configs[source] = .init(source: Self.lang(source), target: Self.lang(target))
    }

    /// Entry point called by `TranslationSessionsHost`'s `.translationTask`
    /// action. The action runs for as long as we keep awaiting, so serving the
    /// mailbox here also pins the session's lifetime to the view-provided one.
    nonisolated func runHostedWorker(session: TranslationSession, source: String) async {
        guard let (stream, target) = await streamAndTarget(for: source) else { return }
        Self.dlog("hosted session attached for \(source)")
        await Self.serve(session: session, source: source, target: target,
                         requests: stream, owner: self)
    }

    private func streamAndTarget(for source: String) -> (AsyncStream<Request>, String)? {
        guard let stream = streams[source] else { return nil }
        return (stream, targets[source] ?? "ja")
    }

    /// Headless path (macOS 26+): create a session locally inside this
    /// detached task and serve requests with it.
    @available(macOS 26.0, *)
    private nonisolated static func runOwnedWorker(
        source: String,
        target: String,
        requests: AsyncStream<Request>,
        owner: TranslationBridge?
    ) async {
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = await TranslationSession(
                installedSource: lang(source), target: lang(target),
                preferredStrategy: .lowLatency)
        } else {
            session = await TranslationSession(installedSource: lang(source), target: lang(target))
        }
        await serve(session: session, source: source, target: target,
                    requests: requests, owner: owner)
    }

    /// Shared worker loop: prepare the pack, then translate requests serially.
    /// `session` is confined to this task — never stored, never shared.
    private nonisolated static func serve(
        session: TranslationSession,
        source: String,
        target: String,
        requests: AsyncStream<Request>,
        owner: TranslationBridge?
    ) async {
        // Prepare the language pack with a watchdog. If the download hangs
        // (e.g. the system prompt can't appear), we stop waiting after 90s and
        // tell the user to install the pack manually — but the prepare task
        // keeps running, so if it finishes later translation starts working
        // automatically (preparedFlag flips mid-stream).
        let preparedFlag = Mutex(false)
        let prepDeadline = Deadline()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task {
                do {
                    try await session.prepareTranslation()
                    preparedFlag.withLock { $0 = true }
                    dlog("session ready for \(source)")
                    await owner?.workerReady(source: source)
                } catch {
                    dlog("prepareTranslation failed \(source): \(error)")
                    await owner?.workerFailed(source: source, target: target)
                }
                if prepDeadline.claim() { cont.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(90))
                if !preparedFlag.withLock({ $0 }) {
                    dlog("prepareTranslation timed out for \(source)")
                    await owner?.workerFailed(source: source, target: target)
                }
                if prepDeadline.claim() { cont.resume() }
            }
        }

        for await request in requests {
            guard preparedFlag.withLock({ $0 }) else {
                request.done(nil)
                continue
            }
            do {
                let response = try await session.translate(request.text)
                request.done(response.targetText)
            } catch {
                dlog("translate error \(source)→\(target): \(error)")
                await owner?.workerTranslateError(source: source, target: target, error: error)
                request.done(nil)
            }
        }
    }

    private func workerReady(source: String) {
        statusMessage = nil
        Self.dlog("worker ready for \(source)")
    }

    private func workerFailed(source: String, target: String) {
        statusMessage = "言語パック \(source)→\(target) を準備できません (システム設定→言語と地域→翻訳言語 で手動インストール)"
    }

    private func workerTranslateError(source: String, target: String, error: Error) {
        statusMessage = "翻訳エラー (\(source)→\(target)): \(error.localizedDescription)"
    }

    func reset() {
        for continuation in mailboxes.values { continuation.finish() }
        for task in workers.values { task.cancel() }
        mailboxes.removeAll()
        streams.removeAll()
        workers.removeAll()
        configs.removeAll()
        targets.removeAll()
        pairStatus.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        statusMessage = nil
    }

    private nonisolated static func dlog(_ msg: String) {
        if ProcessInfo.processInfo.environment["TSUYAKU_TEST_FILE"] != nil {
            FileHandle.standardError.write("[xlate] \(msg)\n".data(using: .utf8)!)
        }
    }
}

/// Invisible view that attaches one `.translationTask` per source language
/// whose pack still needs the system download flow.
struct TranslationSessionsHost: View {
    @ObservedObject var bridge: TranslationBridge

    var body: some View {
        ZStack {
            ForEach(Array(bridge.configs.keys.sorted()), id: \.self) { source in
                Color.clear
                    .frame(width: 0, height: 0)
                    .translationTask(bridge.configs[source]) { session in
                        await bridge.runHostedWorker(session: session, source: source)
                    }
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
