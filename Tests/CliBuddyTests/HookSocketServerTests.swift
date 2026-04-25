import Testing
import Foundation
@testable import CliBuddy

@Suite struct HookSocketServerTests {
    @Test func serverAcceptsConcurrentClients() async throws {
        let tmpPath = "/tmp/cli-buddy-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: tmpPath)
        defer { server.stop() }

        actor Counter {
            private(set) var count = 0
            func inc() { count += 1 }
        }
        let counter = Counter()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            server.start(onEvent: { _ in
                Task { await counter.inc() }
            })
            Thread.sleep(forTimeInterval: 0.1)

            let group = DispatchGroup()
            for i in 0..<20 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    _ = tmpPath.withCString { cstr in
                        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                            let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                            strcpy(buf, cstr)
                        }
                    }
                    _ = withUnsafePointer(to: &addr) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            connect(sock, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    let payload = "{\"session_id\":\"s-\(i)\",\"cwd\":\"/tmp\",\"event\":\"SessionStart\",\"status\":\"processing\"}\n"
                    _ = payload.withCString { send(sock, $0, strlen($0), 0) }
                    close(sock)
                }
            }
            _ = group.wait(timeout: .now() + 2)
            cont.resume()
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        let n = await counter.count
        #expect(n >= 15, "At least 15/20 events should have been delivered; got \(n)")
    }

    @Test func permissionRoundTripReceivesDecisionOnSameSocket() async throws {
        let tmpPath = "/tmp/cli-buddy-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: tmpPath)
        defer { server.stop() }

        let captured: HookEvent = try await withCheckedThrowingContinuation { cont in
            final class Once: @unchecked Sendable {
                private let lock = NSLock(); private var done = false
                func tryFire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
            }
            let fired = Once()
            server.start(onEvent: { evt in
                if evt.expectsResponse, fired.tryFire() {
                    cont.resume(returning: evt)
                }
            })
            Thread.sleep(forTimeInterval: 0.1)

            let payload = """
            {"session_id":"sx","cwd":"/tmp","event":"PermissionRequest","status":"waiting_for_approval","tool":"Bash","tool_use_id":"tu-1","tool_input":{"cmd":"ls"}}
            """
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            _ = tmpPath.withCString { cstr in
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                    strcpy(buf, cstr)
                }
            }
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    connect(sock, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            _ = payload.withCString { send(sock, $0, strlen($0), 0) }

            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 1024)
                let n = read(sock, &buf, buf.count)
                if n <= 0 {
                    Issue.record("server did not write decision")
                    close(sock)
                    return
                }
                let str = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                if !str.contains("\"decision\":\"allow\"") {
                    Issue.record("unexpected response: \(str)")
                }
                close(sock)
            }
        }

        server.respondToPermission(toolUseId: "tu-1", decision: "allow")
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(captured.toolUseId == "tu-1")
        let still = await server.hasPendingPermissionAsync(sessionId: "sx")
        #expect(still == false)
    }

    @Test func serverReceivesEventAndParses() async throws {
        let tmpPath = "/tmp/cli-buddy-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: tmpPath)
        defer { server.stop() }

        final class FireOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func tryFire() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let guardFlag = FireOnce()

        // Capture event via continuation
        let evt: HookEvent = try await withCheckedThrowingContinuation { cont in
            server.start(onEvent: { e in
                if guardFlag.tryFire() {
                    cont.resume(returning: e)
                }
            })

            // Give the server a beat to bind + listen
            Thread.sleep(forTimeInterval: 0.1)

            let payload = """
            {"session_id":"s-1","cwd":"/tmp","event":"SessionStart","status":"processing"}
            """

            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(sock >= 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = tmpPath.withCString { cstr in
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                    strcpy(buf, cstr)
                }
            }
            let rc = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    connect(sock, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(rc == 0)
            _ = payload.withCString { send(sock, $0, strlen($0), 0) }
            close(sock)
        }

        #expect(evt.sessionId == "s-1")
        #expect(evt.status == "processing")
        #expect(evt.event == "SessionStart")
    }
}
