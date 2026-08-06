import Darwin

/// Counts currently open descriptors without opening any new descriptors.
enum FileDescriptorCensus {
    static func count() -> Int {
        let maximum = getdtablesize()
        return (0..<maximum).reduce(into: 0) { count, descriptor in
            errno = 0
            if fcntl(Int32(descriptor), F_GETFD) >= 0 {
                count += 1
            } else {
                precondition(errno == EBADF, "unexpected fcntl error for descriptor \(descriptor)")
            }
        }
    }
}
