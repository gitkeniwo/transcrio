import AppKit
import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

/// The worker's answer to an `export` op.
enum ExportReply: Sendable {
    case done([String: String])
    case failed(String)
}

/// The 36 pt capsule at the bottom of the pane where the action happened.
struct Toast: Identifiable, Equatable {
    enum Pane: Equatable { case sidebar, center, inspector }

    let id = UUID()
    var pane: Pane
    var text: AttributedString
    var failed = false
    /// [Show]: these files in Finder.
    var reveal: [URL] = []
    /// [Save As…] after a failed Save to Downloads.
    var saveAs: (entry: LibraryEntry.ID, format: OutputFormat)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }

    /// "Saved **x.md** to Downloads": `**…**` spans are bold.
    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Locate… picked a file whose fingerprint differs from the entry's.
struct LocateMismatch: Identifiable {
    let id = UUID()
    var entry: LibraryEntry.ID
    var url: URL
    var fingerprint: SourceFingerprint?
}

extension AppModel {
    // MARK: Chips

    static func makingKey(_ id: LibraryEntry.ID, _ f: OutputFormat) -> String { "\(id)/\(f.rawValue)" }

    /// The chip for `format`. "Have" means the file is in the folder;
    /// the other md/txt variant is remade on export without a state change.
    func chipState(_ entry: LibraryEntry, _ format: OutputFormat) -> FormatChipState {
        let key = Self.makingKey(entry.id, format)
        if makingShown.contains(key) { return .making }
        if let error = exportFailures[key] { return .failed(error) }
        if format == .json || entry.formats[format.rawValue] != nil { return .have }
        return .canMake
    }

    /// Why srt/vtt timing is estimated, read from the transcript.
    func estimatedTiming(_ entry: LibraryEntry, notices: [Notice]) -> EstimatedTiming? {
        EstimatedTiming.reason(cueTiming: entry.cueTiming, notices: notices, language: entry.language,
                               alignedLanguages: backends?.defaultBackend?.alignedLanguages ?? [])
    }

    // MARK: Making formats

    /// Sends one `export` op and waits for its reply.
    func runExport(_ request: ServeExport) async -> ExportReply {
        guard let worker = await ensureWorker() else {
            return .failed("The transcribe command isn’t available.")
        }
        return await withCheckedContinuation { c in
            exportWaiters[request.id] = c
            Task { await worker.send(.export(request)) }
        }
    }

    /// The files for `formats` in the entry folder, made from transcript.json when missing (or
    /// the other md/txt variant). json is transcript.json itself.
    func ensureFormats(_ id: LibraryEntry.ID, _ formats: [OutputFormat], timestamps: Bool? = nil) async -> Result<[OutputFormat: URL], ExportError> {
        guard let entry = library[id] else { return .failure(.init(message: "This entry was removed.")) }
        let ts = timestamps ?? exportTimestamps
        if !entry.formats.isEmpty { try? library.forgetMissingFormats(id) }
        let current = library[id] ?? entry
        var out: [OutputFormat: URL] = [:]
        var missing: [OutputFormat] = []
        for f in OutputFormat.ordered(formats) {
            if let url = library.cachedURL(current, f, timestamps: ts) { out[f] = url } else if f != .json { missing.append(f) }
        }
        if formats.contains(.json), out[.json] == nil {
            return .failure(.init(message: "transcript.json is missing from the library folder."))
        }
        guard !missing.isEmpty else { return .success(out) }

        let keys = missing.map { Self.makingKey(id, $0) }
        for k in keys { exportFailures[k] = nil; makingStarted.insert(k) }
        Task { @MainActor [weak self] in
            // The making state only shows past 150 ms.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let still = keys.filter(self.makingStarted.contains)
            if !still.isEmpty { withAnimation(.easeOut(duration: 0.15)) { self.makingShown.formUnion(still) } }
        }
        defer {
            makingStarted.subtract(keys)
            withAnimation(.easeOut(duration: 0.15)) { makingShown.subtract(keys) }
        }
        let request = ServeExport(id: "x-\(UUID().uuidString.prefix(8))", transcript: library.transcriptURL(current).path,
                                  formats: missing.map(\.rawValue), outputDir: library.folderURL(current).path,
                                  timestamps: ts, title: current.title)
        switch await runExport(request) {
        case .failed(let message):
            for k in keys { exportFailures[k] = message }
            return .failure(.init(message: message))
        case .done(let outputs):
            let updated = (try? library.recordFormats(id, outputs: outputs, timestamps: ts)) ?? nil
            for f in missing {
                guard let path = outputs[f.rawValue] else {
                    exportFailures[Self.makingKey(id, f)] = "The worker didn’t write \(f.rawValue)."
                    return .failure(.init(message: "Couldn’t make \(f.rawValue)."))
                }
                out[f] = URL(fileURLWithPath: path)
            }
            _ = updated
            return .success(out)
        }
    }

    /// Writes `formats` of an entry to `directory` as `<title>.<ext>` via a scratch folder
    /// (copies: their own Timestamps value, never touching the cached variant).
    func exportCopies(_ id: LibraryEntry.ID, _ formats: [OutputFormat], timestamps: Bool) async -> Result<[OutputFormat: URL], ExportError> {
        guard let entry = library[id] else { return .failure(.init(message: "This entry was removed.")) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("transcrio-export-\(UUID().uuidString)")
        let made = formats.filter { $0 != .json }
        var out: [OutputFormat: URL] = [:]
        if !made.isEmpty {
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let request = ServeExport(id: "x-\(UUID().uuidString.prefix(8))", transcript: library.transcriptURL(entry).path,
                                      formats: made.map(\.rawValue), outputDir: scratch.path, timestamps: timestamps, title: entry.title)
            switch await runExport(request) {
            case .failed(let m): return .failure(.init(message: m))
            case .done(let outputs):
                for f in made { if let p = outputs[f.rawValue] { out[f] = URL(fileURLWithPath: p) } }
            }
        }
        if formats.contains(.json) { out[.json] = library.transcriptURL(entry) }
        return .success(out)
    }

    // MARK: Destinations

    /// `TRANSCRIBE_DOWNLOADS` (tests), else ~/Downloads.
    var downloadsFolder: URL {
        if let p = DevSupport.environment["TRANSCRIBE_DOWNLOADS"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// Copies `source` to `url` (replacing what's there: Save As confirmed it).
    nonisolated static func place(_ source: URL, at url: URL, replace: Bool) throws {
        let fm = FileManager.default
        if replace, fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: try temporaryCopy(of: source, named: url.lastPathComponent))
        } else {
            try fm.copyItem(at: source, to: url)
        }
    }

    nonisolated static func temporaryCopy(of source: URL, named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcrio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    // MARK: Actions

    /// Save to Downloads (⌥⌘S): never replaces, a name in use gets " 2".
    func saveToDownloads(_ ids: [LibraryEntry.ID], formats: [OutputFormat], pane: Toast.Pane) {
        let formats = OutputFormat.ordered(formats)
        guard !ids.isEmpty, !formats.isEmpty else { return }
        if formats.count == 1 { lastExportFormat = formats[0] }
        Task {
            let dir = downloadsFolder
            var saved: [URL] = []
            var renamed: URL?
            var taken: Set<String> = []
            for id in ids {
                guard let entry = library[id] else { continue }
                switch await ensureFormats(id, formats) {
                case .failure(let e):
                    show(Toast(pane: pane, text: Toast.styled("Couldn’t make **\(ExportNaming.fileName(title: entry.title, format: formats[0]))** · \(e.message)"),
                               failed: true))
                    return
                case .success(let files):
                    for f in formats {
                        guard let src = files[f] else { continue }
                        let name = ExportNaming.fileName(title: entry.title, format: f)
                        let url = ExportNaming.available(name, in: dir, taken: taken)
                        taken.insert(url.lastPathComponent)
                        do {
                            try Self.place(src, at: url, replace: false)
                        } catch {
                            let why = FileManager.default.isWritableFile(atPath: dir.path) ? error.localizedDescription : "Downloads isn’t writable"
                            show(Toast(pane: pane, text: Toast.styled("Couldn’t save **\(name)** · \(why)"), failed: true,
                                       saveAs: (id, f)))
                            return
                        }
                        if url.lastPathComponent != name { renamed = url }
                        saved.append(url)
                    }
                }
            }
            guard !saved.isEmpty else { return }
            let text: String
            if saved.count > 1 {
                text = "Saved \(saved.count) files to Downloads"
            } else if let renamed {
                text = "Saved as **\(renamed.lastPathComponent)** · a file with that name was there"
            } else {
                text = "Saved **\(saved[0].lastPathComponent)** to Downloads"
            }
            show(Toast(pane: pane, text: Toast.styled(text), reveal: saved))
        }
    }

    /// Save As… (⇧⌘S): one format → NSSavePanel; several → a folder, keeping both.
    func saveAs(_ ids: [LibraryEntry.ID], formats: [OutputFormat], pane: Toast.Pane) {
        let formats = OutputFormat.ordered(formats)
        guard let first = ids.first, let entry = library[first], !formats.isEmpty else { return }
        if ids.count == 1, formats.count == 1 {
            let f = formats[0]
            let panel = NSSavePanel()
            panel.nameFieldStringValue = ExportNaming.fileName(title: entry.title, format: f)
            if let type = f.utType { panel.allowedContentTypes = [type] }
            panel.canCreateDirectories = true
            panel.directoryURL = downloadsFolder
            guard panel.runModal() == .OK, let url = panel.url else { return }
            lastExportFormat = f
            Task {
                switch await ensureFormats(first, [f]) {
                case .failure(let e): show(Toast(pane: pane, text: Toast.styled("Couldn’t make **\(url.lastPathComponent)** · \(e.message)"), failed: true))
                case .success(let files):
                    guard let src = files[f] else { return }
                    do {
                        try Self.place(src, at: url, replace: true)
                        show(Toast(pane: pane, text: Toast.styled("Saved **\(url.lastPathComponent)**"), reveal: [url]))
                    } catch {
                        show(Toast(pane: pane, text: Toast.styled("Couldn’t save **\(url.lastPathComponent)** · \(error.localizedDescription)"), failed: true))
                    }
                }
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save \(ids.count * formats.count) files. A name in use gets “ 2”."
        panel.directoryURL = downloadsFolder
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            var saved: [URL] = []
            var taken: Set<String> = []
            for id in ids {
                guard let entry = library[id], case .success(let files) = await ensureFormats(id, formats) else { continue }
                for f in formats {
                    guard let src = files[f] else { continue }
                    let url = ExportNaming.available(ExportNaming.fileName(title: entry.title, format: f), in: dir, taken: taken)
                    taken.insert(url.lastPathComponent)
                    if (try? Self.place(src, at: url, replace: false)) != nil { saved.append(url) }
                }
            }
            let expected = ids.count * formats.count
            show(Toast(pane: pane, text: Toast.styled(saved.count == expected ? "Saved \(saved.count) files to **\(dir.lastPathComponent)**"
                                                       : "Saved \(saved.count) of \(expected) files to **\(dir.lastPathComponent)**"),
                       failed: saved.count < expected, reveal: saved))
        }
    }

    /// Copy Text (⌘C): the transcript as plain text (md when Timestamps is on keeps them).
    func copyText(_ id: LibraryEntry.ID, format: OutputFormat? = nil, pane: Toast.Pane) {
        let f = format.flatMap { $0 == .json ? nil : $0 } ?? .txt
        Task {
            switch await ensureFormats(id, [f]) {
            case .failure(let e): show(Toast(pane: pane, text: Toast.styled("Couldn’t copy · \(e.message)"), failed: true))
            case .success(let files):
                guard let url = files[f], let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                show(Toast(pane: pane, text: Toast.styled(WordCount.copiedMessage(text))))
            }
        }
    }

    /// Show in Finder (⇧⌘R): the format's file in the library folder (made first if needed).
    func revealFormat(_ id: LibraryEntry.ID, _ f: OutputFormat, pane: Toast.Pane) {
        Task {
            switch await ensureFormats(id, [f]) {
            case .failure(let e): show(Toast(pane: pane, text: Toast.styled("Couldn’t make \(f.rawValue) · \(e.message)"), failed: true))
            case .success(let files): if let url = files[f] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    func openFormat(_ id: LibraryEntry.ID, _ f: OutputFormat, pane: Toast.Pane) {
        Task {
            if case .success(let files) = await ensureFormats(id, [f]), let url = files[f] { NSWorkspace.shared.open(url) }
        }
    }

    /// Make Again from Transcript: drops the cached file and makes it fresh.
    func makeAgain(_ id: LibraryEntry.ID, _ f: OutputFormat, pane: Toast.Pane) {
        guard f != .json, let entry = library[id] else { return }
        if let name = entry.formats[f.rawValue] {
            try? FileManager.default.removeItem(at: library.folderURL(entry).appendingPathComponent(name))
            try? library.forgetMissingFormats(id)
        }
        Task {
            switch await ensureFormats(id, [f]) {
            case .failure(let e): show(Toast(pane: pane, text: Toast.styled("Couldn’t make \(f.rawValue) · \(e.message)"), failed: true))
            case .success: show(Toast(pane: pane, text: Toast.styled("Made **\(ExportNaming.fileName(title: entry.title, format: f))** again")))
            }
        }
    }

    /// The file a drag out of a chip delivers: a scratch copy named `<title>.<ext>`, so the
    /// receiver can't move the library's own file away.
    func dragFile(_ id: LibraryEntry.ID, _ f: OutputFormat) async throws -> URL {
        guard let entry = library[id] else { throw ExportError(message: "This entry was removed.") }
        switch await ensureFormats(id, [f]) {
        case .failure(let e): throw e
        case .success(let files):
            guard let src = files[f] else { throw ExportError(message: "Couldn’t make \(f.rawValue).") }
            lastExportFormat = f
            return try Self.temporaryCopy(of: src, named: ExportNaming.fileName(title: entry.title, format: f))
        }
    }

    /// An item provider for dragging `f` to Finder or another app (file promise).
    func dragProvider(_ id: LibraryEntry.ID, _ f: OutputFormat) -> NSItemProvider {
        let provider = NSItemProvider()
        let title = library[id]?.title ?? "Transcript"
        provider.suggestedName = ExportNaming.fileName(title: title, format: f)
        let type = f.utType ?? .plainText
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor [weak self] in
                guard let self else { done(nil, false, nil); return }
                do { done(try await self.dragFile(id, f), false, nil) } catch { done(nil, false, error) }
            }
            return nil
        }
        return provider
    }

    // MARK: Copies

    /// After file_done: "Also save copies" next to the source or into the folder.
    func writeCopies(entry id: LibraryEntry.ID, options: TranscribeOptions, source: URL) {
        guard let plan = CopyPlan(options: options, source: source) else { return }
        Task {
            switch await exportCopies(id, plan.formats, timestamps: plan.timestamps) {
            case .failure(let e):
                show(Toast(pane: .sidebar, text: Toast.styled("Couldn’t save copies of **\(source.lastPathComponent)** · \(e.message)"), failed: true))
            case .success(let files):
                var failed: [String] = []
                for (f, url) in plan.destinations(source: source) {
                    guard let src = files[f] else { failed.append(url.lastPathComponent); continue }
                    do {
                        try FileManager.default.createDirectory(at: plan.directory, withIntermediateDirectories: true)
                        try Self.place(src, at: url, replace: plan.replace)
                    } catch {
                        failed.append(url.lastPathComponent)
                    }
                }
                if !failed.isEmpty {
                    show(Toast(pane: .sidebar, text: Toast.styled("Couldn’t save **\(failed.joined(separator: ", "))** · \(plan.directory.lastPathComponent) isn’t writable"),
                               failed: true))
                }
                for (f, url) in files where f != .json { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
        }
    }

    // MARK: Locate…

    func locateSource(_ id: LibraryEntry.ID) {
        guard let entry = library[id] else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Locate “\(entry.sourceName)”"
        panel.prompt = "Locate"
        let last = entry.sourceURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: last.path) { panel.directoryURL = last }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        locate(id, at: url)
    }

    /// Locate…'s second half: same fingerprint → relocate; otherwise ask (the mismatch alert).
    func locate(_ id: LibraryEntry.ID, at url: URL) {
        guard let entry = library[id] else { return }
        Task {
            let fp = await SourceFingerprint.compute(url)
            if let fp, fp == entry.fingerprint {
                relocate(id, to: url, fingerprint: nil)
            } else {
                locateMismatch = LocateMismatch(entry: id, url: url, fingerprint: fp)
            }
        }
    }

    func relocate(_ id: LibraryEntry.ID, to url: URL, fingerprint: SourceFingerprint?) {
        do {
            try library.relocate(id, to: url, fingerprint: fingerprint)
            show(Toast(pane: .inspector, text: Toast.styled("Found **\(url.lastPathComponent)**"), reveal: [url]))
        } catch {
            banner = .message("Couldn’t update the library: \(error.localizedDescription)")
        }
    }

    // MARK: Toasts

    func show(_ t: Toast) {
        withAnimation(.snappy(duration: 0.2)) { toast = t }
        let id = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.toast?.id == id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.toast = nil }
        }
    }
}

struct ExportError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

extension OutputFormat {
    var utType: UTType? {
        switch self {
        case .md: UTType(filenameExtension: "md") ?? .plainText
        case .txt: .plainText
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .plainText
        case .json: .json
        }
    }
}
