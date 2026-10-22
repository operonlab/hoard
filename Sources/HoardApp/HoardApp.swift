import AppKit
import Quartz
import SwiftUI
import ScanCore

@main
struct HoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        // A worktree build (scripts/make-app.sh gives it the .dev bundle id) keeps its caches, history
        // and protection store apart from the owner's; set before anything reads HoardStorage.
        if Bundle.main.bundleIdentifier == "com.operonlab.hoard.dev" { HoardStorage.folderName = "Hoard Dev" }
    }

    var body: some Scene {
        WindowGroup("Hoard") {
            MainView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                // Coming back from System Settings: pick up a permission granted meanwhile.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshAccess()
                    model.refreshProtection()
                }
                .task {
                    delegate.model = model
                    LaunchOptions.apply(to: model)
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(model: model) }
        Settings { SettingsView() }
    }
}

/// Command-line options, used by scripts/shoot.sh and for manual testing.
enum LaunchOptions {
    /// For renders: run 找出相似的照片 once a tree is in, the same as pressing the button.
    static let findSimilar = CommandLine.arguments.contains("--find-similar")

    /// For renders: a flag below opened a sheet, which scripts/shoot.sh's quit must not be held by.
    static let opensSheet = ["--protect-sheet", "--unprotect-alert", "--uninstall-sheet"]
        .contains { CommandLine.arguments.contains($0) }

    static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    @MainActor static func apply(to model: AppModel) {
        let args = CommandLine.arguments
        if let view = value("--view").flatMap(Int.init).flatMap(ViewKind.init(rawValue:)) { model.view = view }
        if args.contains("--largest") { model.view = .largest }
        if args.contains("--list") { model.mapMode = .list }
        if let path = value("--scan") {
            model.open(path, scope: value("--scope"), select: value("--select"))
        } else if !args.contains("--fresh"), let last = UserDefaults.standard.string(forKey: RootMemory.lastRootKey),
                  FileManager.default.fileExists(atPath: last) {
            // Second launch onwards: reopen the last location from its cache (§2.1).
            model.open(last)
        }
        // For renders: open the add-protection sheet on --select once the scan and the list are in.
        if let kind = value("--protect-sheet").flatMap({ $0 == "lock" ? ProtectionKind.lock : $0 == "guard" ? .guarded : nil }) {
            whenReady(model) { if let id = model.selection { model.requestProtect(id, kind: kind) } }
        }
        // For renders: show the 解除保護 alert for the entry with this name. The render closes it as
        // cancelled, which removes nothing.
        if let name = value("--unprotect-alert") {
            whenReady(model) { if let row = model.protection.rows.first(where: { $0.name == name }) { model.confirmUnprotect(row) } }
        }
        // For renders: open the 解除安裝 sheet for the App with this name once the App list is in (with
        // --view 8). The sheet only shows the plan; the render closes it as cancelled.
        if let name = value("--uninstall-sheet") {
            Task { @MainActor in
                for _ in 0..<300 where model.appReport?.apps.contains(where: { $0.name == name }) != true {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if let app = model.appReport?.apps.first(where: { $0.name == name }) { model.requestUninstall(app) }
            }
        }
        if args.contains("--whats-new") {
            model.whatsNew = WhatsNew.releases.filter { $0.version == WhatsNew.currentVersion }
        } else if !args.dropFirst().contains(where: { $0.hasPrefix("--") }) {
            let defaults = UserDefaults.standard
            let versions = WhatsNewPolicy.versionsToShow(
                current: WhatsNew.currentVersion, lastSeen: defaults.string(forKey: WhatsNew.seenKey),
                hasPriorUse: defaults.string(forKey: RootMemory.lastRootKey) != nil,
                available: WhatsNew.releases.map(\.version))
            if versions.isEmpty {
                WhatsNew.recordSeen()
            } else if model.trashRequest == nil && model.uninstallRequest == nil && model.accessSheet == nil &&
                        model.protectRequest == nil && model.alert == nil {
                model.whatsNew = versions.compactMap { version in
                    WhatsNew.releases.first { $0.version == version }
                }
            }
        }
    }

    /// Runs `action` once a tree is installed and the protection list has loaded (gives up after 30 s).
    @MainActor static func whenReady(_ model: AppModel, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            for _ in 0..<150 where model.tree == nil || model.scanning || !model.protection.loaded {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            action()
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        switch LaunchOptions.value("--appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let out = LaunchOptions.value("--render-to") {
            let delay = LaunchOptions.value("--render-after").flatMap(Double.init) ?? 20
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.render(to: out) }
        }
        if LaunchOptions.opensSheet {
            NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitClosingSheets(_:withReply:)),
                                                         forEventClass: AEEventClass(kCoreEventClass),
                                                         andEventID: AEEventID(kAEQuitApplication))
        }
        // A mouse's back and forward side buttons (buttons 4 and 5; the MX Master's thumb buttons) step
        // through the scope history like the toolbar arrows, as they do in browsers and Finder. Only over
        // the main window and never while a sheet is up; the matching button-up is swallowed too.
        mouseNavigation = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                let back = event.buttonNumber == 3
                guard back || event.buttonNumber == 4, let window = event.window, let model = self?.model,
                      !(window is NSPanel), window.attachedSheet == nil,
                      window.identifier?.rawValue.contains("Settings") != true else { return false }
                if event.type == .otherMouseDown { back ? model.goBack() : model.goForward() }
                return true
            }
            return handled ? nil : event
        }
    }

    private var mouseNavigation: Any?

    /// An open sheet holds termination: close it as cancelled (never confirmed).
    private static func closeSheetsAsCancelled() {
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) } }
    }

    /// The quit Apple event of a render launch: cancel the sheet the render opened, then quit as usual
    /// once it has left the window. `endSheet` does not close a SwiftUI sheet; clearing its request does.
    /// While a lock or guard is being added the quit is refused, as the sheet itself would refuse it.
    @objc private func quitClosingSheets(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        if let model, model.protectionAddsRunning > 0 {
            reply.setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: AEKeyword(keyErrorNumber))
            return
        }
        model?.protectRequest = nil
        model?.uninstallRequest = nil
        Self.closeSheetsAsCancelled()
        func terminateWhenClosed(_ tries: Int) {
            if NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) { NSApp.terminate(nil); return }
            // A sheet this does not cancel (the user opened it) still holds the quit.
            guard tries > 0 else { NSLog("Hoard 有表單還開著，不結束"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { terminateWhenClosed(tries - 1) }
        }
        terminateWhenClosed(30)
    }

    /// Draws this app's own window into a PNG and quits. Needs no Screen Recording permission and
    /// never touches another Hoard instance. Materials (sidebar, toolbar glass) may draw flatter
    /// than on screen; layout, copy and content colors are faithful.
    @MainActor private static func render(to path: String) {
        defer {
            // Close an open sheet as cancelled, and do not wait on it.
            closeSheetsAsCancelled()
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
        let candidates = NSApp.windows.filter { $0.isVisible && !$0.isSheet && $0.contentView != nil }
        let isSettings: (NSWindow) -> Bool = { $0.identifier?.rawValue.contains("Settings") == true }
        let wantSettings = CommandLine.arguments.contains("--settings")
        guard let window = candidates.first(where: { isSettings($0) == wantSettings }) ?? candidates.first,
              let frameView = window.contentView?.superview else {
            FileHandle.standardError.write(Data("render: no window\n".utf8))
            return
        }
        let bounds = frameView.bounds
        guard var rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        // A sheet is a window of its own; draw it over the parent where it sits on screen.
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview,
           let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds),
           let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
            canvas.size = bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            rep.draw(in: NSRect(origin: .zero, size: bounds.size))
            let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
            let frame = NSRect(origin: origin, size: sheetView.bounds.size)
            // Alert panels have rounded corners that the cached bitmap fills in.
            if String(describing: type(of: sheet)).contains("Alert") {
                NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22).addClip()
            }
            sheetRep.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            rep = canvas
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("rendered \(path)")
        } catch {
            FileHandle.standardError.write(Data("render: \(error)\n".utf8))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    weak var model: AppModel?
    private var quitReplied = false
    private static let quitSaveLimit: TimeInterval = 20

    /// Quitting saves the snapshot and a history version off the main thread (a whole-disk tree
    /// takes seconds), then lets the app go. After `quitSaveLimit` it goes anyway; the writes are
    /// atomic, so an unfinished one leaves the previous file in place.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let stopGuardian = model?.stopGuardian()
        let work = model?.quitSaveWork()
        // Quitting does not wait for the guardian: it may be waiting for the registry lock or finishing a
        // vault copy. A copy cut short can leave the store unlocked; the next guardian start re-locks it.
        if let stopGuardian { DispatchQueue.global(qos: .utility).async { stopGuardian() } }
        guard let work else { return .terminateNow }
        // Replies go through run-loop sources, not the main dispatch queue: `terminate` may be called
        // from inside a main-queue block (the --render-to path), and the main queue is not drained
        // again until that block returns, so a DispatchQueue.main reply would never arrive.
        let limit = Timer(timeInterval: Self.quitSaveLimit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.replyToQuit(saved: false) }
        }
        RunLoop.main.add(limit, forMode: .common)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            self.performSelector(onMainThread: #selector(self.quitSaveFinished), with: nil, waitUntilDone: false,
                                 modes: [RunLoop.Mode.common.rawValue])
        }
        return .terminateLater
    }

    @objc private func quitSaveFinished() { replyToQuit(saved: true) }

    private func replyToQuit(saved: Bool) {
        guard !quitReplied else { return }
        quitReplied = true
        if !saved {
            NSLog("Hoard 結束時的快取與比較基準在 %.0f 秒內沒有寫完，直接結束", Self.quitSaveLimit)
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // Quick Look looks for its controller along the responder chain, which ends at the app delegate.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = QuickLook.shared }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @AppStorage(TextScale.key) private var scaleIndex = 1

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        CommandGroup(after: .appInfo) {
            Button("檢查更新…") { model.updateCheckShown = true }
        }
        CommandGroup(replacing: .help) {
            Button("Hoard 的新功能") {
                model.whatsNew = WhatsNew.releases.filter { $0.version == WhatsNew.currentVersion }
            }
            Button("「系統資料」是什麼？") {
                let language = Bundle.main.preferredLocalizations.first
                let name: String
                switch language {
                case "zh-Hant": name = "system-data.zh-Hant.md"
                case "ja": name = "system-data.ja.md"
                case "ko": name = "system-data.ko.md"
                default: name = "system-data.md"
                }
                NSWorkspace.shared.open(URL(string: "https://github.com/operonlab/hoard/blob/main/docs/\(name)")!)
            }
            Divider()
            Button("在 GitHub 上查看 Hoard") {
                NSWorkspace.shared.open(URL(string: "https://github.com/operonlab/hoard")!)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("選擇資料夾…") { FolderPicker.choose(model) }.keyboardShortcut("o")
            Button("掃描整個磁碟「\(Places.diskName)」") { model.choose(Places.disk) }
            Button("掃描家目錄「\(Places.userName)」") { model.choose(Places.home) }
            Divider()
            Button("匯出為 CSV…") { model.exportCSV() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExportCSV)
            Divider()
            Button("重新掃描") { model.rescan() }
                .keyboardShortcut("r")
                .disabled(model.rootPath == nil || model.scanning)
            Button("停止掃描") { model.stopScan() }
                .keyboardShortcut(".")
                .disabled(!model.scanning)
            Divider()
            Button("快速查看") { model.quickLook(model.selectedIDs) }
                .keyboardShortcut("y")
                .disabled(model.selectedIDs.isEmpty)
            let trashBlocked = model.selectedIDs.lazy.compactMap { model.trashBlockReason($0) }.first
            Button("丟到垃圾桶…") { model.requestTrash(model.selectedIDs) }
                .keyboardShortcut(.delete)
                .disabled(model.selectedIDs.isEmpty || trashBlocked != nil)
                .help(trashBlocked ?? "")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("還原丟到垃圾桶") { model.undoTrash() }
                .keyboardShortcut("z")
                .disabled(!model.canUndoTrash)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            ForEach(ViewKind.allCases) { kind in
                Button(kind.title) { model.view = kind }
                    .keyboardShortcut(KeyEquivalent(Character("\(kind.rawValue)")), modifiers: .command)
                    .disabled(model.tree == nil && kind.needsTree)
            }
            Divider()
            Button("以圖顯示") { model.view = .map; model.mapMode = .graph }
                .keyboardShortcut("1", modifiers: [.command, .control])
                .disabled(model.tree == nil)
            Button("以清單顯示") { model.view = .map; model.mapMode = .list }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .disabled(model.tree == nil)
            Divider()
            Button("放大文字") { scaleIndex = min(TextScale.steps.count - 1, scaleIndex + 1) }
                .keyboardShortcut("+")
                .disabled(scaleIndex >= TextScale.steps.count - 1)
            Button("縮小文字") { scaleIndex = max(0, scaleIndex - 1) }
                .keyboardShortcut("-")
                .disabled(scaleIndex <= 0)
            Button("實際大小") { scaleIndex = 1 }
                .keyboardShortcut("0")
                .disabled(scaleIndex == 1)
            Divider()
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("拷貝路徑") { model.copyPaths([model.focus]) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.tree == nil)
            Button("搜尋") { SearchFocus.activate() }
                .keyboardShortcut("f")
                .disabled(model.tree == nil)
        }
        CommandMenu("前往") {
            Button("返回") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("前進") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Button("上一層") { model.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!model.canGoUp)
            Button("打開") { if let id = model.selection { model.enter(id) } }
                .keyboardShortcut(.downArrow)
                .disabled(model.selection == nil)
        }
    }
}

/// ⌘F: `.searchable` has no focus API before macOS 15, so start the toolbar search item directly.
enum SearchFocus {
    @MainActor static func activate() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let toolbar = window.toolbar else { return }
        if let item = toolbar.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        } else if let field = findSearchField(in: window.contentView?.superview) {
            window.makeFirstResponder(field)
        }
    }

    private static func findSearchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews { if let found = findSearchField(in: sub) { return found } }
        return nil
    }
}

enum FolderPicker {
    @MainActor static func choose(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "掃描")
        panel.begin { response in
            if response == .OK, let url = panel.url { model.choose(url.path) }
        }
    }
}
