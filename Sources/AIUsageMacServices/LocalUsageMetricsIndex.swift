import AIUsageCore
import CryptoKit
import Foundation
import SQLite3

struct IndexedUsageEvent {
    let timestamp: Date
    let model: String
    let input: Int
    let cachedInput: Int
    let cacheWrite: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int
    let output: Int
    let reasoning: Int
    let unclassified: Int
    let total: Int
}

public struct LocalUsageMetricsDiagnostics: Sendable, Equatable {
    public let scannedFiles: Int
    public let scannedBytes: Int64
    public let reusedFiles: Int
    public let didChangeIndex: Bool

    public init(
        scannedFiles: Int,
        scannedBytes: Int64,
        reusedFiles: Int,
        didChangeIndex: Bool = false
    ) {
        self.scannedFiles = scannedFiles
        self.scannedBytes = scannedBytes
        self.reusedFiles = reusedFiles
        self.didChangeIndex = didChangeIndex
    }
}

final class LocalUsageMetricsIndex {
    private static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60
    private static let upsertSQL = """
    INSERT INTO events (
        provider, source_path, event_key, timestamp, model, input, cached_input,
        cache_write, cache_write_5m, cache_write_1h, output, reasoning,
        unclassified, total
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(provider, source_path, event_key) DO UPDATE SET
        timestamp = excluded.timestamp,
        model = excluded.model,
        input = excluded.input,
        cached_input = excluded.cached_input,
        cache_write = excluded.cache_write,
        cache_write_5m = excluded.cache_write_5m,
        cache_write_1h = excluded.cache_write_1h,
        output = excluded.output,
        reasoning = excluded.reasoning,
        unclassified = excluded.unclassified,
        total = excluded.total
    WHERE excluded.total >= events.total
    """
    private struct FileState {
        let size: Int64
        let modificationDate: TimeInterval
        let inode: UInt64
        let offset: Int64
        let currentModel: String
        let previous: IndexedCodexTokenCount
    }

    private struct FileMetadata {
        let url: URL
        let size: Int64
        let modificationDate: TimeInterval
        let inode: UInt64
    }

    private let database: OpaquePointer
    private var upsertStatement: OpaquePointer?
    private let fractionalISO8601 = ISO8601DateFormatter()
    private let iso8601 = ISO8601DateFormatter()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let usageNeedle = Data("\"usage\"".utf8)
    private let tokenCountNeedle = Data("\"token_count\"".utf8)
    private let turnContextNeedle = Data("\"turn_context\"".utf8)

    init(databaseURL: URL) throws {
        upsertStatement = nil
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "AIUsageMetricsIndex", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        database = handle
        fractionalISO8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA temp_store=MEMORY")
        try execute("""
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            size INTEGER NOT NULL,
            modification_date REAL NOT NULL,
            inode INTEGER NOT NULL,
            offset INTEGER NOT NULL,
            current_model TEXT NOT NULL,
            previous_input INTEGER NOT NULL,
            previous_cached_input INTEGER NOT NULL,
            previous_cache_write INTEGER NOT NULL,
            previous_output INTEGER NOT NULL,
            previous_reasoning INTEGER NOT NULL,
            previous_total INTEGER NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS events (
            provider TEXT NOT NULL,
            source_path TEXT NOT NULL,
            event_key TEXT NOT NULL,
            timestamp REAL NOT NULL,
            model TEXT NOT NULL,
            input INTEGER NOT NULL,
            cached_input INTEGER NOT NULL,
            cache_write INTEGER NOT NULL,
            cache_write_5m INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL,
            output INTEGER NOT NULL,
            reasoning INTEGER NOT NULL,
            unclassified INTEGER NOT NULL,
            total INTEGER NOT NULL,
            PRIMARY KEY (provider, source_path, event_key)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS events_period ON events(provider, timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS events_dedupe ON events(provider, event_key, total)")
        upsertStatement = try prepare(Self.upsertSQL)
    }

    deinit {
        if let upsertStatement { sqlite3_finalize(upsertStatement) }
        sqlite3_close(database)
    }

    func synchronize(provider: UsageProviderID, root: URL) throws -> LocalUsageMetricsDiagnostics {
        let retentionCutoff = Date.now.addingTimeInterval(-Self.retentionInterval)
        let files = jsonlFiles(below: root, modifiedSince: retentionCutoff)
        let currentPaths = Set(files.map { identifier(for: $0.url.path) })
        let removedMissingFiles = try removeMissingFiles(
            provider: provider,
            currentPaths: currentPaths
        )

        var scannedFiles = 0
        var scannedBytes: Int64 = 0
        var reusedFiles = 0

        for metadata in files {
            guard !Task.isCancelled else { break }
            let sourceID = identifier(for: metadata.url.path)
            let prior = try fileState(path: sourceID)
            let mustRebuild = prior.map {
                $0.inode != metadata.inode || metadata.size < $0.offset
            } ?? true

            if !mustRebuild, let prior, metadata.size == prior.offset {
                reusedFiles += 1
                if metadata.modificationDate != prior.modificationDate || metadata.size != prior.size {
                    try saveFileState(
                        metadata: metadata,
                        provider: provider,
                        offset: prior.offset,
                        currentModel: prior.currentModel,
                        previous: prior.previous
                    )
                }
                continue
            }

            let startingOffset = mustRebuild ? 0 : (prior?.offset ?? 0)
            let startingModel = mustRebuild ? "unknown" : (prior?.currentModel ?? "unknown")
            let startingPrevious = mustRebuild ? .zero : (prior?.previous ?? .zero)
            let result = try ingest(
                metadata: metadata,
                provider: provider,
                startingOffset: startingOffset,
                startingModel: startingModel,
                startingPrevious: startingPrevious,
                rebuild: mustRebuild
            )
            scannedFiles += 1
            scannedBytes += result.scannedBytes
        }

        let prunedEvents = try pruneEvents(olderThan: retentionCutoff)

        return LocalUsageMetricsDiagnostics(
            scannedFiles: scannedFiles,
            scannedBytes: scannedBytes,
            reusedFiles: reusedFiles,
            didChangeIndex: removedMissingFiles || scannedFiles > 0 || prunedEvents
        )
    }

    func events(
        provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [IndexedUsageEvent] {
        let selection: String
        if provider == .claude {
            selection = """
            SELECT timestamp, model, input, cached_input, cache_write, cache_write_5m,
                   cache_write_1h, output, reasoning, unclassified, total
            FROM (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY event_key ORDER BY total DESC, timestamp DESC
                ) AS rank
                FROM events
                WHERE provider = ? AND timestamp >= ? AND timestamp < ?
            )
            WHERE rank = 1
            """
        } else {
            selection = """
            SELECT timestamp, model, input, cached_input, cache_write, cache_write_5m,
                   cache_write_1h, output, reasoning, unclassified, total
            FROM events
            WHERE provider = ? AND timestamp >= ? AND timestamp < ?
            """
        }

        let statement = try prepare(selection)
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, periodStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, periodEnd.timeIntervalSince1970)

        var result: [IndexedUsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(IndexedUsageEvent(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                model: textColumn(statement, 1),
                input: integerColumn(statement, 2),
                cachedInput: integerColumn(statement, 3),
                cacheWrite: integerColumn(statement, 4),
                cacheWrite5m: integerColumn(statement, 5),
                cacheWrite1h: integerColumn(statement, 6),
                output: integerColumn(statement, 7),
                reasoning: integerColumn(statement, 8),
                unclassified: integerColumn(statement, 9),
                total: integerColumn(statement, 10)
            ))
        }
        return result
    }

    func dailyTokenTotals(
        provider: UsageProviderID,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar = .current
    ) throws -> [Date: Int] {
        let selection: String
        if provider == .claude {
            selection = """
            SELECT timestamp, total
            FROM (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY event_key ORDER BY total DESC, timestamp DESC
                ) AS rank
                FROM events
                WHERE provider = ? AND timestamp >= ? AND timestamp < ?
            )
            WHERE rank = 1
            """
        } else {
            selection = """
            SELECT timestamp, total FROM events
            WHERE provider = ? AND timestamp >= ? AND timestamp < ?
            """
        }

        let statement = try prepare(selection)
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, periodStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, periodEnd.timeIntervalSince1970)

        var totals: [Date: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            totals[calendar.startOfDay(for: timestamp), default: 0] += integerColumn(statement, 1)
        }
        return totals
    }

    private func ingest(
        metadata: FileMetadata,
        provider: UsageProviderID,
        startingOffset: Int64,
        startingModel: String,
        startingPrevious: IndexedCodexTokenCount,
        rebuild: Bool
    ) throws -> (scannedBytes: Int64, processedOffset: Int64) {
        let sourceID = identifier(for: metadata.url.path)
        let handle = try FileHandle(forReadingFrom: metadata.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startingOffset))

        try execute("BEGIN IMMEDIATE")
        do {
            if rebuild {
                try deleteEvents(sourcePath: sourceID, provider: provider)
            }

            var currentModel = startingModel
            var previous = startingPrevious
            var buffer = Data()
            var scannedBytes: Int64 = 0
            var processedBytes: Int64 = 0
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard !Task.isCancelled else { throw CancellationError() }
                scannedBytes += Int64(chunk.count)
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    let consumed = Int64(line.count + 1)
                    let lineOffset = startingOffset + processedBytes
                    buffer.removeSubrange(buffer.startIndex...newline)
                    processedBytes += consumed
                    guard !line.isEmpty else { continue }
                    try ingestLine(
                        line,
                        lineOffset: lineOffset,
                        provider: provider,
                        sourceID: sourceID,
                        currentModel: &currentModel,
                        previous: &previous
                    )
                }
            }

            let processedOffset = startingOffset + processedBytes
            try saveFileState(
                metadata: metadata,
                provider: provider,
                offset: processedOffset,
                currentModel: currentModel,
                previous: previous
            )
            try execute("COMMIT")
            return (scannedBytes, processedOffset)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func ingestLine(
        _ line: Data,
        lineOffset: Int64,
        provider: UsageProviderID,
        sourceID: String,
        currentModel: inout String,
        previous: inout IndexedCodexTokenCount
    ) throws {
        switch provider {
        case .claude:
            guard line.range(of: usageNeedle) != nil else { return }
            if let event = claudeEvent(line), event.total > 0 {
                try upsert(event: event, provider: provider, sourcePath: sourceID)
            }
            return
        case .codex:
            let isTokenCount = line.range(of: tokenCountNeedle) != nil
            let isTurnContext = line.range(of: turnContextNeedle) != nil
            guard isTokenCount || isTurnContext else { return }
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }

        switch provider {
        case .claude:
            return
        case .codex:
            let payload = object["payload"] as? [String: Any]
            if object["type"] as? String == "turn_context",
               let model = payload?["model"] as? String {
                currentModel = model
            }
            guard
                payload?["type"] as? String == "token_count",
                let info = payload?["info"] as? [String: Any],
                let total = info["total_token_usage"] as? [String: Any],
                let timestamp = date(from: object["timestamp"])
            else { return }

            let current = IndexedCodexTokenCount(total)
            let delta = current.delta(from: previous)
            previous = current
            guard delta.total > 0 else { return }
            let uncached = max(0, delta.input - delta.cachedInput - delta.cacheWrite)
            let event = IndexedEvent(
                key: String(lineOffset),
                timestamp: timestamp,
                model: currentModel,
                input: uncached,
                cachedInput: delta.cachedInput,
                cacheWrite: delta.cacheWrite,
                cacheWrite5m: delta.cacheWrite,
                cacheWrite1h: 0,
                output: delta.output,
                reasoning: delta.reasoning,
                unclassified: max(0, delta.total - delta.input - delta.output),
                total: delta.total
            )
            try upsert(event: event, provider: provider, sourcePath: sourceID)
        }
    }

    private struct IndexedEvent {
        let key: String
        let timestamp: Date
        let model: String
        let input: Int
        let cachedInput: Int
        let cacheWrite: Int
        let cacheWrite5m: Int
        let cacheWrite1h: Int
        let output: Int
        let reasoning: Int
        let unclassified: Int
        let total: Int
    }

    private func claudeEvent(_ line: Data) -> IndexedEvent? {
        guard
            let messageRange = keyRange("message", in: line),
            let usageRange = keyRange("usage", in: line, backwards: true),
            messageRange.upperBound < usageRange.lowerBound
        else { return nil }
        let timestampString = stringValue(
            for: "timestamp",
            in: line,
            range: usageRange.lowerBound..<line.endIndex
        ) ?? stringValue(for: "timestamp", in: line, backwards: true)
        guard let timestampString, let timestamp = date(from: timestampString) else { return nil }
        let messageHeaderEnd = keyRange(
            "content",
            in: line,
            range: messageRange.upperBound..<usageRange.lowerBound
        )?.lowerBound ?? usageRange.lowerBound
        let messageHeader = messageRange.upperBound..<messageHeaderEnd
        guard
            let model = stringValue(for: "model", in: line, range: messageHeader),
            let messageID = stringValue(for: "id", in: line, range: messageHeader)
                ?? stringValue(for: "uuid", in: line)
        else { return nil }
        guard model != "<synthetic>" else { return nil }

        let tokenRange = usageRange.lowerBound..<line.endIndex
        let input = integerValue(for: "input_tokens", in: line, range: tokenRange)
        let cached = integerValue(for: "cache_read_input_tokens", in: line, range: tokenRange)
        let cacheWrite = integerValue(for: "cache_creation_input_tokens", in: line, range: tokenRange)
        let cacheWrite5m = integerValue(for: "ephemeral_5m_input_tokens", in: line, range: tokenRange)
        let cacheWrite1h = integerValue(for: "ephemeral_1h_input_tokens", in: line, range: tokenRange)
        let output = integerValue(for: "output_tokens", in: line, range: tokenRange)
        return IndexedEvent(
            key: identifier(for: messageID),
            timestamp: timestamp,
            model: model,
            input: input,
            cachedInput: cached,
            cacheWrite: cacheWrite,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            output: output,
            reasoning: 0,
            unclassified: 0,
            total: input + cached + cacheWrite + output
        )
    }

    private func keyRange(
        _ key: String,
        in data: Data,
        range: Range<Data.Index>? = nil,
        backwards: Bool = false
    ) -> Range<Data.Index>? {
        let needle = Data("\"\(key)\"".utf8)
        return data.range(
            of: needle,
            options: backwards ? .backwards : [],
            in: range ?? data.startIndex..<data.endIndex
        )
    }

    private func stringValue(
        for key: String,
        in data: Data,
        range: Range<Data.Index>? = nil,
        backwards: Bool = false
    ) -> String? {
        guard let keyRange = keyRange(key, in: data, range: range, backwards: backwards) else {
            return nil
        }
        var index = keyRange.upperBound
        let limit = range?.upperBound ?? data.endIndex
        while index < limit, data[index] == 0x20 || data[index] == 0x09 { index += 1 }
        guard index < limit, data[index] == 0x3A else { return nil }
        index += 1
        while index < limit, data[index] == 0x20 || data[index] == 0x09 { index += 1 }
        guard index < limit, data[index] == 0x22 else { return nil }
        index += 1
        let start = index
        var escaped = false
        while index < limit {
            let byte = data[index]
            if byte == 0x22, !escaped {
                return String(data: data[start..<index], encoding: .utf8)
            }
            if byte == 0x5C, !escaped {
                escaped = true
            } else {
                escaped = false
            }
            index += 1
        }
        return nil
    }

    private func integerValue(
        for key: String,
        in data: Data,
        range: Range<Data.Index>
    ) -> Int {
        guard let keyRange = keyRange(key, in: data, range: range) else { return 0 }
        var index = keyRange.upperBound
        while index < range.upperBound, data[index] == 0x20 || data[index] == 0x09 { index += 1 }
        guard index < range.upperBound, data[index] == 0x3A else { return 0 }
        index += 1
        while index < range.upperBound, data[index] == 0x20 || data[index] == 0x09 { index += 1 }
        var value = 0
        var foundDigit = false
        while index < range.upperBound, data[index] >= 0x30, data[index] <= 0x39 {
            foundDigit = true
            value = value * 10 + Int(data[index] - 0x30)
            index += 1
        }
        return foundDigit ? value : 0
    }

    private func date(from value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? iso8601.date(from: value)
    }

    private func upsert(event: IndexedEvent, provider: UsageProviderID, sourcePath: String) throws {
        guard let statement = upsertStatement else {
            throw NSError(domain: "AIUsageMetricsIndex", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "The metrics index statement is unavailable."
            ])
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        defer { sqlite3_reset(statement) }
        bind(provider.rawValue, to: 1, in: statement)
        bind(sourcePath, to: 2, in: statement)
        bind(event.key, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, event.timestamp.timeIntervalSince1970)
        bind(event.model, to: 5, in: statement)
        for (index, value) in [
            event.input, event.cachedInput, event.cacheWrite, event.cacheWrite5m,
            event.cacheWrite1h, event.output, event.reasoning, event.unclassified, event.total
        ].enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 6), sqlite3_int64(value))
        }
        try stepDone(statement)
    }

    private func saveFileState(
        metadata: FileMetadata,
        provider: UsageProviderID,
        offset: Int64,
        currentModel: String,
        previous: IndexedCodexTokenCount
    ) throws {
        let statement = try prepare("""
        INSERT INTO files (
            path, provider, size, modification_date, inode, offset, current_model,
            previous_input, previous_cached_input, previous_cache_write,
            previous_output, previous_reasoning, previous_total
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            provider = excluded.provider,
            size = excluded.size,
            modification_date = excluded.modification_date,
            inode = excluded.inode,
            offset = excluded.offset,
            current_model = excluded.current_model,
            previous_input = excluded.previous_input,
            previous_cached_input = excluded.previous_cached_input,
            previous_cache_write = excluded.previous_cache_write,
            previous_output = excluded.previous_output,
            previous_reasoning = excluded.previous_reasoning,
            previous_total = excluded.previous_total
        """)
        defer { sqlite3_finalize(statement) }
        bind(identifier(for: metadata.url.path), to: 1, in: statement)
        bind(provider.rawValue, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, metadata.size)
        sqlite3_bind_double(statement, 4, metadata.modificationDate)
        sqlite3_bind_int64(statement, 5, sqlite3_int64(metadata.inode))
        sqlite3_bind_int64(statement, 6, offset)
        bind(currentModel, to: 7, in: statement)
        for (index, value) in [
            previous.input, previous.cachedInput, previous.cacheWrite,
            previous.output, previous.reasoning, previous.total
        ].enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 8), sqlite3_int64(value))
        }
        try stepDone(statement)
    }

    private func fileState(path: String) throws -> FileState? {
        let statement = try prepare("""
        SELECT size, modification_date, inode, offset, current_model,
               previous_input, previous_cached_input, previous_cache_write,
               previous_output, previous_reasoning, previous_total
        FROM files WHERE path = ?
        """)
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return FileState(
            size: sqlite3_column_int64(statement, 0),
            modificationDate: sqlite3_column_double(statement, 1),
            inode: UInt64(sqlite3_column_int64(statement, 2)),
            offset: sqlite3_column_int64(statement, 3),
            currentModel: textColumn(statement, 4),
            previous: IndexedCodexTokenCount(
                input: integerColumn(statement, 5),
                cachedInput: integerColumn(statement, 6),
                cacheWrite: integerColumn(statement, 7),
                output: integerColumn(statement, 8),
                reasoning: integerColumn(statement, 9),
                total: integerColumn(statement, 10)
            )
        )
    }

    private func removeMissingFiles(
        provider: UsageProviderID,
        currentPaths: Set<String>
    ) throws -> Bool {
        let statement = try prepare("SELECT path FROM files WHERE provider = ?")
        bind(provider.rawValue, to: 1, in: statement)
        var missing: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = textColumn(statement, 0)
            if !currentPaths.contains(path) { missing.append(path) }
        }
        sqlite3_finalize(statement)

        for path in missing {
            try deleteEvents(sourcePath: path, provider: provider)
            let delete = try prepare("DELETE FROM files WHERE path = ?")
            bind(path, to: 1, in: delete)
            try stepDone(delete)
            sqlite3_finalize(delete)
        }
        return !missing.isEmpty
    }

    private func deleteEvents(sourcePath: String, provider: UsageProviderID) throws {
        let statement = try prepare("DELETE FROM events WHERE provider = ? AND source_path = ?")
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: 1, in: statement)
        bind(sourcePath, to: 2, in: statement)
        try stepDone(statement)
    }

    private func pruneEvents(olderThan cutoff: Date) throws -> Bool {
        let statement = try prepare("DELETE FROM events WHERE timestamp < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        try stepDone(statement)
        return sqlite3_changes(database) > 0
    }

    private func jsonlFiles(below root: URL, modifiedSince cutoff: Date) -> [FileMetadata] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attributes[.size] as? NSNumber,
                let modified = attributes[.modificationDate] as? Date,
                let inode = attributes[.systemFileNumber] as? NSNumber,
                modified >= cutoff
            else { return nil }
            return FileMetadata(
                url: url,
                size: size.int64Value,
                modificationDate: modified.timeIntervalSince1970,
                inode: inode.uint64Value
            )
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw NSError(domain: "AIUsageMetricsIndex", code: 2, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw NSError(domain: "AIUsageMetricsIndex", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))
            ])
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "AIUsageMetricsIndex", code: 4, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))
            ])
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func integerColumn(_ statement: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    private func date(from value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return fractionalISO8601.date(from: value) ?? iso8601.date(from: value)
    }

    private func identifier(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct IndexedCodexTokenCount {
    let input: Int
    let cachedInput: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let total: Int

    static let zero = IndexedCodexTokenCount(
        input: 0,
        cachedInput: 0,
        cacheWrite: 0,
        output: 0,
        reasoning: 0,
        total: 0
    )

    init(
        input: Int,
        cachedInput: Int,
        cacheWrite: Int,
        output: Int,
        reasoning: Int,
        total: Int
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoning = reasoning
        self.total = total
    }

    init(_ object: [String: Any]) {
        input = Self.integer(object["input_tokens"])
        cachedInput = Self.integer(object["cached_input_tokens"])
        cacheWrite = Self.integer(object["cache_write_input_tokens"])
        output = Self.integer(object["output_tokens"])
        reasoning = Self.integer(object["reasoning_output_tokens"])
        total = Self.integer(object["total_tokens"])
    }

    func delta(from previous: IndexedCodexTokenCount) -> IndexedCodexTokenCount {
        let baseline = total < previous.total ? .zero : previous
        return IndexedCodexTokenCount(
            input: max(0, input - baseline.input),
            cachedInput: max(0, cachedInput - baseline.cachedInput),
            cacheWrite: max(0, cacheWrite - baseline.cacheWrite),
            output: max(0, output - baseline.output),
            reasoning: max(0, reasoning - baseline.reasoning),
            total: max(0, total - baseline.total)
        )
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}
