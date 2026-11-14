import Darwin
import Foundation

/// Writes new files and never replaces one: each name, or its first free `_N` variant,
/// is created with O_CREAT | O_EXCL, so checking and creating are a single step. If a
/// later file fails or the task is cancelled, unchanged file identities are removed.
/// Open identity descriptors prevent inode reuse while the batch is in progress.
enum PDFNewFileWriter {
    private final class CreatedFile {
        let url: URL
        private let identityDescriptor: Int32

        init(url: URL, descriptor: Int32) throws {
            self.url = url
            identityDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard identityDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        deinit { Darwin.close(identityDescriptor) }

        func removeIfStillOwned() {
            Self.removeIfStillOwned(at: url, descriptor: identityDescriptor)
        }

        static func removeIfStillOwned(at url: URL, descriptor: Int32) {
            var original = stat()
            var current = stat()
            // lstat deliberately does not follow a replacement symlink.
            guard fstat(descriptor, &original) == 0,
                  lstat(url.path, &current) == 0,
                  original.st_dev == current.st_dev,
                  original.st_ino == current.st_ino,
                  original.st_gen == current.st_gen else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func write(
        _ contents: [Data],
        names: [String],
        in directory: URL,
        maximumCandidates: Int = 10_000,
        beforeEachFile: (Int) throws -> Void = { _ in }
    ) throws -> [URL] {
        guard contents.count == names.count else { throw VacanciesPDFExporter.ExportError.missingPreparedExport }
        var written: [CreatedFile] = []
        do {
            for (index, (data, name)) in zip(contents, names).enumerated() {
                try Task.checkCancellation()
                try beforeEachFile(index)
                written.append(try writeNewFile(data, name: name, in: directory, maximumCandidates: maximumCandidates))
            }
            try Task.checkCancellation()
            return written.map(\.url)
        } catch {
            for file in written { file.removeIfStillOwned() }
            throw error
        }
    }

    static func writeFiles(_ files: [URL], names: [String], in directory: URL) throws -> [URL] {
        guard files.count == names.count else { throw VacanciesPDFExporter.ExportError.missingPreparedExport }
        var written: [CreatedFile] = []
        do {
            for (file, name) in zip(files, names) {
                try Task.checkCancellation()
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                written.append(try writeNewFile(data, name: name, in: directory, maximumCandidates: 10_000))
            }
            try Task.checkCancellation()
            return written.map(\.url)
        } catch {
            for file in written { file.removeIfStillOwned() }
            throw error
        }
    }

    private static func writeNewFile(_ data: Data, name: String, in directory: URL, maximumCandidates: Int) throws -> CreatedFile {
        for number in 1...max(1, maximumCandidates) {
            let candidate = number == 1 ? name : PDFFileNameBuilder.fileName(
                base: name, semanticSuffix: String(number), fallback: "vacancy"
            )
            let url = directory.appendingPathComponent(candidate)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                let code = errno
                if code == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            // Keep the identity alive even after the writer is closed.
            let created: CreatedFile
            do {
                created = try CreatedFile(url: url, descriptor: descriptor)
            } catch {
                CreatedFile.removeIfStillOwned(at: url, descriptor: descriptor)
                try? handle.close()
                throw error
            }
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                created.removeIfStillOwned()
                throw error
            }
            return created
        }
        throw VacanciesPDFExporter.ExportError.noAvailableFileName
    }
}
