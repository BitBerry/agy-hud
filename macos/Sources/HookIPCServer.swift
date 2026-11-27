import Foundation

final class HookIPCServer {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.local.agy-hud.ipc", qos: .userInteractive)
    private var serverFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let onMessage: @MainActor (HookIPCMessage) -> Void

    init(socketPath: String = AppPaths.socketURL.path, onMessage: @escaping @MainActor (HookIPCMessage) -> Void) {
        self.socketPath = socketPath
        self.onMessage = onMessage
    }

    func start() {
        AppPaths.ensureDataDir()

        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[AgyHUD] Failed to create Unix domain socket: \(errno)")
            return
        }

        // Prevent SIGPIPE on broken client sockets
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(socketPath.utf8)
        guard utf8.count < maxLen else {
            NSLog("[AgyHUD] Socket path too long: \(socketPath)")
            close(fd)
            return
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { buf in
                memset(buf, 0, maxLen)
                for (i, byte) in utf8.enumerated() {
                    buf[i] = CChar(bitPattern: byte)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }
        guard bindRes == 0 else {
            NSLog("[AgyHUD] Failed to bind socket at \(socketPath): \(errno)")
            close(fd)
            return
        }

        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("[AgyHUD] Failed to listen on socket: \(errno)")
            close(fd)
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        self.serverFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.serverFd >= 0 {
                close(self.serverFd)
                self.serverFd = -1
            }
        }
        self.acceptSource = source
        source.resume()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptSource?.cancel()
            self.acceptSource = nil
            if self.serverFd >= 0 {
                close(self.serverFd)
                self.serverFd = -1
            }
            try? FileManager.default.removeItem(atPath: self.socketPath)
        }
    }

    private func acceptPendingConnections() {
        while serverFd >= 0 {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFd = accept(serverFd, &clientAddr, &clientLen)
            if clientFd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                break
            }
            handleClient(clientFd)
        }
    }

    private func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }

        // An accepted socket inherits O_NONBLOCK from the listener. Left that way, a
        // read that runs before the hook's payload lands returns EAGAIN and the
        // message is dropped, so switch to blocking reads bounded by the timeout below.
        let flags = fcntl(clientFd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(clientFd, F_SETFL, flags & ~O_NONBLOCK)
        }

        var tv = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let maxBytes = 64 * 1024

        while buffer.count < maxBytes {
            let n = read(clientFd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.contains(0x0A) {
                    break
                }
            } else {
                break
            }
        }

        guard !buffer.isEmpty,
              let rawStr = String(data: buffer, encoding: .utf8) else {
            return
        }

        for line in rawStr.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            if let msg = try? JSONDecoder().decode(HookIPCMessage.self, from: lineData) {
                let handler = self.onMessage
                Task { @MainActor in
                    handler(msg)
                }
            }
        }
    }
}
