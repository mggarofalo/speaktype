import Foundation
import Darwin

/// Owns the recovery file so JSON coding and filesystem access never run on the
/// main actor. Once an existing journal cannot be read, writes stay locked until
/// an explicit reload succeeds; this prevents new work from replacing the only
/// recovery copy of older work.
actor HistoryRecoveryJournal {
    private struct Envelope: Codable {
        let version: Int
        let mutations: [HistoryMutation]
    }

    private enum AccessState {
        case unchecked
        case ready
        case blocked(String)
    }

    private let fileURL: URL
    private var accessState = AccessState.unchecked
    private var leaseDescriptor: Int32?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    deinit {
        if let leaseDescriptor {
            _ = flock(leaseDescriptor, LOCK_UN)
            close(leaseDescriptor)
        }
    }

    func load() throws -> [HistoryMutation] {
        try reload()
    }

    func reload() throws -> [HistoryMutation] {
        do {
            try acquireLeaseIfNeeded()
            let mutations: [HistoryMutation]
            do {
                let data = try Data(contentsOf: fileURL)
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1 else {
                    throw HistoryRecoveryError.journalUnavailable(
                        "Unsupported journal version \(envelope.version).")
                }
                guard Set(envelope.mutations.map(\.id)).count == envelope.mutations.count else {
                    throw HistoryRecoveryError.journalUnavailable(
                        "The journal contains duplicate operation identifiers.")
                }
                mutations = envelope.mutations
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                mutations = []
            }
            accessState = .ready
            return mutations
        } catch HistoryRecoveryError.journalInUse {
            throw HistoryRecoveryError.journalInUse
        } catch {
            let message = Self.message(for: error)
            accessState = .blocked(message)
            throw HistoryRecoveryError.journalUnavailable(message)
        }
    }

    func replace(with mutations: [HistoryMutation]) throws {
        guard leaseDescriptor != nil else {
            throw HistoryRecoveryError.journalInUse
        }
        switch accessState {
        case .ready:
            break
        case .unchecked:
            throw HistoryRecoveryError.journalUnavailable("The journal has not been checked yet.")
        case .blocked(let message):
            throw HistoryRecoveryError.journalUnavailable(message)
        }

        do {
            if mutations.isEmpty {
                if unlink(fileURL.path) != 0, errno != ENOENT {
                    throw Self.posixError()
                }
                try synchronizeDirectory()
                return
            }

            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(version: 1, mutations: mutations))
            let temporaryURL = directoryURL.appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                                  S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw Self.posixError() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                guard rename(temporaryURL.path, fileURL.path) == 0 else {
                    throw Self.posixError()
                }
                try synchronizeDirectory()
            } catch {
                try? handle.close()
                _ = unlink(temporaryURL.path)
                throw error
            }
        } catch {
            throw HistoryRecoveryError.journalUnavailable(Self.message(for: error))
        }
    }

    private func acquireLeaseIfNeeded() throws {
        guard leaseDescriptor == nil else { return }
        let lockURL = fileURL.appendingPathExtension("lock")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.posixError() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw HistoryRecoveryError.journalInUse
            }
            errno = lockError
            throw Self.posixError()
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let permissionError = errno
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            errno = permissionError
            throw Self.posixError()
        }
        leaseDescriptor = descriptor
    }

    private func synchronizeDirectory() throws {
        let descriptor = open(fileURL.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Self.posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func message(for error: Error) -> String {
        if let recovery = error as? HistoryRecoveryError,
           let description = recovery.errorDescription {
            return description.replacingOccurrences(of: "History recovery journal: ", with: "")
        }
        return error.localizedDescription
    }
}
