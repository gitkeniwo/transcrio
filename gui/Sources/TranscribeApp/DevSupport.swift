import AppKit
import TranscribeKit

/// Development hooks driven by environment variables (no effect when unset):
///
/// - `TRANSCRIBE_APPEARANCE=light|dark` forces an appearance.
/// - `TRANSCRIBE_ADD=/a.m4a|/b.mp4` adds files to the queue;
///   `TRANSCRIBE_AUTOSTART=1` then starts the batch, `TRANSCRIBE_SELECT=<n>` selects row n,
///   `TRANSCRIBE_STOP_AFTER=<s>` stops the current file after s seconds.
/// - `TRANSCRIBE_FILE_OPTIONS="0:model=fast;formats=;copies=nextToSource;copyformats=srt+md;replace=1"`
///   edits rows' options (`formats=` empty: transcript only).
/// - `TRANSCRIBE_QUIT_AFTER=<s>` quits after s seconds and confirms the quit dialog.
/// - `TRANSCRIBE_WINDOW_SIZE=<w>x<h>` sets the main window's content size (narrow-width checks).
/// - `TRANSCRIBE_OPEN_SETTINGS=1` opens Settings; snapshots capture the key window.
///   `TRANSCRIBE_SETTINGS_TAB=general|library|appearance|models` picks the tab it opens on.
/// - `TRANSCRIBE_APP_ICON=<id>|default` shows that Dock icon without storing it;
///   `TRANSCRIBE_PICK_APP_ICON=<s>:<id>` picks one as a Settings click would (stored);
///   `TRANSCRIBE_DOCK_ICON_SNAPSHOT=/path.png` saves NSApp.applicationIconImage after 1 s.
/// - `TRANSCRIBE_WHEEL=/path/transcribe-X.Y.Z-py3-none-any.whl` stands in for the wheel release
///   builds bundle: Install / Update Command-Line Tool install it. Set `UV_TOOL_DIR` and
///   `UV_TOOL_BIN_DIR` too to install into a scratch directory (the locator follows `UV_TOOL_BIN_DIR`).
///   `TRANSCRIBE_INSTALL_CLI_AFTER=<s>` clicks the banner's Install / Update button after s seconds.
/// - Library: `TRANSCRIBE_LIBRARY=/dir` uses that library folder (nothing is stored);
///   `TRANSCRIBE_LIBRARY_SEED=demo|/a.m4a|…` fills an empty library with demo entries (their
///   sources missing) plus one entry per given file (real fingerprints, so dropping it again
///   is a known file; `/a.m4a#unaligned` seeds it without cues, for Align Subtitles). `TRANSCRIBE_HISTORY_SELECT=<n>` selects History row n;
///   `TRANSCRIBE_HISTORY_COLLAPSED=1|0`; `TRANSCRIBE_SEARCH=<text>` (`TRANSCRIBE_SEARCH_SCOPE=text`
///   searches transcript text, P3);
///   `TRANSCRIBE_DROP_LATER="<s>:/a|/b"` drops files after s seconds (fingerprinted like a drop);
///   `TRANSCRIBE_AGAIN_SHEET="<s>:<n>"` opens Transcribe Again… for History row n;
///   `TRANSCRIBE_AGAIN="<s>:<n>"` queues row n again with its options and starts it;
///   `TRANSCRIBE_REMOVE_ENTRY="<s>:<n>"` asks to remove History row n, confirming 1 s later
///   (`TRANSCRIBE_REMOVE_ENTRY_ASK_ONLY=1` leaves the confirmation up).
///   Export (P2): `TRANSCRIBE_EXPORT="<s>:<n>:md+srt"` saves row n's formats to Downloads
///   (`TRANSCRIBE_DOWNLOADS=/dir` stands in for ~/Downloads); `TRANSCRIBE_COPY_TEXT="<s>:<n>"`;
///   `TRANSCRIBE_DRAG_TEST="<s>:<n>:<fmt>:/out.log"` loads row n's drag provider like a drop
///   target would and logs the delivered file and its size; `TRANSCRIBE_TOAST="<s>:<pane>:<text>"`;
///   `TRANSCRIBE_LOCATE="<s>:<n>:/file"` runs Locate… for row n with that file (no panel);
///   `TRANSCRIBE_PREVIEW_FORMAT=md|txt|srt|vtt|json` is the entry preview's first format.
///   `TRANSCRIBE_HISTORY_HOVER=<n>` shows row n hovered; `TRANSCRIBE_HISTORY_SWIPE=<n>:<points>`
///   shows it swiped (positive: Save, negative: Again… / Remove; past the tiles + 60: full).
///   P3: `TRANSCRIBE_ALWAYS_ALIGN=0|1` overrides Settings → Library → Always align subtitles
///   (not stored); `TRANSCRIBE_ALIGN="<s>:<n>"` runs Align Subtitles for row n (fake-serve's align op
///   takes FAKE_SERVE_ALIGN_SEC).
/// - `TRANSCRIBE_SNAPSHOTS="3:/a.png,8:/b.png"` takes several snapshots, then quits.
/// - `TRANSCRIBE_SNAPSHOT=/path/out.png` renders the main window into a PNG after
///   `TRANSCRIBE_SNAPSHOT_DELAY` seconds (default 2), then quits. This captures the app's
///   own window in-process, so it needs no Screen Recording permission.
@MainActor
enum DevSupport {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let openSettingsNotification = Notification.Name("TranscribeOpenSettings")
    nonisolated static let openModelsNotification = Notification.Name("TranscribeOpenModels")

    static func applyLaunchOptions(model: AppModel) {
        if let id = environment["TRANSCRIBE_APP_ICON"] { AppIcon.apply(AppIconCatalog.resolve(id)) }
        if let spec = environment["TRANSCRIBE_PICK_APP_ICON"]?.split(separator: ":"), spec.count == 2,
           let t = Double(spec[0]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { AppIcon.choose(spec[1] == "default" ? "" : String(spec[1])) }
        }
        if let path = environment["TRANSCRIBE_DOCK_ICON_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let tiff = NSApp.applicationIconImage?.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
        switch environment["TRANSCRIBE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let spec = environment["TRANSCRIBE_WINDOW_SIZE"]?.split(separator: "x"), spec.count == 2,
           let w = Double(spec[0]), let h = Double(spec[1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
                window.setContentSize(NSSize(width: w, height: h))
            }
        }
        // Paths in TRANSCRIBE_ADD (separated by "|"); argv paths would be treated as documents to open.
        let files = (environment["TRANSCRIBE_ADD"] ?? "").split(separator: "|").map(String.init)
            .filter { FileManager.default.fileExists(atPath: $0) }
        if !files.isEmpty { model.addNow(files.map { URL(fileURLWithPath: $0) }) }
        if let n = Int(environment["TRANSCRIBE_SELECT"] ?? ""), model.items.indices.contains(n) {
            model.selection = [model.items[n].id]
        } else if environment["TRANSCRIBE_SELECT"] == "none" {
            model.selection = []
        }
        // TRANSCRIBE_FILE_OPTIONS="1:model=fast;formats=srt+md|2:language=zh" edits rows' options.
        for spec in (environment["TRANSCRIBE_FILE_OPTIONS"] ?? "").split(separator: "|") {
            let bits = spec.split(separator: ":", maxSplits: 1)
            guard bits.count == 2, let row = Int(bits[0]), model.items.indices.contains(row) else { continue }
            let id = model.items[row].id
            let saved = model.selection
            model.selection = [id]
            model.editOptions { o in
                for pair in bits[1].split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "model": o.model = ModelChoice(rawValue: kv[1] == "fast" ? "0.6b" : kv[1] == "accurate" ? "1.7b" : kv[1]) ?? o.model
                    case "formats": o.formats = kv[1].split(separator: "+").compactMap { OutputFormat(rawValue: String($0)) }
                    case "language": o.language = kv[1]
                    case "timestamps": o.timestamps = kv[1] == "1"
                    case "copies": o.copyMode = CopyMode(rawValue: kv[1]) ?? o.copyMode
                    case "copyformats": o.copyFormats = kv[1].split(separator: "+").compactMap { OutputFormat(rawValue: String($0)) }
                    case "replace": o.overwrite = kv[1] == "1"
                    default: break
                    }
                }
            }
            model.selection = saved
        }
        // TRANSCRIBE_START="<s>:0+2" starts those rows (in that order) after s seconds.
        if let spec = environment["TRANSCRIBE_START"]?.split(separator: ":"), spec.count == 2, let t = Double(spec[0]) {
            let rows = spec[1].split(separator: "+").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                model.start(rows.filter(model.items.indices.contains).map { model.items[$0].id })
            }
        }
        // TRANSCRIBE_ADD_LATER="<s>:/path" adds a file during a run and queues it.
        if let spec = environment["TRANSCRIBE_ADD_LATER"]?.split(separator: ":", maxSplits: 1), spec.count == 2,
           let t = Double(spec[0]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let before = Set(model.items.map(\.id))
                model.addNow([URL(fileURLWithPath: String(spec[1]))])
                model.start(model.items.map(\.id).filter { !before.contains($0) })
            }
        }
        // TRANSCRIBE_MOVE="<s>:<row>:<index>" drags that row to position index in Up next.
        if let spec = environment["TRANSCRIBE_MOVE"]?.split(separator: ":"), spec.count == 3,
           let t = Double(spec[0]), let row = Int(spec[1]), let index = Int(spec[2]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                if model.items.indices.contains(row) { model.drop([model.items[row].id], into: .upNext, at: index) }
            }
        }
        // TRANSCRIBE_RUN_AGAIN="<s>:<row>" presses Run Again with Changes… on that row, then starts the copy.
        if let spec = environment["TRANSCRIBE_RUN_AGAIN"]?.split(separator: ":"), spec.count == 2,
           let t = Double(spec[0]), let row = Int(spec[1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                guard model.items.indices.contains(row) else { return }
                model.runAgainWithChanges(model.items[row].id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.startSelected() }
            }
        }
        applyLibraryOptions(model: model)
        // TRANSCRIBE_STATE_LOG=/path appends every row's status once a second (end-to-end checks).
        if let path = environment["TRANSCRIBE_STATE_LOG"] {
            let start = Date()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let rows = model.queue.displayOrder.compactMap { model.queue[$0] }
                        .map { "\($0.name)=\(String(describing: model.status(of: $0)).prefix(60))" }
                    let history: String = model.historyEntries.map(\.title).joined(separator: ",")
                    let notice: String = model.dropNotice.map { " notice=\($0.title)" } ?? ""
                    let line = String(format: "%5.1f ", Date().timeIntervalSince(start)) + "worker=\(model.workerState) "
                        + rows.joined(separator: " | ") + " || history=" + history + notice + "\n"
                    if let h = FileHandle(forWritingAtPath: path) {
                        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
                    } else {
                        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
                    }
                }
            }
        }
        if environment["TRANSCRIBE_AUTOSTART"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { model.startAllReady() }
        }
        if let s = Double(environment["TRANSCRIBE_STOP_AFTER"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { model.stopCurrent() }
        }
        // TRANSCRIBE_RETRY_AFTER="<seconds>:<row>" presses Retry on that row.
        if let spec = environment["TRANSCRIBE_RETRY_AFTER"]?.split(separator: ":"), spec.count == 2,
           let t = Double(spec[0]), let row = Int(spec[1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                if model.items.indices.contains(row) { model.retry(model.items[row].id) }
            }
        }
        // TRANSCRIBE_QUIT_AFTER=<s> asks to quit, then confirms the dialog a second later.
        if let s = Double(environment["TRANSCRIBE_QUIT_AFTER"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if model.showQuitConfirmation { model.confirmQuit(true) }
                }
            }
        }
        // TRANSCRIBE_OPEN_SETTINGS=1 opens the Settings window (snapshots then capture it).
        if environment["TRANSCRIBE_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: openSettingsNotification, object: nil)
            }
        }
        // TRANSCRIBE_OPEN_MODELS=1 opens the Models window; TRANSCRIBE_DOWNLOAD="<s>:<id>" then
        // starts that download, TRANSCRIBE_CANCEL_DOWNLOAD="<s>:<id>" cancels it.
        if environment["TRANSCRIBE_OPEN_MODELS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: openModelsNotification, object: nil)
            }
        }
        // TRANSCRIBE_MODELS_SELECT=<id> picks the card the Models window opens on.
        // Each takes a comma-separated list of "<s>:<id>". TRANSCRIBE_REMOVE asks to remove (the
        // confirmation shows); TRANSCRIBE_CONFIRM_REMOVE=<s> confirms it; TRANSCRIBE_PRELOAD loads.
        let modelActions: [(String, (String) -> Void)] = [
            ("TRANSCRIBE_DOWNLOAD", model.download), ("TRANSCRIBE_CANCEL_DOWNLOAD", model.cancelDownload),
            ("TRANSCRIBE_REMOVE", model.requestRemove), ("TRANSCRIBE_PRELOAD", model.preload),
        ]
        for (key, act) in modelActions {
            for part in (environment[key] ?? "").split(separator: ",") {
                let spec = part.split(separator: ":")
                guard spec.count == 2, let t = Double(spec[0]) else { continue }
                let id = String(spec[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { act(id) }
            }
        }
        if let t = Double(environment["TRANSCRIBE_CONFIRM_REMOVE"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { model.confirmRemove() }
        }
        if let spec = environment["TRANSCRIBE_SELECT_MANY"] {
            let rows = spec.split(separator: ",").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                model.selection = Set(rows.filter(model.items.indices.contains).map { model.items[$0].id })
            }
        }
        if environment["TRANSCRIBE_SELECT_MODE"] == "1" { model.selectMode = true }
        if let t = Double(environment["TRANSCRIBE_INSTALL_CLI_AFTER"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { model.installCLI() }
        }
        if let list = environment["TRANSCRIBE_SNAPSHOTS"] {
            let shots = list.split(separator: ",").compactMap { part -> (Double, String)? in
                let bits = part.split(separator: ":", maxSplits: 1)
                guard bits.count == 2, let t = Double(bits[0]) else { return nil }
                return (t, String(bits[1]))
            }
            for (t, path) in shots {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { snapshot(to: URL(fileURLWithPath: path)) }
            }
            // TRANSCRIBE_SNAPSHOTS_KEEP_RUNNING=1 leaves quitting to TRANSCRIBE_QUIT_AFTER.
            if let last = shots.map(\.0).max(), environment["TRANSCRIBE_SNAPSHOTS_KEEP_RUNNING"] != "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + last + 0.3) { model.killWorkerIfRunning(); exit(0) }
            }
        }
        if let path = environment["TRANSCRIBE_SNAPSHOT"] {
            let delay = Double(environment["TRANSCRIBE_SNAPSHOT_DELAY"] ?? "") ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapshot(to: URL(fileURLWithPath: path))
                model.killWorkerIfRunning()
                exit(0)
            }
        }
    }

    private static func after(_ key: String, _ body: @escaping @MainActor (String) -> Void) {
        guard let spec = environment[key]?.split(separator: ":", maxSplits: 1), spec.count == 2, let t = Double(spec[0]) else { return }
        let arg = String(spec[1])
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { body(arg) }
    }

    static let previewFormat = environment["TRANSCRIBE_PREVIEW_FORMAT"].flatMap(OutputFormat.init(rawValue:))

    static func applyLibraryOptions(model: AppModel) {
        switch environment["TRANSCRIBE_HISTORY_COLLAPSED"] {
        case "1": model.historyCollapsed = true
        case "0": model.historyCollapsed = false
        default: break
        }
        if environment["TRANSCRIBE_SEARCH_SCOPE"] == "text" { model.searchScope = .text }
        if let q = environment["TRANSCRIBE_SEARCH"] { model.searchText = q }
        func entry(_ n: String) -> LibraryEntry.ID? {
            guard let i = Int(n), model.historyEntries.indices.contains(i) else { return nil }
            return model.historyEntries[i].id
        }
        if let n = environment["TRANSCRIBE_HISTORY_SELECT"] {
            // Text scope reads the transcripts first.
            DispatchQueue.main.asyncAfter(deadline: .now() + (model.searchingText ? 1.5 : 0.1)) {
                if let id = entry(n) { model.historySelection = [id] }
            }
        }
        after("TRANSCRIBE_DROP_LATER") { paths in
            model.add(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
        }
        after("TRANSCRIBE_AGAIN_SHEET") { n in entry(n).map { model.requestAgain([$0]) } }
        after("TRANSCRIBE_AGAIN") { n in
            guard let id = entry(n), let e = model.library[id] else { return }
            model.transcribeAgain([id], model: ModelChoice(rawValue: e.options.model) == .accurate ? .fast : .accurate,
                                  language: e.options.language, context: e.options.context)
            model.startSelected()
        }
        after("TRANSCRIBE_EXPORT") { spec in
            let bits = spec.split(separator: ":")
            guard bits.count == 2, let id = entry(String(bits[0])) else { return }
            let formats = bits[1].split(separator: "+").compactMap { OutputFormat(rawValue: String($0)) }
            model.saveToDownloads([id], formats: formats, pane: .inspector)
        }
        after("TRANSCRIBE_COPY_TEXT") { n in entry(n).map { model.copyText($0, pane: .inspector) } }
        after("TRANSCRIBE_TOAST") { spec in
            let bits = spec.split(separator: ":", maxSplits: 1)
            guard bits.count == 2 else { return }
            let pane: Toast.Pane = bits[0] == "sidebar" ? .sidebar : bits[0] == "center" ? .center : .inspector
            model.show(Toast(pane: pane, text: Toast.styled(String(bits[1]))))
        }
        after("TRANSCRIBE_ALIGN") { n in entry(n).map { model.alignSubtitles($0) } }
        after("TRANSCRIBE_LOCATE") { spec in
            let bits = spec.split(separator: ":", maxSplits: 1)
            guard bits.count == 2, let id = entry(String(bits[0])) else { return }
            model.locate(id, at: URL(fileURLWithPath: String(bits[1])))
        }
        after("TRANSCRIBE_DRAG_TEST") { spec in
            let bits = spec.split(separator: ":", maxSplits: 2).map(String.init)
            guard bits.count == 3, let id = entry(bits[0]), let f = OutputFormat(rawValue: bits[1]) else { return }
            let log = URL(fileURLWithPath: bits[2])
            let provider = model.dragProvider(id, f)
            let types = provider.registeredTypeIdentifiers
            _ = provider.loadFileRepresentation(forTypeIdentifier: types.first ?? "public.data") { url, error in
                var line = "types=\(types.joined(separator: ","))"
                if let url {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                    let head = (try? String(contentsOf: url, encoding: .utf8).prefix(80)) ?? ""
                    line += " name=\(url.lastPathComponent) size=\(size) head=\(head.replacingOccurrences(of: "\n", with: "⏎"))"
                } else {
                    line += " error=\(error?.localizedDescription ?? "none")"
                }
                try? (line + "\n").write(to: log, atomically: true, encoding: .utf8)
            }
        }
        after("TRANSCRIBE_REMOVE_ENTRY") { n in
            guard let id = entry(n) else { return }
            model.removeRequest = [id]
            if environment["TRANSCRIBE_REMOVE_ENTRY_ASK_ONLY"] != "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.confirmRemoveEntries() }
            }
        }
    }

    /// `TRANSCRIBE_LIBRARY_SEED`: demo entries for snapshots, written only into an empty library.
    nonisolated static func seedLibraryIfAsked(at root: URL) {
        guard let spec = environment["TRANSCRIBE_LIBRARY_SEED"], !spec.isEmpty,
              !FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryStore.indexName).path),
              var store = try? LibraryStore(root: root) else { return }
        let now = Date()
        let day = 86400.0
        let sentences = [
            "Welcome back to the show. Today we are talking about how small teams ship software without losing their weekends.",
            "Our guest has spent ten years building developer tools, and she has strong opinions about release trains.",
            "The first thing we changed was the review process: every change gets one reviewer, and that reviewer owns the merge.",
            "That sounds slower, but in practice it removed the waiting, because nobody waited for a second or third approval.",
            "Then we looked at the build. Twenty minutes is too long to keep the context in your head, so we split it.",
            "The unit tests now run in under two minutes, and the slow integration suite runs only on the main branch.",
            "People worried that bugs would slip through. Some did, but they were caught within the hour and fixed the same day.",
            "The bigger win was morale. When shipping is boring, people stop being afraid of it.",
        ]
        struct Demo { var title: String; var ext: String; var age: Double; var duration: Double; var lang: String; var model: String; var formats: [String]; var timing: String? }
        var demos: [Demo] = []
        var real: [(url: URL, aligned: Bool)] = []
        for part in spec.split(separator: "|").map(String.init) {
            if part == "demo" {
                demos += [
                    Demo(title: "podcast-ep12", ext: "mp3", age: 2 * day, duration: 2642, lang: "Chinese", model: "1.7b", formats: ["md", "srt"], timing: "aligned"),
                    Demo(title: "Weekly sync 2026-10-14", ext: "m4a", age: 6 * day, duration: 1810, lang: "English", model: "0.6b", formats: ["md"], timing: nil),
                    Demo(title: "Lecture 03 — Signals and Systems", ext: "mp4", age: 30 * day, duration: 4980, lang: "English", model: "1.7b", formats: ["md", "txt", "vtt"], timing: "estimated"),
                    Demo(title: "voice memo 118", ext: "m4a", age: 400 * day, duration: 95, lang: "Japanese", model: "1.7b", formats: ["txt"], timing: nil),
                ]
            } else {
                let unaligned = part.hasSuffix("#unaligned")
                let path = unaligned ? String(part.dropLast("#unaligned".count)) : part
                if FileManager.default.fileExists(atPath: path) { real.append((URL(fileURLWithPath: path), !unaligned)) }
            }
        }
        func write(title: String, source: URL, fp: SourceFingerprint?, kind: MediaKind, date: Date, duration: Double,
                   lang: String, model: String, formats: [String], timing: String?) {
            guard let staging = try? store.makeStaging() else { return }
            let per = duration / Double(sentences.count)
            let segs = sentences.enumerated().map { i, t in TranscriptSegment(start: Double(i) * per, end: Double(i + 1) * per, text: t) }
            var outputs: [String: String] = [:]
            for f in formats {
                let u = staging.appendingPathComponent("\(title).\(f)")
                try? sentences.joined(separator: "\n\n").write(to: u, atomically: true, encoding: .utf8)
                outputs[f] = u.path
            }
            let repo = model == "0.6b" ? "Qwen/Qwen3-ASR-0.6B" : "Qwen/Qwen3-ASR-1.7B"
            let notices = timing == "estimated"
                ? [Notice(code: .timingEstimated, message: "Subtitle timing is estimated: this file wasn’t aligned.")] : []
            let result = FileResult(outputs: outputs, elapsed: duration / 9, language: lang, duration: duration, model: repo,
                                    cueTiming: timing.flatMap(CueTiming.init(rawValue:)), notices: notices, segments: segs)
            let overview: [Float] = (0..<LibraryOverview.bins).map { i in
                let x = Double(i)
                let v: Double = 0.15 + 0.1 * sin(x / 3) + 0.08 * sin(x / 11)
                return Float(v)
            }
            _ = try? store.commit(.init(staging: staging, source: source, kind: kind, fingerprint: fp,
                                        options: EntryOptions(model: model, language: nil), result: result,
                                        overview: overview, date: date))
        }
        for d in demos {
            write(title: d.title, source: URL(fileURLWithPath: "/Users/Shared/Missing/\(d.title).\(d.ext)"), fp: nil,
                  kind: MediaKind(pathExtension: d.ext), date: now.addingTimeInterval(-d.age), duration: d.duration,
                  lang: d.lang, model: d.model, formats: d.formats, timing: d.timing)
        }
        for (i, (url, aligned)) in real.enumerated() {
            write(title: url.deletingPathExtension().lastPathComponent, source: url, fp: try? SourceFingerprint.read(url),
                  kind: MediaKind(pathExtension: url.pathExtension), date: now.addingTimeInterval(-Double(i + 1) * 3600),
                  duration: 40, lang: "English", model: "1.7b", formats: aligned ? ["md", "srt"] : ["md"], timing: aligned ? "aligned" : nil)
        }
    }

    static func snapshot(to url: URL) {
        let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        let settings = environment["TRANSCRIBE_OPEN_SETTINGS"] == "1"
            ? visible.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true || $0.title.contains("Settings") }
            : nil
        let models = environment["TRANSCRIBE_OPEN_MODELS"] == "1" ? visible.first { $0.title == "Models" } : nil
        guard let window = settings ?? models ?? visible.first,
              let view = window.contentView?.superview ?? window.contentView
        else { return }
        render(view, to: url)
        // An alert or sheet is its own window: save it next to the shot as "<name>-sheet.png".
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView {
            render(sheetView, to: url.deletingPathExtension().appendingPathExtension("sheet.png"))
        }
    }

    private static func render(_ view: NSView, to url: URL) {
        view.appearance = NSApp.appearance ?? view.effectiveAppearance
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
