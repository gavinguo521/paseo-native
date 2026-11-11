import Foundation
import Testing
@testable import PaseoKit

@Suite(.timeLimit(.minutes(1))) @MainActor struct HostReconnectTests {
    @Test func retriesForFifteenMinutesThenHalfHourlyForOneDayBeforePausing() async throws {
        let driver = RetryDriver()
        let began = driver.clock.now
        let host = makeHost(driver)
        defer { host.stop() }
        var savedPause = false
        host.onReconnectStateChange = { paused, _ in savedPause = paused }
        host.start()
        while driver.clock.now < began.addingTimeInterval(15 * 60) {
            let delay = try #require(await driver.nextDelay())
            #expect(delay > 0 && delay <= 30)
            await driver.releaseWait()
        }
        #expect(await driver.nextDelay() == 30 * 60)
        let attemptsAtSlowStart = await driver.attempts
        for interval in 0..<48 {
            #expect(host.reconnectProgress?.startedAt == began)
            await driver.releaseWait()
            if interval < 47 { #expect(await driver.nextDelay() == 30 * 60) }
        }
        try await eventually { host.state == .paused }
        #expect(driver.clock.now == began.addingTimeInterval(15 * 60 + 24 * 60 * 60))
        // The cutoff itself is a real attempt; only its failure pauses the host.
        #expect(await driver.attempts == attemptsAtSlowStart + 48)
        #expect(host.automaticConnectionExpired && savedPause)
        host.start()
        host.reconnectNow()
        #expect(host.state == .paused)
        host.setAutomaticConnectionPaused(false)
        #expect(await driver.nextDelay() == 1.5)
        #expect(host.reconnectProgress?.startedAt == driver.clock.now)
        #expect(!host.automaticConnectionExpired && !savedPause)
    }

    @Test func restoringOutagePreservesItsDeadlineAndRemainingWait() async throws {
        let driver = RetryDriver()
        let first = makeHost(driver)
        first.start()
        _ = await driver.nextDelay()
        await driver.releaseWait(advanceBy: 15 * 60)
        #expect(await driver.nextDelay() == 30 * 60)
        let saved = try #require(first.reconnectProgress)
        first.stop()
        driver.clock.advance(10 * 60)

        let restoredDriver = RetryDriver(clock: driver.clock)
        let restored = makeHost(restoredDriver, progress: saved)
        defer { restored.stop() }
        restored.start()
        #expect(await restoredDriver.nextDelay() == 20 * 60)
        #expect(await restoredDriver.attempts == 0)
        await restoredDriver.releaseWait()
        #expect(await restoredDriver.nextDelay() == 30 * 60)
        #expect(restored.reconnectProgress?.startedAt == saved.startedAt)
    }

    @Test func wakeAfterLongSleepTriesBeforePausingAndRestartsTheBudget() async throws {
        let driver = RetryDriver()
        let began = driver.clock.now
        driver.clock.advance(15 * 60 + 24 * 60 * 60 - 10)
        let progress = HostReconnectProgress(startedAt: began, failures: 6,
                                            retryAt: driver.clock.now.addingTimeInterval(30 * 60))
        let host = makeHost(driver, progress: progress)
        defer { host.stop() }
        host.start()
        #expect(await driver.nextDelay() == 10)
        // Asleep for two days: the deadline passed without any attempt, so try first.
        await driver.releaseWait(advanceBy: 2 * 24 * 60 * 60)
        #expect(await driver.nextDelay() == 1.5)
        #expect(await driver.attempts == 1)
        #expect(!host.automaticConnectionPaused)
        #expect(host.reconnectProgress?.failures == 1)

        // Relaunching long after the saved outage also attempts, and an online host connects.
        await driver.setAvailable()
        let relaunched = makeHost(driver, progress: progress)
        defer { relaunched.stop() }
        relaunched.start()
        try await eventually { relaunched.state == .connected }
        #expect(!relaunched.automaticConnectionPaused)
        #expect(relaunched.reconnectProgress == nil)
    }

    @Test func foregroundTriesSlowPhaseHostNowWithoutResettingBudget() async throws {
        let driver = RetryDriver()
        let began = driver.clock.now
        let host = makeHost(driver)
        defer { host.stop() }
        host.start()
        _ = await driver.nextDelay()
        await driver.releaseWait(advanceBy: 15 * 60)
        #expect(await driver.nextDelay() == 30 * 60)
        let attempts = await driver.attempts
        host.setAppVisible(false)
        host.setAppVisible(true)
        #expect(await driver.nextDelay() == 30 * 60)
        #expect(await driver.attempts == attempts + 1)
        #expect(host.reconnectProgress?.startedAt == began)
    }

    @Test func successfulRecoveryResetsTheOutageBudget() async throws {
        let driver = RetryDriver()
        let began = driver.clock.now
        let progress = HostReconnectProgress(startedAt: began, failures: 6, retryAt: began)
        driver.clock.advance(15 * 60 + 23 * 60 * 60)
        await driver.setAvailable()
        let host = makeHost(driver, progress: progress)
        defer { host.stop() }
        host.start()
        try await eventually { host.state == .connected }
        #expect(host.reconnectProgress == nil)
        // An established connection must not expire with its previous outage.
        driver.clock.advance(2 * 60 * 60)
        host.setAppVisible(false)
        host.setAppVisible(true)
        #expect(!host.automaticConnectionPaused)
        let transport = try #require(await driver.transports.last)
        await transport.close(code: 1001, reason: "new outage")
        #expect(await driver.nextDelay() == 1.5)
        #expect(host.reconnectProgress?.startedAt == driver.clock.now)
    }

    @Test func sustainedOutageStaysOfflineAndForegroundPreservesBackoff() async throws {
        let driver = RetryDriver()
        let host = makeHost(driver)
        defer { host.stop() }
        host.start()
        for (index, expected) in [1.5, 3, 6, 12, 24, 30, 30].enumerated() {
            #expect(await driver.nextDelay() == expected)
            if index >= 2 {
                guard case .offline = host.state else { Issue.record("Long outage must stay offline"); return }
                let before = host.state
                host.setAppVisible(false)
                host.setAppVisible(true)
                host.start()
                #expect(host.state == before)
                #expect(await driver.attempts == index + 1)
            }
            if index < 6 { await driver.releaseWait() }
        }
        let observed = await driver.states
        #expect(observed.count == 7)
        #expect(observed.dropFirst(3).allSatisfy { if case .offline = $0 { true } else { false } })
    }

    @Test func backgroundProbeRecoversAndRebuildsSubscriptions() async throws {
        let driver = RetryDriver()
        let host = makeHost(driver)
        defer { host.stop() }
        host.start()
        for _ in 0..<2 { _ = await driver.nextDelay(); await driver.releaseWait() }
        #expect(await driver.nextDelay() == 6)
        await driver.setAvailable()
        await driver.releaseWait()
        try await eventually { host.state == .connected }
        let transport = try #require(await driver.transports.last)
        #expect(await transport.requests.contains("session.events.set_subscription.request"))
        #expect(await transport.requests.contains("fetch_workspaces_request"))
        #expect(await transport.requests.contains("fetch_agents_request"))
        await transport.close(code: 1001, reason: "network lost again")
        #expect(await driver.nextDelay() == 1.5)
    }

    @Test func manualRetryRestartsImmediatelyButPauseCannotBeBypassed() async throws {
        let driver = RetryDriver()
        let host = makeHost(driver)
        defer { host.stop() }
        host.start()
        for _ in 0..<2 { _ = await driver.nextDelay(); await driver.releaseWait() }
        #expect(await driver.nextDelay() == 6)
        let oldStart = host.reconnectProgress?.startedAt
        host.reconnectNow()
        #expect(await driver.nextDelay() == 1.5)
        #expect(host.reconnectProgress?.startedAt != oldStart)
        host.setAutomaticConnectionPaused(true)
        #expect(host.state == .paused)
        host.start()
        host.reconnectNow()
        host.setAppVisible(false)
        host.setAppVisible(true)
        await #expect(throws: HostStore.ActionError.self) { try await host.prepareForCompanionRequest() }
        #expect(host.state == .paused)
        #expect(await driver.attempts == 4)
        host.setAutomaticConnectionPaused(false)
        #expect(await driver.nextDelay() == 1.5)
        #expect(await driver.attempts == 5)
    }

    @Test func restoredPausePreventsInitialConnection() async throws {
        let driver = RetryDriver()
        let host = makeHost(driver, paused: true)
        defer { host.stop() }
        host.start()
        host.updatePassword("new-test-password")
        #expect(host.state == .paused)
        #expect(await driver.attempts == 0)
        host.setAutomaticConnectionPaused(false)
        #expect(await driver.nextDelay() == 1.5)
        #expect(await driver.attempts == 1)
    }

    @Test func cancelledOldHandshakeCannotOverrideReplacementConnection() async throws {
        let driver = RetryDriver()
        let host = makeHost(driver)
        let gate = LateHandshake()
        host.openConnection = { _, _ in try await gate.wait() }
        defer { host.stop() }
        host.start()
        await gate.started()
        host.setAutomaticConnectionPaused(true)
        host.openConnection = { _, _ in try await driver.open() }
        await driver.setAvailable()
        host.setAutomaticConnectionPaused(false)
        try await eventually { host.state == .connected }
        await gate.reject()
        // Wait for the obsolete run to finish handling its authentication error.
        for _ in 0..<20 { await Task.yield() }
        #expect(host.state == .connected)
        #expect(await host.connection?.isClosed == false)
    }

    @Test func bootstrapFailureClosesEachSocketAndKeepsFailureCount() async throws {
        let driver = RetryDriver()
        await driver.setAvailable(rejectBootstrap: true)
        let host = makeHost(driver)
        defer { host.stop() }
        host.start()
        for delay in [1.5, 3, 6] {
            #expect(await driver.nextDelay() == delay)
            let transport = try #require(await driver.transports.last)
            #expect(await transport.closed)
            #expect(host.connection == nil)
            if delay != 6 { await driver.releaseWait() }
        }
        guard case .offline = host.state else { Issue.record("Bootstrap failures must also back off"); return }
    }

    @Test func authenticationFailureDoesNotRetryOnForeground() async throws {
        let driver = RetryDriver()
        let host = makeHost(driver)
        host.openConnection = { _, _ in throw DaemonConnectionError.rejected(reason: "incorrect_password") }
        defer { host.stop() }
        host.start()
        try await eventually { if case .failed(_, true) = host.state { true } else { false } }
        let before = host.state
        host.start()
        host.setAppVisible(false)
        host.setAppVisible(true)
        #expect(host.state == before)
    }

    @Test func cancellingHandshakeClosesBlockedTransportPromptly() async throws {
        let transport = RetryTransport()
        let task = Task {
            try await withTimeout(.seconds(60), "test handshake") {
                try await transport.receive()
            } onTimeout: {
                await transport.close(code: 1001, reason: "attempt ended")
            }
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await transport.close(code: 1001, reason: "watchdog") }
        }
        defer { watchdog.cancel() }
        await transport.waitForReceive()
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled handshake must fail") } catch { }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await transport.closed)
    }

    private func makeHost(_ driver: RetryDriver, paused: Bool = false, progress: HostReconnectProgress? = nil) -> HostStore {
        let host = HostStore(offer: .direct(serverId: "test", endpoint: "localhost:1", useTls: false, password: nil),
                             label: "Offline test", clientId: "test", appVersion: "test", automaticConnectionPaused: paused, reconnectProgress: progress)
        host.reconnectDate = { driver.clock.now }
        host.openConnection = { [weak host] _, _ in
            if let state = await host?.state { await driver.record(state) }
            return try await driver.open()
        }
        host.waitToReconnect = { try await driver.wait($0) }
        return host
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

private final class RetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

private actor RetryDriver {
    nonisolated let clock: RetryClock

    private(set) var attempts = 0
    private(set) var states: [ConnectionState] = []
    private(set) var transports: [RetryTransport] = []
    private var available = false
    private var rejectBootstrap = false
    private var waiters: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    private let delays: AsyncStream<TimeInterval>
    private let sink: AsyncStream<TimeInterval>.Continuation

    init(clock: RetryClock = RetryClock()) {
        self.clock = clock
        (delays, sink) = AsyncStream.makeStream(of: TimeInterval.self)
    }
    func record(_ state: ConnectionState) { states.append(state) }
    func setAvailable(rejectBootstrap: Bool = false) { available = true; self.rejectBootstrap = rejectBootstrap }
    func open() async throws -> DaemonConnection {
        attempts += 1
        guard available else { throw URLError(.cannotConnectToHost) }
        let transport = RetryTransport(rejectBootstrap: rejectBootstrap)
        transports.append(transport)
        let connection = DaemonConnection(channel: transport)
        try await connection.handshake(hello: .init(clientId: "test"), expectedServerId: "test")
        return connection
    }
    func wait(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = (seconds, continuation); sink.yield(seconds) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    func releaseWait(advanceBy seconds: TimeInterval? = nil) {
        let pending = waiters; waiters.removeAll()
        clock.advance(seconds ?? pending.values.map { $0.0 }.max() ?? 0)
        for (_, waiter) in pending.values { waiter.resume() }
    }
    func nextDelay() async -> TimeInterval? {
        var iterator = delays.makeAsyncIterator()
        return await iterator.next()
    }
}

private actor LateHandshake {
    private var continuation: CheckedContinuation<DaemonConnection, Error>?
    private let events: AsyncStream<Void>
    private let sink: AsyncStream<Void>.Continuation
    init() { (events, sink) = AsyncStream.makeStream(of: Void.self) }
    func wait() async throws -> DaemonConnection {
        try await withCheckedThrowingContinuation { continuation = $0; sink.yield(()) }
    }
    func started() async { var iterator = events.makeAsyncIterator(); _ = await iterator.next() }
    func reject() { continuation?.resume(throwing: DaemonConnectionError.rejected(reason: "incorrect_password")); continuation = nil }
}

private actor RetryTransport: FrameTransport {
    private var incoming: [WireFrame] = []
    private var receiver: CheckedContinuation<WireFrame, Error>?
    private(set) var closed = false
    private(set) var requests: [String] = []
    private let rejectBootstrap: Bool
    private let receives: AsyncStream<Void>
    private let received: AsyncStream<Void>.Continuation
    init(rejectBootstrap: Bool = false) {
        self.rejectBootstrap = rejectBootstrap
        (receives, received) = AsyncStream.makeStream(of: Void.self)
    }
    func send(_ frame: WireFrame) async throws {
        guard !closed else { throw TransportClosed(code: 1001, reason: "test closed") }
        guard case .text(let text) = frame else { return }
        let value = try JSONValue.parse(text)
        if value["type"]?.stringValue == "hello" {
            deliver(["type": "session", "message": ["type": "status", "payload": ["status": "server_info", "serverId": "test"]]])
        } else if let request = value["message"], let type = request["type"]?.stringValue, let id = request["requestId"] {
            requests.append(type)
            let reject = rejectBootstrap && type == "session.events.set_subscription.request"
            deliver(["type": "session", "message": ["type": .string(reject ? "rpc_error" : type + ".response"),
                "payload": ["requestId": id, "entries": [], "projects": [], "error": reject ? "test bootstrap failure" : .null]]])
        }
    }
    func receive() async throws -> WireFrame {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw TransportClosed(code: 1001, reason: "test closed") }
        return try await withCheckedThrowingContinuation { receiver = $0; received.yield(()) }
    }
    func waitForReceive() async { var iterator = receives.makeAsyncIterator(); _ = await iterator.next() }
    func close(code: Int, reason: String) async {
        closed = true
        receiver?.resume(throwing: TransportClosed(code: code, reason: reason)); receiver = nil
    }
    private func deliver(_ value: JSONValue) {
        let frame = WireFrame.text(try! value.serialized())
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { incoming.append(frame) }
    }
}
