import Darwin
import Foundation

@main
struct ParakeetStoreLockProbe {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            let root = try argument("--root", from: arguments)
            let modeName = try argument("--mode", from: arguments)
            let mode: ParakeetStoreFileLock.Mode
            switch modeName {
            case "shared": mode = .shared
            case "exclusive": mode = .exclusive
            default: throw ProbeError.invalidMode
            }
            let abrupt = arguments.contains("--abrupt")
            let lock = ParakeetStoreFileLock(storeParent: URL(fileURLWithPath: root, isDirectory: true))
            emit("READY")
            guard readLine() == "GO" else { throw ProbeError.missingGo }
            emit("WAITING")
            let lease: ParakeetStoreFileLock.Lease
            if let immediateLease = try lock.tryAcquire(mode) {
                lease = immediateLease
            } else {
                emit("BLOCKED")
                lease = try await lock.acquire(mode)
            }
            emit("ACQUIRED")
            if abrupt { _exit(0) }
            guard readLine() == "RELEASE" else { throw ProbeError.missingRelease }
            lease.release()
            emit("RELEASED")
        } catch {
            emit("ERROR \(error)")
            exit(1)
        }
    }

    private static func emit(_ value: String) {
        print(value)
        fflush(stdout)
    }

    private static func argument(_ name: String, from arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            throw ProbeError.missingArgument(name)
        }
        return arguments[index + 1]
    }

    private enum ProbeError: Error {
        case invalidMode
        case missingGo
        case missingRelease
        case missingArgument(String)
    }
}
