// Menu bar companion for the Sift core.
// Reads status.json / config.json from the support directory and sends commands
// by editing config.json. It also runs the core every minute (see Core): as a child of
// the app, macOS asks "Sift" for folder access, so vaults in Documents/iCloud work.
// Apart from creating an inbox file the user asked for, it never writes to the vault.

import AppKit
import Carbon.HIToolbox
import Combine
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Sift")
let statusURL = supportDir.appendingPathComponent("status.json")
let configURL = supportDir.appendingPathComponent("config.json")
let runNowURL = supportDir.appendingPathComponent("run-now")
let quickDir = supportDir.appendingPathComponent("quick")  // core appends these to the inbox
let draftURL = supportDir.appendingPathComponent("quick-draft.json")
let coreDir = supportDir.appendingPathComponent("app")
let coreLog = supportDir.appendingPathComponent("logs/core.log")

/// UI language, shared with core through config.json `language` ("en" or "ko").
enum Language: String, CaseIterable {
    case en, ko
    var name: String { self == .ko ? "한국어" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
}

final class Lang: ObservableObject {
    static let shared = Lang()
    @Published var current: Language = .en
}

/// The string for the current language.
func L(_ en: String, _ ko: String) -> String { Lang.shared.current == .ko ? ko : en }

/// Runs `python3 -m pa run --scheduled` every minute; core decides whether the check is due.
/// A launchd job can't get folder permission (no prompt for a background python), a child of the app can.
final class Core {
    static let shared = Core()
    private var running: Process?
    private var again = false
    private var timer: Timer?
    private var held = false  // an update is swapping the core

    /// Stops new runs and waits for the current one (it may be mid-analysis) to finish.
    func hold() async {
        held = true
        while running?.isRunning == true { try? await Task.sleep(nanoseconds: 500_000_000) }
    }

    func release() {
        held = false
        tick()
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    private(set) var hasTools = Setup.hasTools

    func tick() {
        if held { return }
        if !hasTools {
            hasTools = Setup.hasTools
            if !hasTools { return }
        }
        if let running, running.isRunning { again = true; return }  // run once more when it ends
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-m", "pa", "run", "--scheduled"]
        task.currentDirectoryURL = coreDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = "ko_KR.UTF-8"
        task.environment = env
        try? FileManager.default.createDirectory(at: coreLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: coreLog.path) {
            FileManager.default.createFile(atPath: coreLog.path, contents: nil)
        }
        if let log = try? FileHandle(forWritingTo: coreLog) {
            log.seekToEndOfFile()
            task.standardOutput = log
            task.standardError = log
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                if self.again { self.again = false; self.tick() }
            }
        }
        do { try task.run(); running = task } catch { NSLog("Sift core: \(error)") }
    }
}

// MARK: - first run

/// Lets a bare Sift.app work without install.sh: moves itself into ~/Applications,
/// installs the core bundled in Contents/Resources/core, and starts at login (launchd).
enum Setup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let installedApp = home.appendingPathComponent("Applications/Sift.app")
    static let agentPlist = home.appendingPathComponent("Library/LaunchAgents/\(appLabel).plist")
    static let bundledCore = Bundle.main.resourceURL?.appendingPathComponent("core")

    static var inApplications: Bool { Bundle.main.bundlePath.hasSuffix("/Applications/Sift.app") }
    static var underLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == appLabel }

    static func run() {
        chooseLanguage()
        moveToApplications()
        installCore()
        startAtLogin()
        removeOldCoreJob()
    }

    /// No config yet: a first install asks for the language (English by default).
    /// A config without `language` predates the choice, when the app was Korean only, so it stays Korean.
    private static func chooseLanguage() {
        var cfg = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let raw = cfg?["language"] as? String {
            Lang.shared.current = Language(rawValue: raw) ?? .en
            return
        }
        let choice: Language
        if cfg == nil {
            let alert = NSAlert()
            alert.messageText = "Choose a language · 언어 선택"
            alert.informativeText = "You can change it later in Settings.\n나중에 설정에서 바꿀 수 있어요."
            alert.addButton(withTitle: Language.en.name)
            alert.addButton(withTitle: Language.ko.name)
            NSApp.activate(ignoringOtherApps: true)
            choice = alert.runModal() == .alertSecondButtonReturn ? .ko : .en
        } else {
            choice = .ko
        }
        Lang.shared.current = choice
        var updated = cfg ?? [:]
        updated["language"] = choice.rawValue
        cfg = updated
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    /// Opened from Downloads or a disk image: offer to copy itself where updates can replace it.
    private static func moveToApplications() {
        guard !inApplications else { return }
        let alert = NSAlert()
        alert.messageText = L("Move Sift to the Applications folder?", "Sift를 응용 프로그램 폴더로 옮길까요?")
        alert.informativeText = L("Sift copies itself to ~/Applications/Sift.app and relaunches from there. Starting at login and in-app updates only work from that location.",
                                  "~/Applications/Sift.app으로 복사하고 거기서 다시 실행해요. 로그인할 때 자동 실행과 앱 안 업데이트는 이 위치에서만 돼요.")
        alert.addButton(withTitle: L("Move", "옮기기"))
        alert.addButton(withTitle: L("Run from here", "그대로 실행"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: installedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = installedApp.deletingLastPathComponent().appendingPathComponent(".Sift-new.app")
            try? fm.removeItem(at: staged)
            try tool("/usr/bin/ditto", [Bundle.main.bundlePath, staged.path])
            // unsigned build: the user chose to run it, so drop the download mark on the copy
            _ = try? tool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
            if fm.fileExists(atPath: installedApp.path) {
                _ = try fm.replaceItemAt(installedApp, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: installedApp)
            }
        } catch {
            let fail = NSAlert()
            fail.messageText = L("Couldn't move Sift", "옮기지 못했어요")
            fail.informativeText = error.localizedDescription
            fail.runModal()
            return
        }
        if fm.fileExists(atPath: agentPlist.path) {
            // the login copy is running (older version): restart it from the new app
            _ = try? tool("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(appLabel)"])
        } else {
            _ = try? tool("/usr/bin/open", ["-n", installedApp.path])
        }
        exit(0)
    }

    /// Copies the bundled core when none is installed or the bundled one is newer
    /// (an in-app core update can be ahead of the app; that one is kept).
    private static func installCore() {
        guard let bundledCore,
              let bundled = try? String(contentsOf: bundledCore.appendingPathComponent("VERSION"), encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        let fm = FileManager.default
        let current = coreDir.appendingPathComponent("pa")
        let installed = fm.fileExists(atPath: current.path) ? Updater.installedVersion : ""
        guard installed.isEmpty || bundled.compare(installed, options: .numeric) == .orderedDescending else { return }
        do {
            try fm.createDirectory(at: coreDir, withIntermediateDirectories: true)
            let staged = coreDir.appendingPathComponent("pa.new")
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: bundledCore.appendingPathComponent("pa"), to: staged)
            if fm.fileExists(atPath: current.path) {
                _ = try fm.replaceItemAt(current, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: current)
            }
            try Data((bundled + "\n").utf8).write(to: installedVersionURL, options: .atomic)
        } catch {
            NSLog("Sift: core install failed: \(error)")
        }
    }

    /// A launchd job (same as install.sh writes) starts the app at login and restarts it after an update.
    private static func startAtLogin() {
        guard inApplications else { return }
        let exe = Bundle.main.executablePath ?? ""
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>\(appLabel)</string>
              <key>ProgramArguments</key>
              <array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
              <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>

            """
        if (try? String(contentsOf: agentPlist, encoding: .utf8)) == plist { return }
        try? FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? Data(plist.utf8).write(to: agentPlist, options: .atomic)) != nil else { return }
        if underLaunchd { return }  // already the login copy; the new plist applies next login
        // hand over to launchd: it starts a copy of this app, and this one quits
        let domain = "gui/\(getuid())"
        _ = try? tool("/bin/launchctl", ["bootout", "\(domain)/\(appLabel)"])
        if (try? tool("/bin/launchctl", ["bootstrap", domain, agentPlist.path])) != nil { exit(0) }
    }

    /// 0.2.0 ran the core as its own launchd job; the app runs it now.
    private static func removeOldCoreJob() {
        let old = "io.github.kpiljoong.sift.core"
        let path = home.appendingPathComponent("Library/LaunchAgents/\(old).plist")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        _ = try? tool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(old)"])
        try? FileManager.default.removeItem(at: path)
    }

    /// Command Line Tools provide /usr/bin/python3. Without them the python3 stub pops up an
    /// install dialog on every run, so core stays off until they are there.
    static var hasTools: Bool {
        (try? tool("/usr/bin/xcode-select", ["-p"])) != nil
    }

    @discardableResult
    static func tool(_ path: String, _ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateError("\(path) \(task.terminationStatus)") }
        return 0
    }
}

// MARK: - updates

/// Ed25519 key that signs update manifests (private half: SIFT_UPDATE_KEY in CI).
/// scripts/update-sign.swift refuses to sign with a key that doesn't pair with it.
let updatePublicKey = "luNon+8Dy7pBK04+7bP6D4BLEdrCt2//7AeEDsKNY+g="
let defaultUpdateFeed = "https://github.com/kpiljoong/sift/releases/latest/download"
let releasesPage = URL(string: "https://github.com/kpiljoong/sift/releases/latest")!
let installedVersionURL = coreDir.appendingPathComponent("VERSION")
let appLabel = "io.github.kpiljoong.sift.menubar"

struct UpdateManifest: Decodable {
    struct Part: Decodable {
        let file: String
        let size: Int
        let sha256: String
        let source: String?  // app only: hash of the app's source; differs = the app itself changed
    }
    let version: String
    let core: Part
    let app: Part
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// In-app updates from GitHub Releases, like Margin's: a signed manifest names the core and app
/// packages. Only the core (Python) changes → swap it in place, no restart and no new folder-permission
/// prompt. The app changed too → replace Sift.app and relaunch.
/// Nothing is contacted unless the user presses Check or turns on the daily check.
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate, installing(String), done(String)
        case available(String, app: Bool)
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var auto = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "autoUpdateCheck"); if auto { Task { await self.checkIfDue() } } }
    }
    var onOffer: ((String) -> Void)?
    private var offer: (manifest: UpdateManifest, feed: URL)?
    private var timer: Timer?

    static var bundleVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var appSource: String { Bundle.main.infoDictionary?["SiftSource"] as? String ?? "" }
    /// Core and app are versioned together; a core-only update moves this ahead of the app's own version.
    static var installedVersion: String {
        let text = (try? String(contentsOf: installedVersionURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? bundleVersion : text
    }

    /// Why this copy can't update itself (a dev build, or core not installed), or nil.
    var unsupported: String? {
        if !Setup.inApplications {
            return L("Only Sift.app in the Applications folder can update itself", "응용 프로그램 폴더의 Sift.app에서만 업데이트할 수 있어요")
        }
        if !FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) {
            let folder = Bundle.main.bundleURL.deletingLastPathComponent().path
            return L("No permission to write to \(folder)", "\(folder)에 쓸 권한이 없어요")
        }
        if !FileManager.default.fileExists(atPath: coreDir.appendingPathComponent("pa").path) {
            return L("The core isn't installed", "core가 설치되어 있지 않아요")
        }
        return nil
    }

    func start() {
        // wake hourly; the check itself runs at most once a day and only when turned on
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { await self?.checkIfDue() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await checkIfDue()
        }
    }

    @MainActor
    private func checkIfDue() async {
        guard auto, unsupported == nil else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 23 * 3600 else { return }
        await check(quiet: true)
    }

    /// The feed can point at a local test server: `defaults write io.github.kpiljoong.sift updateFeed http://127.0.0.1:PORT`
    private func feed() throws -> URL {
        let raw = UserDefaults.standard.string(forKey: "updateFeed") ?? defaultUpdateFeed
        guard let url = URL(string: raw.hasSuffix("/") ? raw : raw + "/"),
              url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1")
        else { throw UpdateError(L("The update address isn't https: \(raw)", "업데이트 주소가 https가 아니에요: \(raw)")) }
        return url
    }

    private func fetch(_ name: String, from feed: URL, max: Int) async throws -> Data {
        var request = URLRequest(url: feed.appendingPathComponent(name))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw UpdateError(L("No update has been published yet (\(name))", "아직 업데이트가 게시되지 않았어요 (\(name))")) }
        guard code == 200 else { throw UpdateError(L("Couldn't download \(name) (HTTP \(code))", "\(name) 다운로드 실패 (HTTP \(code))")) }
        guard data.count <= max else { throw UpdateError(L("\(name) is too large", "\(name)이 너무 커요")) }
        return data
    }

    @MainActor
    func check(quiet: Bool = false) async {
        if let reason = unsupported { status = .failed(reason); return }
        if case .checking = status { return }
        if case .installing = status { return }
        status = .checking
        do {
            let feed = try feed()
            let manifestData = try await fetch("sift-update.json", from: feed, max: 64 * 1024)
            let sigText = String(decoding: try await fetch("sift-update.sig", from: feed, max: 1024), as: UTF8.self)
            guard let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: updatePublicKey)!),
                  key.isValidSignature(sig, for: manifestData)
            else { throw UpdateError(L("The update's signature doesn't match. Nothing was installed", "업데이트 서명이 맞지 않아요. 설치하지 않았어요")) }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            if manifest.version.compare(Updater.installedVersion, options: .numeric) != .orderedDescending {
                offer = nil
                status = .upToDate
                return
            }
            offer = (manifest, feed)
            let app = manifest.app.source != Updater.appSource
            status = .available(manifest.version, app: app)
            if quiet, UserDefaults.standard.string(forKey: "offeredVersion") != manifest.version {
                UserDefaults.standard.set(manifest.version, forKey: "offeredVersion")
                onOffer?(manifest.version)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    @MainActor
    func install() async {
        guard let (manifest, feed) = offer, case .available(let version, let appChanged) = status else { return }
        let fm = FileManager.default
        let work = supportDir.appendingPathComponent("update")
        do {
            status = .installing(L("Downloading…", "내려받는 중…"))
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            let core = try await download(manifest.core, from: feed, to: work)
            try await Updater.run("/usr/bin/ditto", ["-x", "-k", core.path, work.appendingPathComponent("core").path])
            let newCore = work.appendingPathComponent("core/pa")
            // the new core must at least load before it replaces the working one
            try await Updater.run("/usr/bin/python3", ["-c", "import pa.cli"], in: newCore.deletingLastPathComponent())

            var newApp: URL?
            if appChanged {
                let zip = try await download(manifest.app, from: feed, to: work)
                try await Updater.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appendingPathComponent("app").path])
                let app = work.appendingPathComponent("app/Sift.app")
                guard let info = Bundle(url: app)?.infoDictionary,
                      info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                      fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Sift").path)
                else { throw UpdateError(L("The downloaded app isn't Sift", "받은 앱이 Sift가 아니에요")) }
                newApp = app
            }

            status = .installing(L("Waiting for the current run to finish…", "진행 중인 정리가 끝나길 기다리는 중…"))
            await Core.shared.hold()
            defer { Core.shared.release() }
            status = .installing(L("Installing…", "설치 중…"))
            let current = coreDir.appendingPathComponent("pa")
            let previous = coreDir.appendingPathComponent("pa.previous")  // kept for a manual rollback
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: current, to: previous)
            do {
                try fm.moveItem(at: newCore, to: current)
            } catch {
                try? fm.moveItem(at: previous, to: current)
                throw error
            }
            try Data((version + "\n").utf8).write(to: installedVersionURL, options: .atomic)

            if let newApp {
                _ = try fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp)
                try? fm.removeItem(at: work)
                relaunch()
            }
            try? fm.removeItem(at: work)
            offer = nil
            status = .done(L("Updated to \(version)", "\(version)으로 업데이트했어요"))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func download(_ part: UpdateManifest.Part, from feed: URL, to dir: URL) async throws -> URL {
        guard !part.file.contains("/"), part.file.hasSuffix(".zip") else { throw UpdateError(L("Invalid file name: \(part.file)", "잘못된 파일 이름: \(part.file)")) }
        let data = try await fetch(part.file, from: feed, max: 50 * 1024 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == part.size, digest == part.sha256 else {
            throw UpdateError(L("\(part.file) doesn't match the signed list. Nothing was installed", "\(part.file)이 서명된 목록과 달라요. 설치하지 않았어요"))
        }
        let url = dir.appendingPathComponent(part.file)
        try data.write(to: url)
        return url
    }

    /// Under launchd (the normal install) a failing exit makes launchd start the new app.
    private func relaunch() -> Never {
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != appLabel {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try? task.run()
            exit(0)
        }
        exit(75)
    }

    nonisolated static func run(_ tool: String, _ args: [String], in dir: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = args
            if let dir { task.currentDirectoryURL = dir }
            let err = Pipe()
            task.standardError = err
            task.standardOutput = FileHandle.nullDevice
            task.terminationHandler = { t in
                if t.terminationStatus == 0 { return done.resume() }
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").last.map(String.init) ?? ""
                let name = (tool as NSString).lastPathComponent
                done.resume(throwing: UpdateError(L("\(name) failed: \(text)", "\(name) 실패: \(text)")))
            }
            do { try task.run() } catch { done.resume(throwing: error) }
        }
    }
}

struct RecentItem: Identifiable {
    let id: String
    let time: String
    let kind: String
    let title: String
    let targets: [String]
    let confidence: Double?
    var entry: [String: Any] = [:]  // the history entry, sent back to core for a re-sort
}

final class Model: ObservableObject {
    @Published var state = "unknown"
    @Published var detail = ""
    @Published var lastRun: Date?
    @Published var lastError: String?
    @Published var inboxBlocks = 0
    @Published var today: [String: Int] = [:]
    @Published var recent: [RecentItem] = []
    @Published var review: [RecentItem] = []  // waiting for the user's check (core drops ones settled in the vault)
    @Published var reviewDismissed = Set(UserDefaults.standard.stringArray(forKey: "review.dismissed") ?? [])
    @Published var dryRun = true
    @Published var paused = false
    @Published var vault = ""
    @Published var inbox = ""
    @Published var inboxRel = ""
    @Published var checkInterval = 2.0
    @Published var quietMinutes = 5.0
    @Published var holdMinutes = 10.0
    @Published var threshold = 0.7
    @Published var codexPath = ""
    @Published var openWith = ""  // app path; empty = macOS default
    @Published var collectOnly = false  // this Mac only feeds the inbox; another Mac sorts it
    @Published var otherProcessor: String?  // the Mac that sorts this vault, when core stood down for it
    @Published var assistantDir = ""
    @Published var flash: String?
    private let bubble = Bubble()
    let updater = Updater()

    private var seenRecent: Set<String>?

    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        Shortcuts.shared.start { [weak self] shortcut in
            guard let self else { return }
            switch shortcut {
            case .quickNote: QuickNote.shared.toggle(self)
            }
        }
        DispatchQueue.main.async { [weak self] in
            installEditKeys()
            Setup.run()
            Core.shared.start()
            self?.watchCodex()
            self?.updater.start()
        }
        updater.onOffer = { [weak self] version in
            guard let self else { return }
            let item = RecentItem(id: "update-\(version)", time: "", kind: "update",
                                  title: L("Sift \(version) is available", "Sift \(version) 업데이트가 있어요"), targets: [], confidence: nil)
            self.bubble.show(item: item, more: 0, caption: L("Click to install in Settings", "눌러서 설정에서 설치")) { SettingsWindow.shared.show(self) }
        }
    }

    var needsTools: Bool { !Core.shared.hasTools }

    func installTools() {
        _ = try? Setup.tool("/usr/bin/xcode-select", ["--install"])
        show(L("Follow the installer when it opens", "설치 창이 뜨면 안내대로 설치하세요"))
    }

    var symbol: String {
        if paused { return "pause.circle" }
        switch state {
        case "processing": return "arrow.triangle.2.circlepath.circle"
        case "waiting": return "hourglass.circle"
        case "error": return "exclamationmark.triangle"
        case "collecting": return "tray.and.arrow.down"
        case "blocked": return "macbook.and.iphone"
        default: return dryRun ? "tray.circle" : "tray.full"
        }
    }

    var stateLabel: String {
        if paused { return L("Paused", "일시정지") }
        switch state {
        case "idle": return L("Idle", "대기 중")
        case "waiting": return L("Waiting for you to finish", "작성 중 대기")
        case "processing": return L("Processing", "처리 중")
        case "error": return L("Error", "오류")
        case "paused": return L("Paused", "일시정지")
        case "collecting": return L("Collecting notes only", "메모만 받는 중")
        case "blocked": return L("Another Mac is sorting", "다른 Mac이 정리 중")
        default: return L("Unknown", "알 수 없음")
        }
    }

    func reload() {
        if let data = try? Data(contentsOf: statusURL),
           let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            state = s["state"] as? String ?? "unknown"
            detail = s["detail"] as? String ?? ""
            lastError = s["last_error"] as? String
            otherProcessor = s["other_processor"] as? String
            inboxBlocks = s["inbox_blocks"] as? Int ?? 0
            today = (s["today"] as? [String: Int]) ?? [:]
            vault = s["vault"] as? String ?? vault
            inbox = s["inbox"] as? String ?? inbox
            assistantDir = s["assistant_dir"] as? String ?? assistantDir
            if let raw = s["last_run_at"] as? String {
                lastRun = ISO8601DateFormatter().date(from: raw)
            }
            review = ((s["review"] as? [[String: Any]]) ?? []).map(Model.item)
            let items: [RecentItem] = ((s["recent"] as? [[String: Any]]) ?? []).map {
                RecentItem(
                    id: "\($0["id"] ?? "")-\($0["time"] ?? "")",
                    time: $0["time"] as? String ?? "",
                    kind: $0["kind"] as? String ?? "",
                    title: $0["title"] as? String ?? "",
                    targets: $0["targets"] as? [String] ?? [],
                    confidence: ($0["confidence"] as? NSNumber)?.doubleValue,
                    entry: $0
                )
            }
            announce(items)
            recent = items
        }
        if let cfg = readConfig() {
            dryRun = cfg["dry_run"] as? Bool ?? true
            paused = cfg["paused"] as? Bool ?? false
            let language = Language(rawValue: cfg["language"] as? String ?? "") ?? .en
            if Lang.shared.current != language { Lang.shared.current = language }
            if let v = cfg["vault"] as? String { vault = (v as NSString).expandingTildeInPath }
            if let i = cfg["inbox"] as? String {
                inboxRel = i
                inbox = (vault as NSString).appendingPathComponent(i)
            }
            checkInterval = (cfg["check_interval_minutes"] as? NSNumber)?.doubleValue ?? 2
            quietMinutes = (cfg["quiet_minutes"] as? NSNumber)?.doubleValue ?? 5
            holdMinutes = (cfg["last_block_hold_minutes"] as? NSNumber)?.doubleValue ?? 10
            threshold = (cfg["review_threshold"] as? NSNumber)?.doubleValue ?? 0.7
            reviewThreshold = threshold
            codexPath = cfg["codex_path"] as? String ?? ""
            openWith = cfg["open_with"] as? String ?? ""
            collectOnly = cfg["collect_only"] as? Bool ?? false
            if let a = cfg["assistant_dir"] as? String {
                assistantDir = (vault as NSString).appendingPathComponent(a)
            }
        }
    }

    static func item(_ e: [String: Any]) -> RecentItem {
        RecentItem(
            id: "\(e["id"] ?? "")-\(e["time"] ?? "")",
            time: e["time"] as? String ?? "",
            kind: e["kind"] as? String ?? "",
            title: e["title"] as? String ?? "",
            targets: e["targets"] as? [String] ?? [],
            confidence: (e["confidence"] as? NSNumber)?.doubleValue,
            entry: e
        )
    }

    var pendingReview: [RecentItem] { review.filter { !reviewDismissed.contains($0.id) } }

    /// ✓ in the list: the user looked at it. Kept on this Mac only; the vault is not touched.
    func dismissReview(_ item: RecentItem) {
        reviewDismissed.insert(item.id)
        let live = Set(review.map(\.id))  // forget ids core no longer lists
        UserDefaults.standard.set(Array(reviewDismissed.filter { live.contains($0) }), forKey: "review.dismissed")
    }

    /// Open the review note when there is one: it says why the item needs a look.
    func openReview(_ item: RecentItem) {
        if let target = item.targets.first(where: { $0.contains("/review/") }) ?? item.targets.first { openNote(target) }
    }

    // MARK: processed notice

    /// Menu bar notice for items that appeared since the last poll ("To todo · call the dentist").
    func announce(_ items: [RecentItem]) {
        let ids = Set(items.map(\.id))
        defer { seenRecent = ids; updateTooltip(items) }
        guard let seen = seenRecent else { return }  // first load: nothing is new
        let fresh = items.filter { !seen.contains($0.id) }
        guard let first = fresh.first else { return }
        bubble.show(item: first, more: fresh.count - 1) { [weak self] in
            if let target = first.targets.first { self?.openNote(target) }
        }
    }

    static func destination(_ item: RecentItem) -> String {
        let target = item.targets.first ?? ""
        if target.hasSuffix("/todo.md") || item.kind == "todo" && target.isEmpty { return "todo" }
        if target.hasSuffix("/calendar-queue.md") { return L("calendar", "일정 후보") }
        if target.contains("/review/") || target.isEmpty { return "review" }
        return L("notes", "문서")
    }

    static func clip(_ text: String, _ limit: Int = 18) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Hover tooltip on the menu bar icon: the last few processed items.
    func updateTooltip(_ items: [RecentItem]) {
        let lines = items.prefix(5).map { "\($0.time.suffix(5))  \(Model.destination($0)) · \(Model.clip($0.title, 30))" }
        let tip = lines.isEmpty ? "Sift: \(stateLabel)"
            : "Sift: \(stateLabel)\n" + L("Recent", "최근 처리") + "\n" + lines.joined(separator: "\n")
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if window.contentView?.toolTip != tip { window.contentView?.toolTip = tip }
        }
    }

    // MARK: commands

    func readConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func setLanguage(_ language: Language) {
        guard language != Lang.shared.current else { return }
        Lang.shared.current = language
        setConfig("language", language.rawValue)
        SettingsWindow.shared.retitle()
        // core writes the status line; a config change makes it check (and rewrite it) on the next tick, so tick now
        Core.shared.tick()
    }

    func setConfig(_ key: String, _ value: Any) {
        setConfig([key: value])
    }

    /// Missing keys fall back to core defaults, so a missing config.json is fine.
    func setConfig(_ values: [String: Any]) {
        var cfg = readConfig() ?? [:]
        cfg.merge(values) { _, new in new }
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
        } catch {
            warn(L("Couldn't save settings", "설정을 저장하지 못했어요"), "\(configURL.path)\n\(error.localizedDescription)")
        }
        reload()
    }

    func runNow() {
        FileManager.default.createFile(atPath: runNowURL.path, contents: Data())
        kick()
        show(L("Processing requested (everything, including the last block)", "처리를 요청했어요 (마지막 블록까지 모두)"))
    }

    func kick() {
        Core.shared.tick()
    }

    /// Take the vault over from the other Mac: core claims it on its next run.
    func sortHere() {
        setConfig("collect_only", false)
        FileManager.default.createFile(atPath: supportDir.appendingPathComponent("claim-vault").path, contents: Data())
        kick()
        show(L("This Mac sorts the vault from now on", "이제 이 Mac이 정리해요"))
    }

    func setCollectOnly(_ on: Bool) {
        setConfig("collect_only", on)
        kick()
    }

    /// Vault and inbox are both chosen before anything is used.
    var needsSetup: Bool {
        vault.isEmpty || inboxRel.isEmpty || !FileManager.default.fileExists(atPath: inbox)
    }

    /// Hand a quick note to core; it appends it to the inbox under its run lock.
    /// `request` becomes a request line for the AI; `group` keeps the whole note as one item.
    func submitQuickNote(_ text: String, request: String = "", group: Bool = false, resort: [String: Any]? = nil) -> Bool {
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
        var note: [String: Any] = ["text": text, "request": request, "group": group]
        if let resort { note["resort"] = resort }
        do {
            try FileManager.default.createDirectory(at: quickDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: note)
            try data.write(to: quickDir.appendingPathComponent(name), options: .atomic)
        } catch {
            warn(L("Couldn't save the note", "메모를 저장하지 못했어요"), error.localizedDescription)
            return false
        }
        kick()
        return true
    }

    /// Quick-note confirmation under the menu bar icon; the processed result follows in another bubble.
    func notifyQueued(_ text: String) {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let item = RecentItem(id: "queued", time: "", kind: "quick", title: Model.clip(first, 40), targets: [], confidence: nil)
        bubble.show(item: item, more: 0, caption: L("Added to the inbox · you'll hear when it's sorted", "inbox에 넣었어요 · 정리되면 알려 드릴게요")) { [weak self] in
            guard let self else { return }
            self.openFile(self.inbox)
        }
    }

    /// Re-sort: core re-queues the original text with the user's instruction and records the
    /// correction in rules/corrections.md. The earlier entry is not deleted (the assistant never deletes).
    func resort(_ item: RecentItem) {
        guard !item.entry.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("How should this be re-sorted?", "어떻게 다시 정리할까요?")
        let targets = item.targets.joined(separator: ", ")
        alert.informativeText = L("""
            “\(item.title)”
            Now in: \(targets)

            Sift re-sorts it as you say and records the correction in rules/corrections.md for later runs.
            The earlier entry isn't deleted; remove it yourself if needed.
            """, """
            「\(item.title)」
            지금 위치: \(targets)

            적은 대로 다시 정리하고, 바로잡은 내용은 rules/corrections.md에 남겨 다음 정리에 반영해요.
            이전 항목은 지우지 않으니 필요하면 직접 지워 주세요.
            """)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = L("e.g. into the alpha project note / an idea, not a todo", "예: alpha 프로젝트 문서로 / todo 말고 아이디어로")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Re-sort", "다시 정리"))
        alert.addButton(withTitle: L("Cancel", "취소"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let instruction = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return show(L("Say how to change it", "어떻게 바꿀지 적어 주세요")) }
        if submitQuickNote("", request: instruction, group: true, resort: item.entry) {
            let queued = RecentItem(id: "resort", time: "", kind: "quick", title: Model.clip(item.title, 40), targets: [], confidence: nil)
            bubble.show(item: queued, more: 0, caption: L("Re-sort requested · the earlier entry stays", "다시 정리를 요청했어요 · 이전 항목은 그대로 있어요")) { [weak self] in
                if let target = item.targets.first { self?.openNote(target) }
            }
        }
    }

    /// nil when Codex is ready; "missing" or "login" otherwise. Checked at launch, every 30 minutes
    /// (every 30 seconds while there is a problem), and when the codex path changes.
    @Published var codexIssue: String?
    private var codexTimer: Timer?

    func watchCodex() {
        checkCodex()
        codexTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let slow = Int(Date().timeIntervalSince1970) % 1800 < 30
            if self.codexIssue != nil || slow { self.checkCodex() }
        }
    }

    func checkCodex() {
        let path = codexPath.isEmpty ? "/opt/homebrew/bin/codex" : codexPath
        DispatchQueue.global().async { [weak self] in
            var issue: String?
            if !FileManager.default.isExecutableFile(atPath: path) {
                issue = "missing"
            } else {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = ["login", "status"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                task.environment = env
                let out = Pipe()
                task.standardOutput = out
                task.standardError = out
                if (try? task.run()) != nil {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if task.isRunning { task.terminate() } }
                    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
                    task.waitUntilExit()
                    if task.terminationStatus != 0 || text.contains("not logged in") { issue = "login" }
                }
            }
            DispatchQueue.main.async { self?.codexIssue = issue }
        }
    }

    /// Opens Terminal with `codex login` (a .command file, so no automation permission is needed).
    func codexLogin() {
        let path = codexPath.isEmpty ? "/opt/homebrew/bin/codex" : codexPath
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("sift-codex-login.command")
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let body = "#!/bin/zsh\nexport PATH=/opt/homebrew/bin:/usr/local/bin:$PATH\n\(quoted) login\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            warn(L("Couldn't open Terminal", "터미널을 열지 못했어요"), L("Run codex login in Terminal.", "터미널에서 codex login을 실행하세요."))
        }
    }

    // MARK: locations

    /// Pick the vault, then the inbox inside it. Nothing is saved until both are chosen.
    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose", "선택")
        panel.message = L("Choose your notes folder (vault). Any folder of markdown files works, Obsidian vaults included", "노트 폴더(vault)를 고르세요. 마크다운 파일이 있는 폴더면 돼요 (Obsidian vault 포함)")
        panel.directoryURL = vault.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: vault)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard let rel = pickInbox(in: path) else { return }
        if !vault.isEmpty, path != vault {
            let alert = NSAlert()
            alert.messageText = L("Switch vaults?", "vault를 바꿀까요?")
            let shown = (path as NSString).abbreviatingWithTildeInPath, folder = (assistantDir as NSString).lastPathComponent
            alert.informativeText = L("""
                \(shown)
                inbox: \(rel)

                • Creates a \(folder)/ folder for the results
                • Recent history starts over for the new vault (files in the old vault stay as they are)
                """, """
                \(shown)
                inbox: \(rel)

                • 정리 결과를 둘 \(folder)/ 폴더를 새로 만듦
                • 최근 처리 이력은 새 vault 기준으로 다시 시작 (기존 vault 파일은 그대로)
                """)
            alert.addButton(withTitle: L("Switch", "바꾸기"))
            alert.addButton(withTitle: L("Cancel", "취소"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setConfig(["vault": path, "inbox": rel])
        kick()
        show(L("Vault and inbox set", "vault와 inbox를 정했어요"))
    }

    func chooseInbox() {
        if vault.isEmpty { return chooseVault() }
        guard let rel = pickInbox(in: vault), rel != inboxRel else { return }
        setConfig("inbox", rel)
        kick()
        show(L("Inbox changed to \(rel)", "inbox를 \(rel)로 바꿨어요"))
    }

    /// Returns the inbox path relative to `root`, or nil if cancelled or invalid.
    /// A new file is created only when the user asks for one here.
    private func pickInbox(in root: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Choose the inbox file", "inbox 파일을 정해 주세요")
        let shown = (root as NSString).abbreviatingWithTildeInPath
        alert.informativeText = L("""
            The .md file where you jot notes. Sift sorts what you write there.
            Pick an existing file in \(shown) or create a new one.
            """, """
            메모를 적어 두는 .md 파일이에요. Sift가 여기 적힌 메모를 정리해요.
            \(shown) 안에서 기존 파일을 고르거나 새로 만드세요.
            """)
        alert.addButton(withTitle: L("Choose Existing…", "기존 파일 고르기…"))
        alert.addButton(withTitle: L("Create New…", "새 파일 만들기…"))
        alert.addButton(withTitle: L("Cancel", "취소"))
        NSApp.activate(ignoringOtherApps: true)
        let md = UTType(filenameExtension: "md") ?? .plainText
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [md]
            panel.prompt = L("Choose", "선택")
            panel.message = L("Choose the inbox file (.md) inside the vault", "vault 안의 inbox 파일(.md)을 고르세요")
            let current = (root as NSString).appendingPathComponent((inboxRel as NSString).deletingLastPathComponent)
            panel.directoryURL = URL(fileURLWithPath: root == vault && !inboxRel.isEmpty ? current : root)
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return inboxRelative(url, root: root)
        case .alertSecondButtonReturn:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [md]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "inbox.md"
            panel.prompt = L("Create", "만들기")
            panel.message = L("Name the new inbox file and pick where it goes inside the vault", "vault 안에 만들 inbox 파일 이름과 위치를 정하세요")
            panel.directoryURL = URL(fileURLWithPath: root)
            guard panel.runModal() == .OK, let url = panel.url,
                  let rel = inboxRelative(url, root: root) else { return nil }
            if !FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.createFile(atPath: url.path, contents: Data()) {
                warn(L("Couldn't create the inbox file", "inbox 파일을 만들지 못했어요"), url.path)
                return nil
            }
            return rel
        default:
            return nil
        }
    }

    private func inboxRelative(_ url: URL, root: String) -> String? {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
        let file = url.resolvingSymlinksInPath().path
        let assistant = assistantDir.isEmpty ? "99-assistant" : (assistantDir as NSString).lastPathComponent
        guard file.hasPrefix(base) else {
            warn(L("The inbox must be inside the vault", "inbox는 vault 안에 있어야 해요"), "vault: \(root)\n" + L("chosen", "선택") + ": \(file)")
            return nil
        }
        let rel = String(file.dropFirst(base.count))
        if rel.hasPrefix(assistant + "/") {
            warn(L("Files in \(assistant)/ can't be the inbox", "\(assistant)/ 안의 파일은 inbox로 쓸 수 없어요"), rel)
            return nil
        }
        return rel
    }

    func chooseCodex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = L("Choose", "선택")
        panel.message = L("Choose the codex executable", "codex 실행 파일을 고르세요")
        panel.directoryURL = URL(fileURLWithPath: (codexPath as NSString).deletingLastPathComponent)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return warn(L("That isn't an executable", "실행 파일이 아니에요"), url.path)
        }
        setConfig("codex_path", url.path)
        checkCodex()
    }

    func number(_ key: String, _ value: Double) {
        setConfig(key, value.rounded() == value ? NSNumber(value: Int(value)) : NSNumber(value: value))
    }

    func warn(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    func togglePause() {
        setConfig("paused", !paused)
        show(paused ? L("Paused", "일시정지했어요") : L("Resumed", "다시 시작했어요"))
    }

    func toggleDryRun() {
        setConfig("dry_run", !dryRun)
        show(dryRun ? L("Dry-run: proposals only", "dry-run 모드: 제안만 작성") : L("Writing for real", "실제 기록 모드"))
    }

    func show(_ message: String) {
        flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.flash == message { self?.flash = nil }
        }
    }

    /// Opens a note with the app chosen in settings (config open_with), else the macOS default app.
    func openFile(_ absolutePath: String) {
        let url = URL(fileURLWithPath: absolutePath)
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            let name = (absolutePath as NSString).lastPathComponent
            return show(L("File not found: \(name)", "파일이 없어요: \(name)"))
        }
        if !openWith.isEmpty, FileManager.default.fileExists(atPath: openWith) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: openWith),
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openNote(_ relative: String) {
        openFile((vault as NSString).appendingPathComponent(relative))
    }

    /// Apps offered in settings besides "default" and "other…": Margin when installed.
    static let knownEditors = ["io.github.kpiljoong.margin"]

    var suggestedEditors: [URL] {
        Model.knownEditors.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    func chooseOpenWith() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Choose", "선택")
        panel.message = L("Choose the app to open notes with", "노트를 열 앱을 고르세요")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setConfig("open_with", url.path)
    }

    /// Review notes are one file per day: open the newest in the editor rather than the folder in Finder
    /// (an editor like Margin would make the review folder its workspace).
    func openReview() {
        let dir = URL(fileURLWithPath: (assistantDir as NSString).appendingPathComponent("review"))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "md" } ?? []
        let modified = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        guard let newest = files.max(by: { modified($0) < modified($1) }) else {
            return show(L("Nothing to review", "확인할 review가 없어요"))
        }
        openFile(newest.path)
    }

    func todayLog() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return (assistantDir as NSString).appendingPathComponent("log/\(f.string(from: Date())).md")
    }
}

// MARK: views

var reviewThreshold = 0.7  // mirrors config review_threshold

extension Model {
    var stateColor: Color {
        if paused { return .gray }
        switch state {
        case "processing": return .blue
        case "waiting": return .orange
        case "error": return .red
        case "idle": return .green
        default: return .gray
        }
    }
}

struct KindStyle {
    let symbol: String
    let color: Color
    let label: String

    init(_ kind: String) {
        switch kind {
        case "todo": (symbol, color, label) = ("checkmark.circle.fill", .blue, "todo")
        case "project": (symbol, color, label) = ("folder.fill", .purple, L("Project", "프로젝트"))
        case "idea": (symbol, color, label) = ("lightbulb.fill", .yellow, L("Idea", "아이디어"))
        case "meeting": (symbol, color, label) = ("person.2.fill", .teal, L("Meeting", "미팅"))
        case "note": (symbol, color, label) = ("doc.text.fill", .indigo, L("Note", "노트"))
        case "calendar": (symbol, color, label) = ("calendar", .red, L("Calendar", "일정"))
        case "quick": (symbol, color, label) = ("square.and.pencil", .blue, L("Note", "메모"))
        case "update": (symbol, color, label) = ("arrow.down.circle.fill", .green, L("Update", "업데이트"))
        default: (symbol, color, label) = ("tray.fill", .gray, kind.isEmpty ? L("Other", "기타") : kind)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

struct Stat: View {
    let symbol: String
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.caption).foregroundStyle(value > 0 ? color : Color.secondary.opacity(0.5))
            Text("\(value)").font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct RecentRow: View {
    let item: RecentItem
    let open: () -> Void
    var resort: (() -> Void)?
    var dismiss: (() -> Void)?
    @State private var hover = false

    var body: some View {
        let style = KindStyle(item.kind)
        let low = (item.confidence ?? 1) < reviewThreshold
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.color)
                    .frame(width: 26, height: 26)
                    .background(style.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .medium))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if hover, let resort {
                            Button(action: resort) {
                                Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 13))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L("Re-sort…", "다시 정리…"))
                        }
                        if hover, let dismiss {
                            Button(action: dismiss) {
                                Image(systemName: "checkmark.circle").font(.system(size: 13))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L("Checked: hide from this list", "확인함: 목록에서 숨기기"))
                        }
                        Text(shortTime(item.time)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        Text(style.label).font(.caption2.weight(.medium)).foregroundStyle(style.color)
                        if let c = item.confidence {
                            Text(String(format: "%.0f%%", c * 100))
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(low ? Color.orange : Color.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background((low ? Color.orange : Color.secondary).opacity(0.14), in: Capsule())
                                .help(low ? L("Needs review", "확인 필요") + " (confidence < \(Int(reviewThreshold * 100))%)" : "confidence")
                        }
                        Text(item.targets.first.map(displayPath) ?? "-")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.targets.joined(separator: "\n"))
        .contextMenu {
            Button(L("Open", "열기"), action: open)
            if let resort { Button(L("Re-sort…", "다시 정리…"), action: resort) }
            if let dismiss { Button(L("Mark as Checked", "확인함"), action: dismiss) }
        }
    }

    // "2026-09-26 16:42" -> "16:42" for today, "9/26" otherwise
    func shortTime(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return raw }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if parts[0] == f.string(from: Date()) { return String(parts[1]) }
        let d = parts[0].split(separator: "-")
        return d.count == 3 ? "\(Int(d[1]) ?? 0)/\(Int(d[2]) ?? 0) \(parts[1])" : raw
    }

    // drop ".md" and show "folder › file"
    func displayPath(_ path: String) -> String {
        let trimmed = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
        return trimmed.split(separator: "/").joined(separator: " › ")
    }
}

struct LinkButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(hover ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: global hot keys

/// A global hot key via Carbon RegisterEventHotKey (no accessibility permission needed).
/// Unregistered when released.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Fails with the Carbon status, e.g. eventHotKeyExistsErr when another app holds the combination.
    static func register(_ key: KeyCombo, action: @escaping () -> Void) -> Result<HotKey, HotKeyError> {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { HotKey.actions[id.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let hotKey = HotKey(id: nextID)
        nextID += 1
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: OSType(0x5041_4e54), id: hotKey.id),
                                         GetApplicationEventTarget(), 0, &hotKey.ref)
        guard status == noErr, hotKey.ref != nil else { return .failure(.taken(status)) }
        actions[hotKey.id] = action
        return .success(hotKey)
    }

    private init(id: UInt32) { self.id = id }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}

enum HotKeyError: Error {
    case taken(OSStatus)
}

/// A key code plus Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
struct KeyCombo: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    init?(stored: Any?) {
        guard let dict = stored as? [String: Any],
              let code = (dict["keyCode"] as? NSNumber)?.uint32Value,
              let mods = (dict["modifiers"] as? NSNumber)?.uint32Value else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    var stored: [String: Any] { ["keyCode": keyCode, "modifiers": modifiers] }

    var isFunctionKey: Bool { KeyCombo.functionKeys.keys.contains(Int(keyCode)) }

    /// "⌃⌥⇧⌘" order, as in macOS menus.
    /// Tight spots (the panel link): Space as ␣.
    var shortLabel: String { label.replacingOccurrences(of: "Space", with: "␣") }

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]
    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// The key's character on the ASCII layout (not the current input source: Korean would give "ㅍ").
    private var keyName: String {
        let code = Int(keyCode)
        if let name = KeyCombo.specialKeys[code] ?? KeyCombo.functionKeys[code] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Every global shortcut Sift offers. Add a case to get a recordable row in settings.
enum Shortcut: String, CaseIterable, Identifiable {
    case quickNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickNote: L("Quick note", "빠른 메모")
        }
    }

    var hint: String {
        switch self {
        case .quickNote: L("Open the note window from anywhere and add straight to the inbox. Quick notes are sorted without waiting",
                            "어디서든 입력창을 열어 inbox에 바로 넣기. 넣은 메모는 대기 없이 정리")
        }
    }

    var defaultKey: KeyCombo {
        switch self {
        case .quickNote: KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        }
    }

    var defaultsKey: String { "shortcut.\(rawValue)" }
}

/// Registers the shortcuts, records new ones in settings and keeps them in UserDefaults.
/// A combination that can't be registered is refused and the previous one stays.
/// macOS lets two apps register the same hot key without an error, and the other app's one swallows
/// the key press, so while recording such a combination simply never arrives.
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    @Published private(set) var keys: [Shortcut: KeyCombo] = [:]
    /// Shortcuts whose saved key couldn't be registered at launch.
    @Published private(set) var failed: Set<Shortcut> = []
    @Published private(set) var recording: Shortcut?
    /// The latest refusal, shown under the row until the next change.
    @Published var message: (shortcut: Shortcut, text: String)?

    private var hotKeys: [Shortcut: HotKey] = [:]
    private var action: (Shortcut) -> Void = { _ in }
    private var monitor: Any?

    func start(_ action: @escaping (Shortcut) -> Void) {
        self.action = action
        for shortcut in Shortcut.allCases {
            let key = KeyCombo(stored: UserDefaults.standard.object(forKey: shortcut.defaultsKey)) ?? shortcut.defaultKey
            keys[shortcut] = key
            if !register(shortcut, key) { failed.insert(shortcut) }
        }
    }

    func key(_ shortcut: Shortcut) -> KeyCombo { keys[shortcut] ?? shortcut.defaultKey }
    func label(_ shortcut: Shortcut) -> String { key(shortcut).label }

    private func register(_ shortcut: Shortcut, _ key: KeyCombo) -> Bool {
        hotKeys[shortcut] = nil
        switch HotKey.register(key, action: { [weak self] in self?.action(shortcut) }) {
        case .success(let hotKey):
            hotKeys[shortcut] = hotKey
            return true
        case .failure:
            return false
        }
    }

    // MARK: recording

    /// Listens for the next key combination. The shortcuts are released meanwhile,
    /// so pressing the current combination records it instead of firing it.
    func record(_ shortcut: Shortcut) {
        stopRecording()
        message = nil
        recording = shortcut
        hotKeys.removeAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let shortcut = self.recording else { return event }
            let key = KeyCombo(event: event)
            if key.modifiers == 0 && (key.keyCode == UInt32(kVK_Escape) || key.keyCode == UInt32(kVK_Delete)) {
                self.cancelRecording()
            } else {
                self.apply(key, to: shortcut)
            }
            return nil
        }
    }

    func cancelRecording() {
        guard recording != nil else { return }
        stopRecording()
        restore()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    /// Re-registers every shortcut with its current key (after recording released them).
    private func restore() {
        for shortcut in Shortcut.allCases where hotKeys[shortcut] == nil {
            if register(shortcut, key(shortcut)) { failed.remove(shortcut) } else { failed.insert(shortcut) }
        }
    }

    func resetToDefault(_ shortcut: Shortcut) {
        cancelRecording()
        message = nil
        apply(shortcut.defaultKey, to: shortcut)
    }

    private func apply(_ key: KeyCombo, to shortcut: Shortcut) {
        stopRecording()
        if let problem = problem(with: key, for: shortcut) {
            refuse(shortcut, problem)
            return
        }
        hotKeys[shortcut] = nil
        if register(shortcut, key) {
            keys[shortcut] = key
            failed.remove(shortcut)
            if key == shortcut.defaultKey {
                UserDefaults.standard.removeObject(forKey: shortcut.defaultsKey)
            } else {
                UserDefaults.standard.set(key.stored, forKey: shortcut.defaultsKey)
            }
            message = nil
        } else {
            refuse(shortcut, L("Another app already uses \(key.label)", "\(key.label)는 다른 앱이 이미 쓰고 있어요"))
        }
        restore()
    }

    private func refuse(_ shortcut: Shortcut, _ text: String) {
        let current = label(shortcut)
        message = (shortcut, text + L(". Keeping \(current)", ". \(current)를 그대로 써요"))
        restore()
        NSSound.beep()
    }

    /// Why the combination can't be used, or nil. RegisterEventHotKey only catches other apps'
    /// hot keys; system shortcuts and everyday editing keys are checked here.
    private func problem(with key: KeyCombo, for shortcut: Shortcut) -> String? {
        let command = UInt32(cmdKey), option = UInt32(optionKey), control = UInt32(controlKey)
        if key.modifiers & (command | option | control) == 0 && !key.isFunctionKey {
            return L("Include ⌘, ⌥ or ⌃", "⌘·⌥·⌃ 중 하나와 함께 눌러 주세요")
        }
        if let other = Shortcut.allCases.first(where: { $0 != shortcut && self.key($0) == key }) {
            return L("\(key.label) is already the \(other.title) shortcut", "\(key.label)는 이미 \(other.title) 단축키예요")
        }
        if KeyCombo.reserved.contains(key) {
            return L("Apps commonly use \(key.label), so Sift won't take it over", "\(key.label)는 앱에서 흔히 쓰는 단축키라 가로채면 안 돼요")
        }
        if systemShortcuts().contains(key) {
            return L("\(key.label) is a macOS shortcut (System Settings > Keyboard > Keyboard Shortcuts)", "\(key.label)는 macOS 단축키로 쓰이고 있어요 (시스템 설정 > 키보드 > 키보드 단축키)")
        }
        return nil
    }

    /// Enabled symbolic hot keys (Spotlight, input source switching, screenshots, …).
    private func systemShortcuts() -> [KeyCombo] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return nil }
            let carbon = mods & UInt32(cmdKey | optionKey | controlKey | shiftKey)
            return KeyCombo(keyCode: code, modifiers: carbon)
        }
    }
}

extension KeyCombo {
    /// ⌘ shortcuts every app relies on; a global hot key would take them away everywhere.
    static let reserved: [KeyCombo] = {
        let command = UInt32(cmdKey), shift = UInt32(shiftKey)
        let keys = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_S,
                    kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_F, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_T, kVK_Tab,
                    kVK_Space, kVK_ANSI_Comma]
        return keys.map { KeyCombo(keyCode: UInt32($0), modifiers: command) }
            + [kVK_ANSI_Z, kVK_Tab, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
            .map { KeyCombo(keyCode: UInt32($0), modifiers: command | shift) }
    }()
}

/// A settings row: the current key, Change (then press the new combination) and Default.
struct ShortcutRow: View {
    @ObservedObject var shortcuts = Shortcuts.shared
    let shortcut: Shortcut

    var body: some View {
        let recording = shortcuts.recording == shortcut
        let failed = shortcuts.failed.contains(shortcut)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortcut.title)
                    Text(shortcut.hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(recording ? L("Press the new keys", "새 키 조합을 누르세요") : shortcuts.label(shortcut))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(recording ? Color.accentColor : failed ? Color.red : Color.primary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(recording ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(failed ? L("Another app already uses this key, so it couldn't be registered. Pick another one", "다른 앱이 이미 이 키를 쓰고 있어서 등록하지 못했어요. 다른 키로 바꿔 주세요") : "")
                Button(recording ? L("Cancel", "취소") : L("Change", "변경")) {
                    recording ? shortcuts.cancelRecording() : shortcuts.record(shortcut)
                }
                Button(L("Default", "기본값")) { shortcuts.resetToDefault(shortcut) }
                    .disabled(shortcuts.key(shortcut) == shortcut.defaultKey && !failed)
                    .help(L("Back to \(shortcut.defaultKey.label)", "\(shortcut.defaultKey.label)로 되돌리기"))
            }
            if recording {
                Text(L("Include ⌘, ⌥ or ⌃ · esc cancels\nIf nothing happens, another app is using those keys. Try another combination",
                       "⌘·⌥·⌃ 중 하나를 포함해 누르세요 · esc 취소\n눌러도 반응이 없으면 다른 앱이 그 키를 쓰고 있어요. 다른 조합을 눌러 주세요"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let message = shortcuts.message, message.shortcut == shortcut {
                Text(message.text).font(.caption).foregroundStyle(.red)
            } else if failed {
                Text(L("Couldn't register \(shortcuts.label(shortcut)): another app is using it. Pick another key",
                       "\(shortcuts.label(shortcut)) 등록 실패: 다른 앱이 쓰고 있어요. 다른 키로 바꿔 주세요"))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: quick note

/// Panel that takes keyboard focus without activating the app (like Spotlight).
/// A menu bar app has no Edit menu, and the quick-note panel takes keys without activating Sift,
/// so ⌘V/⌘C/⌘X/⌘A/⌘Z never reach text fields on their own. Route them for every Sift window
/// (quick note, alerts). Key codes, not characters: with a Korean input source ⌘V arrives as "ㅍ".
func installEditKeys() {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector?
        switch (Int(event.keyCode), mods) {
        case (kVK_ANSI_X, .command): action = #selector(NSText.cut(_:))
        case (kVK_ANSI_C, .command): action = #selector(NSText.copy(_:))
        case (kVK_ANSI_V, .command): action = #selector(NSText.paste(_:))
        case (kVK_ANSI_A, .command): action = #selector(NSText.selectAll(_:))
        case (kVK_ANSI_Z, .command): action = Selector(("undo:"))
        case (kVK_ANSI_Z, [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: nil) { return nil }
        return event
    }
}

// MARK: @ targets

/// A note or folder the quick note can point at with @. Read from core's index, which
/// already leaves out .assistantignore paths and the assistant folder.
struct MentionTarget: Identifiable, Equatable {
    let path: String  // vault-relative; folders end with "/"
    let title: String
    let token: String  // shown after @ in the editor, e.g. "alpha/" or "README"
    let mtime: Double

    var id: String { path }
    var isFolder: Bool { path.hasSuffix("/") }
    /// Folder or file name without .md.
    var name: String {
        let last = ((isFolder ? String(path.dropLast()) : path) as NSString).lastPathComponent
        return isFolder ? last : (last as NSString).deletingPathExtension
    }
    /// Containing folder without the trailing slash; "" at the vault root.
    var parent: String { ((isFolder ? String(path.dropLast()) : path) as NSString).deletingLastPathComponent }
    /// What core reads: `@[[01-projects/alpha/README]]` (no .md) or `@[[01-projects/alpha/]]`.
    var link: String { "@[[\(isFolder ? path : String(path.dropLast(3)))]]" }
}

enum MentionIndex {
    static let url = supportDir.appendingPathComponent("index.json")

    static func load(vault: String) -> [MentionTarget] {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = index["notes"] as? [String: [String: Any]],
              let indexed = index["vault"] as? String, same(indexed, vault) else { return [] }
        var folders: [String: Double] = [:]
        var items: [(path: String, title: String, name: String, parent: String, mtime: Double)] = []
        for (rel, note) in notes {
            let mtime = (note["mtime"] as? NSNumber)?.doubleValue ?? 0
            let path = rel as NSString
            items.append((rel, note["title"] as? String ?? "", (path.lastPathComponent as NSString).deletingPathExtension,
                          path.deletingLastPathComponent, mtime))
            var dir = path.deletingLastPathComponent
            while !dir.isEmpty {
                folders[dir + "/"] = max(folders[dir + "/"] ?? 0, mtime)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        for (dir, mtime) in folders {
            let trimmed = String(dir.dropLast()) as NSString
            items.append((dir, trimmed.lastPathComponent, trimmed.lastPathComponent + "/", trimmed.deletingLastPathComponent, mtime))
        }
        // file names repeat (README, index); those get their parent folder in front
        let counts = Dictionary(grouping: items, by: { $0.name.lowercased() }).mapValues(\.count)
        return items.map { item in
            let parent = (item.parent as NSString).lastPathComponent
            let token = counts[item.name.lowercased()] ?? 0 > 1 && !parent.isEmpty ? "\(parent)/\(item.name)" : item.name
            return MentionTarget(path: item.path, title: item.title, token: token, mtime: item.mtime)
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ p: String) -> String {
            URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return norm(a) == norm(b)
    }

    /// With a "/" the query browses a folder ("01-projects/" lists what's directly inside, "01-projects/al" narrows it);
    /// otherwise: name prefix first, then title prefix, then anywhere in name/title/path; recent first within each.
    static func search(_ query: String, in targets: [MentionTarget], limit: Int = 50) -> (items: [MentionTarget], folder: String?) {
        if let slash = query.lastIndex(of: "/") {
            guard let folder = folder(String(query[..<slash]), in: targets) else { return ([], nil) }
            let rest = query[query.index(after: slash)...].lowercased()
            let inside = targets.filter { t in
                t.parent == folder && (rest.isEmpty || t.name.lowercased().contains(rest) || t.title.lowercased().contains(rest))
            }
            let sorted = inside.sorted { a, b in
                let pa = a.name.lowercased().hasPrefix(rest), pb = b.name.lowercased().hasPrefix(rest)
                if pa != pb { return pa }
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return (Array(sorted.prefix(limit * 4)), folder)
        }
        return (rank(query, targets, limit), nil)
    }

    /// "" is the vault root; otherwise a folder path, or the end of one ("alpha" → "01-projects/alpha"), most recent first.
    private static func folder(_ query: String, in targets: [MentionTarget]) -> String? {
        let q = query.lowercased()
        if q.isEmpty { return "" }
        let folders = targets.filter(\.isFolder)
        if let exact = folders.first(where: { $0.path.dropLast().lowercased() == q }) { return String(exact.path.dropLast()) }
        return folders.filter { ("/" + $0.path.dropLast().lowercased()).hasSuffix("/" + q) }
            .max { $0.mtime < $1.mtime }.map { String($0.path.dropLast()) }
    }

    private static func rank(_ query: String, _ targets: [MentionTarget], _ limit: Int) -> [MentionTarget] {
        let q = query.lowercased()
        func rank(_ t: MentionTarget) -> Int? {
            if q.isEmpty { return 0 }
            let token = t.token.lowercased(), title = t.title.lowercased()
            if token.hasPrefix(q) || (token as NSString).lastPathComponent.hasPrefix(q) { return 0 }
            if title.hasPrefix(q) { return 1 }
            if token.contains(q) || title.contains(q) { return 2 }
            if t.path.lowercased().contains(q) { return 3 }
            return nil
        }
        return targets.compactMap { t in rank(t).map { (t, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.mtime > $1.0.mtime }
            .prefix(limit).map(\.0)
    }
}

/// The quick note's editor: a plain NSTextView, because @ completion needs the caret.
struct NoteEditor: NSViewRepresentable {
    @ObservedObject var state: QuickNoteState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let saved = state.cursor
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: state.fontSize)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.textContainerInset = .zero
        text.string = state.text
        text.delegate = context.coordinator  // after the text, so loading it doesn't overwrite the saved caret
        state.editor = text
        DispatchQueue.main.async {
            // once laid out: back where the user was writing (the end the first time), scrolled into view
            text.window?.makeFirstResponder(text)
            let length = (text.string as NSString).length
            var caret = saved ?? NSRange(location: length, length: 0)
            if NSMaxRange(caret) > length { caret = NSRange(location: length, length: 0) }
            text.setSelectedRange(caret)
            text.scrollRangeToVisible(caret)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.font?.pointSize != state.fontSize {
            text.font = .systemFont(ofSize: state.fontSize)
            text.scrollRangeToVisible(text.selectedRange())
        }
        guard !text.hasMarkedText(), text.string != state.text else { return }
        text.string = state.text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: QuickNoteState
        init(state: QuickNoteState) { self.state = state }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            state.text = text.string
            state.updateCompletion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let text = notification.object as? NSTextView { state.cursor = text.selectedRange() }
            state.updateCompletion()
        }
    }
}

/// The @ completion list, in a small panel under the caret.
struct MentionList: View {
    @ObservedObject var state: QuickNoteState
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            if let completion = state.completion {
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(spacing: 0) { rows(completion) }
                    }
                    .frame(height: CGFloat(min(completion.items.count, MentionList.visibleRows)) * MentionList.rowHeight)
                    .onChange(of: completion.selected) { scroller.scrollTo(completion.items[$0].id) }
                }
                HStack {
                    Text(completion.folder.map { "\($0.isEmpty ? "vault" : $0)/ · " + L("\(completion.items.count) items", "\(completion.items.count)개") }
                         ?? L("\(completion.items.count) items · / browses folders", "\(completion.items.count)개 · /로 폴더 탐색"))
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(L("↑↓ · ⏎ insert · ⇥ open folder · esc", "↑↓ · ⏎ 넣기 · ⇥ 폴더 열기 · esc"))
                }
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 3).padding(.horizontal, 4)
            }
        }
        .padding(5)
        .frame(width: MentionList.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    func rows(_ completion: QuickNoteState.Completion) -> some View {
        ForEach(Array(completion.items.enumerated()), id: \.element.id) { index, item in
            Button { state.accept(item) } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.isFolder ? "folder" : "doc.text")
                        .foregroundStyle(item.isFolder ? Color.orange : Color.blue).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.isFolder ? item.name + "/"
                             : item.title.isEmpty || item.title == item.name ? item.name : "\(item.name) · \(item.title)")
                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: MentionList.rowHeight)
                .background(index == completion.selected ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(item.id)
        }
    }

    static let visibleRows = 8
    static func height(rows: Int) -> CGFloat { CGFloat(min(rows, visibleRows)) * rowHeight + 10 + 18 }
}

/// Clicks in the list must not take focus from the quick note (that would close it).
final class ListPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class QuickNoteState: ObservableObject {
    @Published var text: String { didSet { saveDraft() } }
    @Published var request: String { didSet { saveDraft() } }
    /// Meeting mode: the panel stays open and the note goes in as one meeting note when finished.
    @Published var meetingStart: Date? {
        didSet {
            if meetingStart == nil { meetingFrame = nil }  // a new meeting opens in the usual place
            saveDraft()
        }
    }
    /// Where the pinned meeting panel was last moved or resized; it reopens there until the meeting ends.
    var meetingFrame: NSRect? { didSet { saveDraft() } }
    /// "@alpha/" → "@[[01-projects/alpha/]]": short in the editor, exact paths when handed to core.
    var mentions: [String: String] { didSet { saveDraft() } }
    /// Where the caret was, so reopening continues there (nil: the end).
    var cursor: NSRange? { didSet { if cursor != oldValue { saveDraft() } } }

    /// Editor text size: −/+ in the footer, ⌘- ⌘+ ⌘0, or a pinch.
    static let fontSizes: [CGFloat] = [11, 12, 13, 14, 16, 18, 20, 22, 24, 28]
    static let defaultFontSize: CGFloat = 14
    @Published var fontSize: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "quickNote.fontSize"))
        return fontSizes.contains(saved) ? saved : defaultFontSize
    }() {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "quickNote.fontSize") }
    }

    /// Panel opacity in 10% steps; 40% keeps the text readable.
    static let opacities: [Double] = [0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    @Published var opacity: Double = {
        let saved = UserDefaults.standard.double(forKey: "quickNote.opacity")
        return opacities.first { abs($0 - saved) < 0.001 } ?? 1.0
    }() {
        didSet { UserDefaults.standard.set(opacity, forKey: "quickNote.opacity") }
    }

    /// One opacity step more opaque (1) or more transparent (-1).
    func fade(_ step: Int) {
        let steps = QuickNoteState.opacities
        let index = steps.firstIndex { abs($0 - opacity) < 0.001 } ?? steps.count - 1
        opacity = steps[min(max(index + step, 0), steps.count - 1)]
    }

    /// One size step bigger (1) or smaller (-1); 0 goes back to the default.
    func zoom(_ step: Int) {
        let sizes = QuickNoteState.fontSizes
        guard step != 0 else { return fontSize = QuickNoteState.defaultFontSize }
        let index = sizes.firstIndex(of: fontSize) ?? sizes.firstIndex(of: QuickNoteState.defaultFontSize)!
        fontSize = sizes[min(max(index + step, 0), sizes.count - 1)]
    }

    struct Completion {
        var range: NSRange  // "@query" before the caret
        var items: [MentionTarget]
        var folder: String?  // browsing this folder ("" = vault root)
        var selected = 0
    }
    @Published var completion: Completion?
    var targets: [MentionTarget] = []
    weak var editor: NSTextView?
    private var dismissedAt: Int?  // esc closed the list for the @ at this location

    var meeting: Bool { meetingStart != nil }

    init() {
        let saved = (try? Data(contentsOf: draftURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        text = saved["text"] as? String ?? ""
        request = saved["request"] as? String ?? ""
        meetingStart = (saved["meeting_start"] as? Double).map { Date(timeIntervalSince1970: $0) }
        mentions = saved["mentions"] as? [String: String] ?? [:]
        if let c = saved["cursor"] as? [Int], c.count == 2 { cursor = NSRange(location: c[0], length: c[1]) }
        if meetingStart != nil, let f = saved["meeting_frame"] as? [Double], f.count == 4 {
            meetingFrame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
    }

    func saveDraft() {
        if text.isEmpty && request.isEmpty && !meeting {
            try? FileManager.default.removeItem(at: draftURL)
            return
        }
        var draft: [String: Any] = ["text": text, "request": request, "mentions": mentions]
        if let cursor { draft["cursor"] = [cursor.location, cursor.length] }
        if let meetingStart { draft["meeting_start"] = meetingStart.timeIntervalSince1970 }
        if let f = meetingFrame { draft["meeting_frame"] = [f.minX, f.minY, f.width, f.height].map(Double.init) }
        if let data = try? JSONSerialization.data(withJSONObject: draft) {
            try? data.write(to: draftURL, options: .atomic)
        }
    }

    func toggleMeeting() {
        meetingStart = meeting ? nil : Date()
    }

    // MARK: @ completion

    /// Opens, narrows or closes the list from the "@…" right before the caret.
    func updateCompletion() {
        guard let editor, !targets.isEmpty else { return completion = nil }
        let selection = editor.selectedRange()
        let string = editor.string as NSString
        guard selection.length == 0, let at = mentionStart(in: string, before: selection.location) else {
            dismissedAt = nil
            return completion = nil
        }
        if at == dismissedAt { return completion = nil }
        dismissedAt = nil
        let query = string.substring(with: NSRange(location: at + 1, length: selection.location - at - 1))
        let found = MentionIndex.search(query, in: targets)
        guard !found.items.isEmpty else { return completion = nil }
        let same = completion?.range.location == at && completion?.folder == found.folder
        let keep = same ? min(completion?.selected ?? 0, found.items.count - 1) : 0
        completion = Completion(range: NSRange(location: at, length: selection.location - at), items: found.items,
                                folder: found.folder, selected: keep)
    }

    /// Location of an "@" that starts a word and has no space between it and the caret.
    private func mentionStart(in string: NSString, before caret: Int) -> Int? {
        var i = caret - 1
        while i >= 0 && caret - i <= 160 {
            let c = string.character(at: i)
            if c == 0x40 {  // @
                let before = i == 0 ? nil : string.character(at: i - 1)
                guard before.map({ Character(UnicodeScalar($0)!).isWhitespace || $0 == 0x28 }) ?? true else { return nil }
                return i
            }
            if let scalar = UnicodeScalar(c), Character(scalar).isWhitespace || "[]".contains(Character(scalar)) { return nil }
            i -= 1
        }
        return nil
    }

    func moveSelection(_ step: Int) {
        guard var c = completion else { return }
        c.selected = (c.selected + step + c.items.count) % c.items.count
        completion = c
    }

    func dismissCompletion() {
        dismissedAt = completion?.range.location
        completion = nil
    }

    func accept(_ item: MentionTarget? = nil) {
        guard let current = completion else { return }
        let item = item ?? current.items[current.selected]
        let token = "@" + item.token
        mentions[token] = item.link
        replaceQuery(with: token + " ")
        completion = nil
    }

    /// ⇥: a folder opens (the query becomes its path and the list shows what's inside); a note is accepted.
    func openOrAccept() {
        guard let current = completion else { return }
        let item = current.items[current.selected]
        guard item.isFolder else { return accept(item) }
        replaceQuery(with: "@" + item.path)
    }

    private func replaceQuery(with text: String) {
        guard let editor, let current = completion else { return }
        if editor.hasMarkedText() {  // commit the Korean syllable being composed, in the view and in the IME
            editor.unmarkText()
            editor.inputContext?.discardMarkedText()
        }
        updateCompletion()
        let range = completion?.range ?? current.range
        if editor.shouldChangeText(in: range, replacementString: text) {
            editor.replaceCharacters(in: range, with: text)
            editor.didChangeText()
        }
    }

    /// The note as core should see it: every inserted "@name" becomes its exact `@[[path]]`.
    func expandedText(_ text: String) -> String {
        var out = text
        for (token, link) in mentions.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = NSRegularExpression.escapedPattern(for: token) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: link))
        }
        return out
    }

    /// "## Meeting notes (2026-09-29 14:02–14:47)" ("## 미팅 메모 (…)" in Korean; the prompt treats both as meetings)
    func meetingHeader(until end: Date = Date()) -> String {
        guard let start = meetingStart else { return "" }
        let day = DateFormatter(), hm = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        hm.dateFormat = "HH:mm"
        return "## " + L("Meeting notes", "미팅 메모") + " (\(day.string(from: start)) \(hm.string(from: start))–\(hm.string(from: end)))"
    }
}

final class QuickNote: NSObject, NSWindowDelegate {
    static let shared = QuickNote()
    private var panel: KeyPanel?
    private let state = QuickNoteState()
    private weak var model: Model?
    private var list: ListPanel?
    private var watch: AnyCancellable?
    private var keys: Any?
    private var meetingWatch: AnyCancellable?
    private var zoomKeys: Any?
    private var opacityWatch: AnyCancellable?
    private var pinch: Any?
    private var pinched: CGFloat = 0

    func toggle(_ model: Model) {
        if let panel, panel.isVisible { close() } else { show(model) }
    }

    func show(_ model: Model) {
        self.model = model
        if model.needsSetup { return askSetup(model) }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // fresh view each time so the editor gets focus again
        panel.contentView = NSHostingView(rootView: QuickNoteView(state: state, submit: { [weak self] in self?.submit() },
                                                                  cancel: { [weak self] in self?.close() }))
        let vault = model.vault
        DispatchQueue.global().async { [weak self] in
            let targets = MentionIndex.load(vault: vault)
            DispatchQueue.main.async {
                self?.state.targets = targets
                self?.state.updateCompletion()  // a draft may end in "@…"
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if panel.isVisible {
            // already open (a pinned meeting): leave it where the user put it
        } else if state.meeting, let saved = state.meetingFrame {
            panel.setFrame(QuickNote.onScreen(saved, min: panel.minSize, fallback: screen), display: false)
        } else if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.62))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// `frame` moved fully onto the screen it overlaps most (or `fallback` when its display is gone),
    /// shrunk to fit if that screen is smaller.
    static func onScreen(_ frame: NSRect, min: NSSize, fallback: NSScreen?) -> NSRect {
        let overlap = { (s: NSScreen) -> CGFloat in
            let i = s.visibleFrame.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        let best = NSScreen.screens.max { overlap($0) < overlap($1) }
        guard let screen = (best.map(overlap) ?? 0) > 0 ? best : (fallback ?? NSScreen.main) else { return frame }
        return fit(frame, in: screen.visibleFrame, min: min)
    }

    static func fit(_ frame: NSRect, in visible: NSRect, min: NSSize) -> NSRect {
        var f = frame
        f.size.width = Swift.max(Swift.min(f.width, visible.width), Swift.min(min.width, visible.width))
        f.size.height = Swift.max(Swift.min(f.height, visible.height), Swift.min(min.height, visible.height))
        f.origin.x = Swift.min(Swift.max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = Swift.min(Swift.max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    func close() {
        state.completion = nil
        rememberMeetingFrame()  // also covers a panel moved before the meeting started
        panel?.orderOut(nil)
    }

    /// Shows the @ list under the caret (above it near the bottom of the screen).
    private func placeList(_ completion: QuickNoteState.Completion?) {
        guard let completion, let panel, panel.isVisible, let editor = state.editor else {
            list?.orderOut(nil)
            return
        }
        let list = self.list ?? makeList()
        self.list = list
        let caret = editor.firstRect(forCharacterRange: NSRange(location: completion.range.location, length: 0), actualRange: nil)
        let size = NSSize(width: MentionList.width, height: MentionList.height(rows: completion.items.count))
        var origin = NSPoint(x: caret.minX - 8, y: caret.minY - size.height - 4)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = caret.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        list.setFrame(NSRect(origin: origin, size: size), display: true)
        if list.parent == nil { panel.addChildWindow(list, ordered: .above) }
        list.orderFront(nil)
    }

    private func makeList() -> ListPanel {
        let list = ListPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        list.isOpaque = false
        list.backgroundColor = .clear
        list.hasShadow = true
        list.level = .floating
        list.contentView = NSHostingView(rootView: MentionList(state: state))
        return list
    }

    /// ↑↓ ⏎ ⇥ esc belong to the list while it's open (before the IME and the panel's buttons see them).
    private func installListKeys() {
        // text size: ⌘+ (⌘= or ⌘⇧=), ⌘-, ⌘0 and the keypad; a pinch on the trackpad
        zoomKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == .command || mods == [.command, .shift] else { return event }
            switch Int(event.keyCode) {
            case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: self.state.zoom(1)
            case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: self.state.zoom(-1)
            case kVK_ANSI_0, kVK_ANSI_Keypad0: self.state.zoom(0)
            case kVK_ANSI_LeftBracket where mods == .command: self.state.fade(-1)  // ⌘[ more transparent
            case kVK_ANSI_RightBracket where mods == .command: self.state.fade(1)  // ⌘] more opaque
            default: return event
            }
            return nil
        }
        pinch = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.pinched += event.magnification
            if abs(self.pinched) >= 0.15 {
                self.state.zoom(self.pinched > 0 ? 1 : -1)
                self.pinched = 0
            }
            return nil
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.state.completion != nil, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return event }
            switch Int(event.keyCode) {
            case kVK_DownArrow: self.state.moveSelection(1)
            case kVK_UpArrow: self.state.moveSelection(-1)
            case kVK_Return, kVK_ANSI_KeypadEnter: self.state.accept()
            case kVK_Tab: self.state.openOrAccept()
            case kVK_Escape: self.state.dismissCompletion()
            default: return event
            }
            return nil
        }
    }

    private func askSetup(_ model: Model) {
        let alert = NSAlert()
        alert.messageText = L("First choose your notes folder and inbox", "먼저 노트 폴더와 inbox를 정해 주세요")
        alert.informativeText = L("Quick notes go to the end of the inbox file. Choose the vault folder, then pick or create an inbox file inside it.",
                                  "빠른 메모는 inbox 파일 끝에 들어가요. vault 폴더를 고른 뒤 그 안의 inbox 파일을 고르거나 새로 만들면 돼요.")
        alert.addButton(withTitle: L("Choose…", "정하기…"))
        alert.addButton(withTitle: L("Later", "나중에"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { model.chooseVault() }
    }

    private func submit() {
        let typed = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = typed
        let request = state.request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let model else { return }
        let meeting = state.meeting
        text = state.expandedText(text)
        if meeting { text = state.meetingHeader() + "\n" + text }
        if model.submitQuickNote(text, request: request, group: meeting || !request.isEmpty) {
            state.text = ""
            state.request = ""
            state.meetingStart = nil
            state.mentions = [:]
            state.cursor = nil
            close()
            model.notifyQueued(typed)
        }
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: QuickNoteView.width, height: QuickNoteView.height),
                             styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        panel.minSize = NSSize(width: QuickNoteView.width, height: QuickNoteView.height)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        watch = state.$completion.receive(on: DispatchQueue.main).sink { [weak self] in self?.placeList($0) }
        // a meeting remembers the spot it started in, even if the panel is never moved afterwards
        meetingWatch = state.$meetingStart.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rememberMeetingFrame() }
        opacityWatch = state.$opacity.sink { [weak panel] in panel?.alphaValue = CGFloat($0) }
        installListKeys()
        return panel
    }

    func windowDidMove(_ notification: Notification) { rememberMeetingFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberMeetingFrame() }

    private func rememberMeetingFrame() {
        guard state.meeting, let panel, panel.isVisible else { return }
        state.meetingFrame = panel.frame
    }

    func windowDidResignKey(_ notification: Notification) {
        if !state.meeting { close() }  // clicking elsewhere closes it (the draft stays); meetings stay pinned
    }
}

struct QuickNoteView: View {
    static let width: CGFloat = 560
    static let height: CGFloat = 290
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    @ObservedObject var state: QuickNoteState
    let submit: () -> Void
    let cancel: () -> Void

    var body: some View {
        let empty = state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state.meeting ? "person.2.fill" : "square.and.pencil")
                    .foregroundStyle(state.meeting ? Color.teal : Color.blue)
                Text(state.meeting ? L("Meeting notes", "미팅 메모") : L("Quick note", "빠른 메모")).font(.system(size: 13, weight: .semibold))
                if let start = state.meetingStart {
                    let since = QuickNoteView.clock.string(from: start)
                    (Text(L("since \(since) · ", "\(since)부터 · ")) + Text(start, style: .timer))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(QuickNoteState.opacities.reversed(), id: \.self) { value in
                        Button {
                            state.opacity = value
                        } label: {
                            Text("\(Int((value * 100).rounded()))%" + (abs(value - state.opacity) < 0.001 ? " ✓" : ""))
                        }
                    }
                    Divider()
                    Text(L("⌘[ more transparent · ⌘] more opaque", "⌘[ 더 투명하게 · ⌘] 더 불투명하게"))
                } label: {
                    Label(state.opacity < 1 ? "\(Int((state.opacity * 100).rounded()))%" : "",
                          systemImage: "circle.lefthalf.filled")
                        .font(.caption.weight(.medium))
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .help(L("Window opacity (⌘[ ⌘])", "창 투명도 (⌘[ ⌘])"))
                Button(action: state.toggleMeeting) {
                    Label(state.meeting ? L("In meeting", "미팅 중") : L("Meeting", "미팅"), systemImage: state.meeting ? "pin.fill" : "pin")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((state.meeting ? Color.teal : Color.secondary).opacity(state.meeting ? 0.2 : 0.1),
                                    in: Capsule())
                        .foregroundStyle(state.meeting ? Color.teal : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(state.meeting ? L("Turn off meeting mode (the note stays)", "미팅 모드 끄기 (메모는 그대로)")
                      : L("Meeting mode: the window stays open, and the note goes in as one meeting note when you finish",
                          "미팅 모드: 창이 계속 떠 있고, 끝낼 때 '미팅 메모' 하나로 넣어요"))
            }
            ZStack(alignment: .topLeading) {
                NoteEditor(state: state)
                if state.text.isEmpty {
                    Text(state.meeting ? L("Write the meeting down. When it's over, ⌘⏎ adds it all at once.", "미팅 내용을 적으세요. 끝나면 ⌘⏎로 한 번에 넣어요.")
                         : L("Write whatever comes to mind. @ picks a note or folder to file it in; blank lines split it into separate items.",
                             "생각나는 대로 적으세요. @로 넣을 문서·폴더를 고를 수 있고, 빈 줄로 나누면 따로 정리돼요."))
                        .font(.system(size: 14)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple).font(.system(size: 12))
                TextField(L("Ask the AI (optional), e.g. make meeting notes, add to the alpha note, todos only",
                            "AI에게 요청 (선택) 예: 회의록으로 정리, alpha 문서에 추가, todo로만"), text: $state.request)
                    .textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.purple.opacity(state.request.isEmpty ? 0.04 : 0.1),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help(L("Goes in front of the note as a 'Request:' line, and the whole note is sorted as one, following it",
                    "적으면 메모 앞에 '요청:' 줄로 붙고, 메모 전체를 이 지시대로 한 번에 정리해요"))
            HStack(spacing: 10) {
                Text(L("⌘⏎ add", "⌘⏎ 넣기")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(state.meeting ? L("esc hides · \(Shortcuts.shared.label(.quickNote)) brings it back", "esc 숨기기 · \(Shortcuts.shared.label(.quickNote))로 다시")
                     : L("esc closes · the draft stays", "esc 닫기 · 초안 유지")).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 2) {
                    Button { state.zoom(-1) } label: { Image(systemName: "minus") }
                        .help(L("Smaller text (⌘-)", "글자 작게 (⌘-)"))
                        .disabled(state.fontSize <= QuickNoteState.fontSizes.first!)
                    Button { state.zoom(0) } label: {
                        Text("\(Int((state.fontSize / QuickNoteState.defaultFontSize * 100).rounded()))%")
                            .font(.caption.monospacedDigit()).frame(minWidth: 34)
                    }
                    .help(L("Default size (⌘0)", "기본 크기 (⌘0)"))
                    Button { state.zoom(1) } label: { Image(systemName: "plus") }
                        .help(L("Larger text (⌘+)", "글자 크게 (⌘+)"))
                        .disabled(state.fontSize >= QuickNoteState.fontSizes.last!)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).controlSize(.small)
                Button(state.meeting ? L("Hide", "숨기기") : L("Close", "닫기"), action: cancel).keyboardShortcut(.cancelAction).controlSize(.small)
                Button(state.meeting ? L("End meeting · add to inbox", "미팅 끝 · inbox에 넣기") : L("Add to inbox", "inbox에 넣기"), action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(empty)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        .frame(minWidth: QuickNoteView.width, maxWidth: .infinity, minHeight: QuickNoteView.height, maxHeight: .infinity)
    }
}

// MARK: processed bubble

/// Speech-bubble panel that drops down from the menu bar icon for a few seconds.
final class Bubble {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    static let width: CGFloat = 300
    static let seconds = 8.0

    func show(item: RecentItem, more: Int, caption: String? = nil, open: @escaping () -> Void) {
        guard let icon = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") })?.frame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) }) ?? NSScreen.main
        else { return }
        close()

        let visible = screen.visibleFrame
        var x = icon.midX - Bubble.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - Bubble.width - 6)
        let arrowX = icon.midX - x  // arrow stays under the icon even when the bubble is clamped

        let view = BubbleView(item: item, more: more, caption: caption, arrowX: arrowX) { [weak self] in
            open()
            self?.close()
        }
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let size = NSSize(width: Bubble.width, height: host.fittingSize.height)

        let panel = NSPanel(contentRect: NSRect(x: x, y: icon.minY - size.height - 2, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Bubble.seconds, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            if self?.panel === panel { self?.close() }
        })
    }

    func close() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

struct BubbleShape: Shape {
    let arrowX: CGFloat
    let arrow: CGFloat = 7
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrow, width: rect.width, height: rect.height - arrow)
        var p = Path(roundedRect: body, cornerRadius: 11, style: .continuous)
        let x = min(max(arrowX, 16), rect.width - 16)
        p.move(to: CGPoint(x: x - arrow - 1, y: body.minY))
        p.addLine(to: CGPoint(x: x, y: rect.minY))
        p.addLine(to: CGPoint(x: x + arrow + 1, y: body.minY))
        p.closeSubpath()
        return p
    }
}

struct BubbleView: View {
    let item: RecentItem
    let more: Int
    let caption: String?
    let arrowX: CGFloat
    let open: () -> Void

    var body: some View {
        let style = KindStyle(item.kind)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.color)
                .frame(width: 28, height: 28)
                .background(style.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(caption ?? L("To \(Model.destination(item))", "\(Model.destination(item))로 이동") + (more > 0 ? L(" · \(more) more", " · 외 \(more)건") : ""))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 7 + 10).padding(.bottom, 10)
        .frame(width: Bubble.width, alignment: .leading)
        .background(
            ZStack {
                VisualEffect().clipShape(BubbleShape(arrowX: arrowX))
                BubbleShape(arrowX: arrowX).stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        )
        .contentShape(BubbleShape(arrowX: arrowX))
        .onTapGesture(perform: open)
        .help(L("Click to open", "클릭하면 열기"))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: settings window

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(_ model: Model) {
        let opening = window?.isVisible != true
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ScrollView { SettingsView(model: model) })
            host.sizingOptions = []  // the window keeps the size set below; the content scrolls
            w.contentView = host
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Shortcuts.shared.cancelRecording()
            }
            window = w
        }
        if opening, let window {
            // as tall as the settings, but no taller than the screen (small displays scroll)
            let full = NSHostingView(rootView: SettingsView(model: model)).fittingSize.height
            let screen = (NSScreen.main ?? window.screen)?.visibleFrame.height ?? full
            let height = min(full, screen - 40)
            window.contentMinSize = NSSize(width: 460, height: min(300, height))
            window.contentMaxSize = NSSize(width: 460, height: full + 40)
            window.setContentSize(NSSize(width: 460, height: height))
            window.center()
        }
        window?.title = L("Sift Settings", "Sift 설정")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func retitle() { window?.title = L("Sift Settings", "Sift 설정") }
}

struct MinutesRow: View {
    let label: String
    let hint: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(L("\(Int(value)) min", "\(Int(value))분")).monospacedDigit().frame(minWidth: 40, alignment: .trailing)
            Stepper("", value: Binding(get: { value }, set: set), in: range, step: 1).labelsHidden()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @ObservedObject private var lang = Lang.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group(L("Language", "언어")) {
                HStack {
                    Text(L("App language", "앱 언어"))
                    Spacer()
                    Picker("", selection: Binding(get: { lang.current }, set: { model.setLanguage($0) })) {
                        ForEach(Language.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            group(L("Checking", "확인")) {
                MinutesRow(label: L("Check every", "확인 주기"), hint: L("How often to look at the inbox", "inbox를 얼마나 자주 확인할지"), value: model.checkInterval,
                           range: 1...60) { model.number("check_interval_minutes", $0) }
                Divider()
                MinutesRow(label: L("Wait after writing", "작성 후 대기"), hint: L("Process only once the file has been left alone this long", "파일을 마지막으로 고친 뒤 이만큼 지나야 처리"), value: model.quietMinutes,
                           range: 1...60) { model.number("quiet_minutes", $0) }
                Divider()
                MinutesRow(label: L("Hold the last block", "마지막 블록 보류"), hint: L("The last block waits until it hasn't changed this long", "마지막 블록은 이만큼 변화가 없어야 처리"), value: model.holdMinutes,
                           range: 0...120) { model.number("last_block_hold_minutes", $0) }
            }
            group(L("Sorting", "정리")) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Needs-review threshold", "확인 필요 기준"))
                        Text(L("Below this confidence, items are marked for review", "confidence가 이보다 낮으면 review 표시")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int((model.threshold * 100).rounded()))%").monospacedDigit().frame(minWidth: 40, alignment: .trailing)
                    Stepper("", value: Binding(get: { model.threshold },
                                               set: { model.number("review_threshold", ($0 * 100).rounded() / 100) }),
                            in: 0.5...0.95, step: 0.05).labelsHidden()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("dry-run")
                        Text(L("Write nothing to the vault; only leave proposals in review/dry-run-<date>.md", "vault에 쓰지 않고 review/dry-run-날짜.md에 제안만 남김")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.dryRun }, set: { _ in model.toggleDryRun() }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Collect notes only on this Mac", "이 Mac은 메모만 받기"))
                        Text(L("For a vault synced across Macs: this Mac adds quick notes to the inbox and another Mac sorts them", "여러 Mac이 같은 vault를 동기화할 때: 이 Mac은 빠른 메모만 inbox에 넣고, 정리는 다른 Mac이 해요")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.collectOnly }, set: { model.setCollectOnly($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            group(L("Locations", "위치")) {
                LocationRow(symbol: "externaldrive", label: "vault",
                            value: (model.vault as NSString).abbreviatingWithTildeInPath, change: model.chooseVault)
                Divider()
                LocationRow(symbol: "tray.and.arrow.down", label: "inbox", value: model.inboxRel, change: model.chooseInbox)
                Divider()
                LocationRow(symbol: "terminal", label: "codex", value: model.codexPath, change: model.chooseCodex)
            }
            group(L("Opening", "열기")) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Open notes with", "노트 열 앱"))
                        Text(L("Recent items, bubbles and shortcuts open in this app", "최근 처리·말풍선·바로가기를 누르면 이 앱으로 열어요")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu(openWithLabel) {
                        Button(L("Default app (macOS setting)", "기본 앱 (macOS 설정)")) { model.setConfig("open_with", "") }
                        ForEach(model.suggestedEditors, id: \.self) { app in
                            Button(FileManager.default.displayName(atPath: app.path)) { model.setConfig("open_with", app.path) }
                        }
                        Divider()
                        Button(L("Other App…", "다른 앱…"), action: model.chooseOpenWith)
                    }
                    .fixedSize()
                }
            }
            group(L("Shortcuts", "단축키")) {
                ForEach(Array(Shortcut.allCases.enumerated()), id: \.element) { index, shortcut in
                    if index > 0 { Divider() }
                    ShortcutRow(shortcut: shortcut)
                }
            }
            UpdateSection(updater: model.updater)
            Text(L("Changes are saved right away and apply from the next check.", "변경은 바로 저장되고, 다음 확인부터 적용됩니다.")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .id(lang.current)
        .environment(\.locale, lang.current.locale)
    }

    var openWithLabel: String {
        model.openWith.isEmpty ? L("Default app", "기본 앱") : FileManager.default.displayName(atPath: model.openWith)
    }

    func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            Card { VStack(spacing: 8) { content() } }
        }
    }
}

struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: L("Updates", "업데이트"))
            Card {
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sift \(Updater.installedVersion)")
                            Text(message).font(.caption).foregroundStyle(color).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        switch updater.status {
                        case .available:
                            Button(L("Install", "설치")) { Task { await updater.install() } }.buttonStyle(.borderedProminent)
                        case .checking, .installing:
                            ProgressView().controlSize(.small)
                        default:
                            Button(L("Check", "확인")) { Task { await updater.check() } }
                        }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("Check automatically", "자동으로 확인"))
                            Text(L("Asks GitHub for the latest version once a day, nothing else", "하루 한 번 GitHub에 최신 버전만 물어봐요")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $updater.auto).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    var message: String {
        switch updater.status {
        case .idle:
            return Updater.bundleVersion == Updater.installedVersion ? L("Updates are installed after their signature is checked", "업데이트는 서명을 확인한 뒤 설치해요")
                : L("app", "앱") + " \(Updater.bundleVersion) · core \(Updater.installedVersion)"
        case .checking: return L("Checking…", "확인 중…")
        case .upToDate: return L("You're up to date", "최신 버전이에요")
        case .available(let v, let app):
            return L("\(v) is available", "\(v) 업데이트가 있어요")
                + (app ? L(". The app changes too, so it relaunches after installing", ". 앱도 바뀌어 설치 후 다시 실행돼요") : L(". No relaunch needed", ". 다시 실행할 필요 없어요"))
        case .installing(let step): return step
        case .done(let text): return text
        case .failed(let text): return text
        }
    }

    var color: Color {
        switch updater.status {
        case .available, .done: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

struct LocationRow: View {
    let symbol: String
    let label: String
    let value: String
    let change: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(label).font(.caption.weight(.medium)).frame(width: 38, alignment: .leading)
            Text(value.isEmpty ? "-" : value).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
            Button(L("Change…", "변경…"), action: change).controlSize(.small)
        }
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    @ObservedObject var shortcuts = Shortcuts.shared
    @ObservedObject private var lang = Lang.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.needsTools {
                HStack(spacing: 10) {
                    Image(systemName: "hammer.fill").font(.title3).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Command Line Tools needed", "Command Line Tools가 필요해요")).font(.callout.weight(.semibold))
                        Text(L("The sorting engine runs on macOS's python3. Once installed, it starts within a minute", "정리 엔진이 macOS의 python3로 돌아가요. 설치하면 1분 안에 시작해요"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Install…", "설치…"), action: model.installTools).buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if model.needsSetup {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").font(.title3).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.vault.isEmpty ? L("First choose your notes folder (vault) and inbox", "먼저 노트 폴더(vault)와 inbox를 정해 주세요")
                                                 : L("Inbox file not found: \(model.inboxRel)", "inbox 파일이 없어요: \(model.inboxRel)"))
                            .font(.callout.weight(.semibold))
                        Text(L("Choose the vault, then pick or create an inbox file", "vault를 고른 뒤 inbox 파일을 고르거나 새로 만들어요")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.vault.isEmpty ? L("Choose…", "정하기…") : L("Choose Inbox…", "inbox 고르기…"),
                           action: model.vault.isEmpty ? model.chooseVault : model.chooseInbox)
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let issue = model.codexIssue {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill").font(.title3).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue == "login" ? L("Log in to Codex", "Codex 로그인이 필요해요") : L("Codex CLI not found", "Codex CLI를 찾을 수 없어요"))
                            .font(.callout.weight(.semibold))
                        Text(issue == "login" ? L("Sorting runs on Codex. Log in from Terminal and sorting picks up right away", "정리는 Codex로 해요. 터미널에서 로그인하면 바로 이어서 정리해요")
                                              : L("Sorting needs the Codex CLI. If it's installed, choose its path", "정리에 Codex CLI가 필요해요. 설치했다면 경로를 골라 주세요"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if issue == "login" {
                        Button(L("Log In…", "로그인…"), action: model.codexLogin).buttonStyle(.borderedProminent)
                    } else {
                        VStack(spacing: 4) {
                            Button(L("How to Install", "설치 안내")) { NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex")!) }
                                .buttonStyle(.borderedProminent)
                            Button(L("Path…", "경로…"), action: model.chooseCodex).controlSize(.small)
                        }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if model.state == "blocked" && !model.collectOnly {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "macbook.and.iphone").font(.title3).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("\(model.otherProcessor ?? "Another Mac") sorts this vault", "\(model.otherProcessor ?? "다른 Mac")이(가) 이 vault를 정리하고 있어요"))
                                .font(.callout.weight(.semibold))
                            Text(L("Two Macs sorting the same synced inbox would file notes twice, so this Mac waits. Quick notes still go into the inbox.",
                                   "두 Mac이 동기화된 같은 inbox를 정리하면 두 번 정리돼서, 이 Mac은 기다려요. 빠른 메모는 그대로 inbox에 들어가요."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Spacer()
                        Button(L("Sort on This Mac", "이 Mac에서 정리"), action: model.sortHere)
                        Button(L("Collect Notes Only", "메모만 받기")) { model.setCollectOnly(true) }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let err = model.lastError, model.state == "error" {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            today
            reviewList
            recent
            controls
            links
            footer
        }
        .padding(14)
        .frame(width: 440)
    }

    var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(model.stateColor.opacity(0.16))
                Image(systemName: model.symbol).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.stateColor)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.stateLabel).font(.system(size: 15, weight: .semibold))
                    if model.dryRun {
                        Text("DRY-RUN").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                    }
                }
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: "tray").font(.caption2)
                    Text("inbox \(model.inboxBlocks)").font(.caption.monospacedDigit())
                }
                .foregroundStyle(model.inboxBlocks > 0 ? Color.primary : Color.secondary)
                if let last = model.lastRun {
                    (lang.current == .ko ? Text("\(last, style: .relative) 전") : Text("\(last, style: .relative) ago"))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help(L("Last check", "마지막 확인"))
                }
            }
        }
    }

    var today: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: L("Today", "오늘"))
            Card {
                HStack(spacing: 0) {
                    Stat(symbol: "square.stack.3d.up", label: L("blocks", "블록"), value: model.today["blocks"] ?? 0, color: .gray)
                    Stat(symbol: "checkmark.circle", label: "todo", value: model.today["todos"] ?? 0, color: .blue)
                    Stat(symbol: "doc.text", label: L("notes", "문서"), value: model.today["docs"] ?? 0, color: .indigo)
                    Stat(symbol: "calendar", label: L("calendar", "일정 후보"), value: model.today["calendar"] ?? 0, color: .red)
                    Stat(symbol: "exclamationmark.bubble", label: "review", value: model.today["review"] ?? 0, color: .orange)
                }
            }
        }
    }

    @ViewBuilder var reviewList: some View {
        let items = model.pendingReview
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: L("Needs Review · \(items.count)", "확인 필요 · \(items.count)"),
                             trailing: L("✓ when checked", "확인하면 ✓"))
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(items) { item in
                            RecentRow(item: item, open: { model.openReview(item) },
                                      resort: { model.resort(item) }, dismiss: { model.dismissReview(item) })
                        }
                    }
                    .padding(3)
                }
                .frame(height: min(CGFloat(items.count) * 52 + 6, 160))
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: L("Recent", "최근 처리"), trailing: model.recent.isEmpty ? nil : L("Click to open", "클릭하면 열기"))
            if model.recent.isEmpty {
                Card {
                    Text(L("Nothing sorted yet", "아직 처리한 항목이 없어요")).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.recent) { item in
                            RecentRow(item: item, open: {
                                if let first = item.targets.first { model.openNote(first) }
                            }, resort: item.entry.isEmpty ? nil : { model.resort(item) })
                        }
                    }
                    .padding(3)
                }
                .frame(minHeight: 200, maxHeight: 380)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    var controls: some View {
        HStack(spacing: 8) {
            Button { model.runNow() } label: {
                Label(L("Process Now", "지금 처리"), systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help(L("Skip the wait and the last-block hold, and process right away", "5분 대기와 마지막 블록 보류를 건너뛰고 바로 처리"))
            .disabled(model.collectOnly || model.state == "blocked")
            Button { model.togglePause() } label: {
                Label(model.paused ? L("Resume", "재개") : L("Pause", "일시정지"), systemImage: model.paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Toggle("dry-run", isOn: Binding(get: { model.dryRun }, set: { _ in model.toggleDryRun() }))
                .toggleStyle(.switch).controlSize(.small)
                .help(L("When on, nothing is written to the vault; proposals go to review/dry-run-<date>.md", "켜면 vault에 쓰지 않고 review/dry-run-날짜.md에 제안만 남김"))
        }
        .controlSize(.large)
    }

    var links: some View {
        Card {
            HStack(spacing: 2) {
                LinkButton(symbol: "square.and.pencil", label: L("Note", "메모") + " \(shortcuts.key(.quickNote).shortLabel)") { QuickNote.shared.show(model) }
                LinkButton(symbol: "tray.and.arrow.down", label: "inbox") { model.openFile(model.inbox) }
                LinkButton(symbol: "checklist", label: "todo") {
                    model.openFile((model.assistantDir as NSString).appendingPathComponent("todo.md"))
                }
                LinkButton(symbol: "calendar", label: L("Calendar", "일정")) {
                    model.openFile((model.assistantDir as NSString).appendingPathComponent("calendar-queue.md"))
                }
                LinkButton(symbol: "exclamationmark.bubble", label: "review") {
                    model.openReview()
                }
                LinkButton(symbol: "list.bullet.rectangle", label: L("Log", "로그")) { model.openFile(model.todayLog()) }
            }
        }
        .padding(.top, -4)
    }

    var footer: some View {
        HStack {
            if let flash = model.flash {
                Label(flash, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            if case .available(let version, _) = model.updater.status {
                Button { SettingsWindow.shared.show(model) } label: {
                    Label(L("Update to \(version)", "\(version) 업데이트"), systemImage: "arrow.down.circle.fill").font(.caption)
                }
                .buttonStyle(.borderless).foregroundStyle(.green)
            }
            Button { SettingsWindow.shared.show(model) } label: {
                Label(L("Settings…", "설정…"), systemImage: "gearshape").font(.caption)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            Button { NSApp.terminate(nil) } label: {
                Label(L("Quit", "종료"), systemImage: "power").font(.caption)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.2), value: model.flash)
        .id(lang.current)
        .environment(\.locale, lang.current.locale)
    }
}

@main
struct SiftApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(systemName: model.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
