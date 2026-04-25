import Foundation
import os.log

// Unix domain socket server for real-time hook events.
// Supports request/response for permission decisions.

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.cli-buddy", category: "Hooks")

/// Event received from Claude Code or Codex hooks
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?
    /// "codex" for Codex hook events; nil for Claude Code hook events
    let source: String?
    /// Rollout file path for Codex sessions (passed via transcript_path)
    let transcriptPath: String?
    /// Env-detected terminal app hint from hook script (fallback when process tree fails)
    let terminalApp: String?
    /// cmux workspace/surface IDs captured by the hook script from `os.environ`.
    /// The only reliable way to read these — macOS hides hardened-runtime env
    /// vars from `ps -E`.
    let cmuxWorkspaceId: String?
    let cmuxSurfaceId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message, source
        case transcriptPath = "transcript_path"
        case terminalApp = "terminal_app"
        case cmuxWorkspaceId = "cmux_workspace_id"
        case cmuxSurfaceId = "cmux_surface_id"
    }

    /// Create a copy with updated toolUseId
    init(sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?, source: String? = nil, transcriptPath: String? = nil, terminalApp: String? = nil, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.source = source
        self.transcriptPath = transcriptPath
        self.terminalApp = terminalApp
        self.cmuxWorkspaceId = cmuxWorkspaceId
        self.cmuxSurfaceId = cmuxSurfaceId
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
final class HookSocketServer: @unchecked Sendable {
    let socketPath: String

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.cli-buddy.socket", qos: .userInitiated)

    private let registry = PermissionRegistry()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    /// Per-client read state, keyed by fd. Allocated on accept, released
    /// when the client closes or the read source is cancelled.
    private var clientReaders: [Int32: ClientReader] = [:]

    private final class ClientReader {
        var buffer = Data()
        var source: DispatchSourceRead?
    }

    init(socketPath: String = "/tmp/cli-buddy.sock") {
        self.socketPath = socketPath
    }

    /// Called when the server fails to bind or listen. Fires on the
    /// server's own dispatch queue; AppDelegate should hop to MainActor
    /// before touching UI.
    typealias BindFailureHandler = @Sendable (_ reason: String) -> Void

    /// Start the socket server
    func start(
        onEvent: @escaping HookEventHandler,
        onPermissionFailure: PermissionFailureHandler? = nil,
        onBindFailure: BindFailureHandler? = nil
    ) {
        queue.async { [weak self] in
            self?.startServer(
                onEvent: onEvent,
                onPermissionFailure: onPermissionFailure,
                onBindFailure: onBindFailure
            )
        }
    }

    private func startServer(
        onEvent: @escaping HookEventHandler,
        onPermissionFailure: PermissionFailureHandler?,
        onBindFailure: BindFailureHandler?
    ) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            onBindFailure?("Failed to create socket (errno \(errno))")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            let saved = errno
            close(serverSocket)
            serverSocket = -1
            onBindFailure?("bind(\(self.socketPath)) failed with errno \(saved)")
            return
        }

        chmod(self.socketPath, 0o700)

        guard listen(serverSocket, 128) == 0 else {
            logger.error("Failed to listen: \(errno)")
            let saved = errno
            close(serverSocket)
            serverSocket = -1
            onBindFailure?("listen() failed with errno \(saved)")
            return
        }

        logger.info("Listening on \(self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(self.socketPath)

        for (fd, reader) in clientReaders {
            reader.source?.setCancelHandler {}
            reader.source?.cancel()
            close(fd)
        }
        clientReaders.removeAll()

        Task { [registry, queue] in
            let drained = await registry.drain()
            queue.async {
                for p in drained { close(p.clientSocket) }
            }
        }
    }

    /// Respond to a pending permission request by toolUseId
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        Task { [registry, queue] in
            guard let pending = await registry.remove(toolUseId: toolUseId) else {
                logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
                return
            }
            queue.async { [weak self] in
                self?.writeResponse(to: pending, decision: decision, reason: reason, sessionForFailure: pending.sessionId)
            }
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        Task { [registry, queue] in
            guard let pending = await registry.popMostRecent(sessionId: sessionId) else {
                logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
                return
            }
            queue.async { [weak self] in
                self?.writeResponse(to: pending, decision: decision, reason: reason, sessionForFailure: sessionId)
            }
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        Task { [registry, queue] in
            let removed = await registry.removeAll(sessionId: sessionId)
            queue.async {
                for pending in removed {
                    logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public)")
                    close(pending.clientSocket)
                }
            }
        }
    }

    /// Check if there's a pending permission request for a session (sync shim for AppDelegate callers)
    func hasPendingPermission(sessionId: String) -> Bool {
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { [registry] in
            box.value = await registry.hasPending(sessionId: sessionId)
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    /// Async version for test and Swift concurrency callers
    func hasPendingPermissionAsync(sessionId: String) async -> Bool {
        await registry.hasPending(sessionId: sessionId)
    }

    /// Get the pending permission details for a session (if any) — sync shim for AppDelegate callers
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        final class Box: @unchecked Sendable { var value: (String?, String?, [String: AnyCodable]?)? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { [registry] in
            if let p = await registry.peekPending(sessionId: sessionId) {
                box.value = (p.event.tool, p.toolUseId, p.event.toolInput)
            }
            sem.signal()
        }
        sem.wait()
        return box.value.map { ($0.0, $0.1, $0.2) }
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        Task { [registry, queue] in
            guard let pending = await registry.remove(toolUseId: toolUseId) else { return }
            queue.async {
                logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
                close(pending.clientSocket)
            }
        }
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        let reader = ClientReader()
        clientReaders[clientSocket] = reader

        let src = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: queue)
        src.setEventHandler { [weak self] in
            self?.drainReader(fd: clientSocket)
        }
        src.setCancelHandler { [weak self] in
            self?.cleanupReader(fd: clientSocket, close: true)
        }
        reader.source = src
        src.resume()
    }

    /// Read everything currently available on the FD into the reader's
    /// buffer, then attempt to decode. The hook script sends one complete
    /// JSON document then shuts down the write half, so EOF (bytesRead ==
    /// 0) is the "done" signal for non-permission events. For permission
    /// events we decode eagerly — the hook keeps the FD open waiting for
    /// our response.
    private func drainReader(fd: Int32) {
        guard let reader = clientReaders[fd] else { return }

        var buffer = [UInt8](repeating: 0, count: 131072)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                reader.buffer.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                dispatchEvent(fd: fd, data: reader.buffer, clientClosedWriteHalf: true)
                reader.source?.cancel()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                reader.source?.cancel()
                return
            }
        }

        if !reader.buffer.isEmpty {
            dispatchEvent(fd: fd, data: reader.buffer, clientClosedWriteHalf: false)
        }
    }

    /// Attempt to parse a full `HookEvent` from the buffer. On success,
    /// routes it and — for permission events — hands the FD off to the
    /// pending-permissions map instead of closing it.
    private func dispatchEvent(fd: Int32, data: Data, clientClosedWriteHalf: Bool) {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            if clientClosedWriteHalf {
                logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
                cleanupReader(fd: fd, close: true)
            }
            return
        }

        guard let reader = clientReaders[fd] else { return }
        reader.buffer.removeAll(keepingCapacity: false)

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" { cacheToolUseId(event: event) }
        if event.event == "SessionEnd" { cleanupCache(sessionId: event.sessionId) }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cached = popCachedToolUseId(event: event) {
                toolUseId = cached
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                cleanupReader(fd: fd, close: true)
                eventHandler?(event)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                sessionId: event.sessionId, cwd: event.cwd, event: event.event,
                status: event.status, pid: event.pid, tty: event.tty, tool: event.tool,
                toolInput: event.toolInput, toolUseId: toolUseId,
                notificationType: event.notificationType, message: event.message,
                source: event.source, transcriptPath: event.transcriptPath,
                terminalApp: event.terminalApp, cmuxWorkspaceId: event.cmuxWorkspaceId,
                cmuxSurfaceId: event.cmuxSurfaceId
            )

            let pending = PendingPermission(
                sessionId: event.sessionId, toolUseId: toolUseId,
                clientSocket: fd, event: updatedEvent, receivedAt: Date()
            )
            // Detach from clientReaders — pending permission owns the fd now.
            reader.source?.setCancelHandler {}
            reader.source?.cancel()
            clientReaders.removeValue(forKey: fd)

            let handler = eventHandler
            Task { [registry] in
                await registry.register(pending)
                handler?(updatedEvent)
            }
            return
        }

        eventHandler?(event)
        if clientClosedWriteHalf {
            cleanupReader(fd: fd, close: true)
        } else {
            reader.source?.cancel()
        }
    }

    private func cleanupReader(fd: Int32, close closeFD: Bool) {
        if clientReaders.removeValue(forKey: fd) != nil, closeFD {
            close(fd)
        }
    }

    private func writeResponse(to pending: PendingPermission, decision: String, reason: String?, sessionForFailure: String) {
        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionForFailure, pending.toolUseId)
            return
        }
        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeOK = false
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let n = write(pending.clientSocket, base, data.count)
            writeOK = n > 0
            if n < 0 {
                logger.error("Write failed with errno: \(errno)")
            }
        }
        close(pending.clientSocket)
        if !writeOK {
            permissionFailureHandler?(sessionForFailure, pending.toolUseId)
        }
    }
}

// AnyCodable lives in Models/AnyCodable.swift — removed inline copy to avoid duplication.
