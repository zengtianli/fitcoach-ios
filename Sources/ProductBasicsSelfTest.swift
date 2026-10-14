import SwiftUI
#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
import ObjectiveC
#endif

/// Runs inside the actual product executable, before Session, Keychain or production configuration is constructed.
@MainActor
enum ProductBasicsSelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--ui-self-test") || CommandLine.arguments.contains("--ui-self-test-readback") }
    static var readback: Bool { CommandLine.arguments.contains("--ui-self-test-readback") }
    static var root: URL {
        #if os(macOS)
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["FITCOACH_BASICS_OUT"]!)
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("product-basics")
        #endif
    }
    static let suite = "test.tianli.fitcoach.product-basics"
    static func launch() {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["FITCOACH_BASICS_OUT"] != nil,
              Bundle.main.bundleIdentifier?.hasPrefix("test.tianli.fitcoach.") == true else { exit(2) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.mainMenu = NSMenu()
        Task { await run(); exit(0) }
        RunLoop.main.run()
        #else
        #if targetEnvironment(simulator)
        BasicsTestApp.main()
        #else
        exit(2) // This isolated entrance never writes preferences on a physical phone.
        #endif
        #endif
    }

    static func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }

    static func sync(_ config: AppConfiguration) async -> Bool {
        await withCheckedContinuation { continuation in
            config.reconcile { error in continuation.resume(returning: error == nil) }
        }
    }

    static func write(_ value: Any, _ filename: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(filename), options: .atomic)
    }

    static func run() async {
        do {
            if !readback { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let support = root.appendingPathComponent("support"), cloud = root.appendingPathComponent("cloud")
            setenv("APP_LIFECYCLE_SUPPORT_DIR", support.path, 1)
            setenv("APP_LIFECYCLE_CLOUD_DIR", cloud.path, 1)
            let defaults = UserDefaults(suiteName: suite)!
            if readback {
                defaults.synchronize()
                try write(["settings.persisted_readback": defaults.string(forKey: "fitcoach.baseURL") == "https://restored.invalid",
                           "shortcuts.persisted_readback": defaults.object(forKey: "appShortcuts.refresh.enabled") == nil || defaults.bool(forKey: "appShortcuts.refresh.enabled"),
                           "updates.persisted_options": AppUpdatePreferences.options(Bundle.main.bundleIdentifier!).automaticCheck], "readback.json")
                #if os(iOS)
                LaneSignal.ready("product-basics-readback")
                #endif
                return
            }
            defaults.removePersistentDomain(forName: suite)
            defaults.set("https://original.invalid", forKey: "fitcoach.baseURL")
            defaults.set("private-cookie-sentinel", forKey: "fitcoach.coachCookie")
            defaults.set(true, forKey: "appShortcuts.refresh.enabled")
            defaults.set(["key": "r", "modifiers": 1 << 20] as [String: Any], forKey: "appShortcuts.refresh.binding")
            let config = MobileProductLifecycle.makeConfiguration(defaults: defaults)
            let model = FitCoachSettingsModel(configuration: config, channel: MobileProductLifecycle.channel, defaults: defaults)
            var checks: [String: Bool] = [:]
            model.showing = true
            let rendered = try render(model)
            model.server = "https://saved.invalid"
            model.saveServer()
            checks["settings.interaction"] = rendered && model.showing && defaults.string(forKey: "fitcoach.baseURL") == model.server
            let exported = try config.exportData()
            try exported.write(to: root.appendingPathComponent("export.json"))
            model.server = "http://invalid.example"
            model.saveServer()
            let invalidServerPreserved = defaults.string(forKey: "fitcoach.baseURL") == "https://saved.invalid"
            do { try config.importData(Data("{broken".utf8)); checks["settings.error_preserves_data"] = false }
            catch { let after = try config.exportData(); checks["settings.error_preserves_data"] = invalidServerPreserved && after == exported }
            checks["settings.credentials_excluded"] = !String(decoding: exported, as: UTF8.self).contains("private-cookie-sentinel")
            checks["icloud.mac_fields_retained_on_touch_client"] = String(decoding: exported, as: UTF8.self).contains("defaults.appShortcuts.refresh.binding")
            model.showing = false
            checks["settings.closed"] = !model.showing

            #if os(macOS)
            model.shortcuts.installMenu()
            var refreshes = 0
            let token = NotificationCenter.default.addObserver(forName: .fitcoachReload, object: nil, queue: .main) { _ in refreshes += 1 }
            if let item = model.shortcuts.menuItem, let action = item.action {
                checks["shortcuts.action_path"] = NSApp.sendAction(action, to: item.target, from: item) && refreshes == 1
            } else { checks["shortcuts.action_path"] = false }
            model.setShortcutEnabled(false)
            let disabled = model.shortcuts.menuItem?.keyEquivalent == "" && !model.shortcuts.enabled
            model.setShortcutEnabled(true)
            checks["shortcuts.disable_restore"] = disabled && model.shortcuts.menuItem?.keyEquivalent == "r" && model.shortcuts.enabled
            model.shortcutKey = "q"; model.saveShortcut()
            let reserved = model.shortcuts.binding.key == "r"
            let conflict = NSMenuItem(title: "占用", action: nil, keyEquivalent: "k"); conflict.keyEquivalentModifierMask = .command
            NSApp.mainMenu?.addItem(conflict)
            model.shortcutKey = "k"; model.saveShortcut()
            checks["shortcuts.conflict_or_reserved_keys"] = reserved && model.shortcuts.binding.key == "r" && model.message.contains("已使用")
            model.shortcutKey = model.shortcuts.binding.key
            NSApp.mainMenu?.removeItem(conflict)
            NotificationCenter.default.removeObserver(token)
            #endif

            model.lifecycle.setCloudEnabled(true)
            let pushed = await sync(config)
            let cloudFile = cloud.appendingPathComponent("fitcoach-mobile.json")
            let peerDefaults = UserDefaults(suiteName: suite + ".peer")!
            peerDefaults.removePersistentDomain(forName: suite + ".peer")
            setenv("APP_LIFECYCLE_SUPPORT_DIR", root.appendingPathComponent("peer-support").path, 1)
            let peer = MobileProductLifecycle.makeConfiguration(defaults: peerDefaults)
            peer.setEnabled(true)
            let pulled = await sync(peer)
            let received = peerDefaults.string(forKey: "fitcoach.baseURL") == "https://saved.invalid"
            peerDefaults.set("https://remote.invalid", forKey: "fitcoach.baseURL")
            let peerPushed = await sync(peer)
            let remoteReceived = await sync(config)
            checks["icloud.push_pull"] = pushed && pulled && received && peerPushed && remoteReceived && defaults.string(forKey: "fitcoach.baseURL") == "https://remote.invalid"
            peer.setEnabled(false)
            setenv("APP_LIFECYCLE_SUPPORT_DIR", support.path, 1)
            let beforeOffline = try config.exportData()
            let goodCloud = try Data(contentsOf: cloudFile)
            unsetenv("APP_LIFECYCLE_CLOUD_DIR")
            let unavailable = !(await sync(config))
            let localRetained = try config.exportData() == beforeOffline
            model.server = "https://offline.invalid"; model.saveServer()
            let pendingOffline = !(await sync(config))
            checks["icloud.unavailable_local_fallback"] = unavailable && pendingOffline && localRetained && defaults.string(forKey: "fitcoach.baseURL") == "https://offline.invalid"
            // Keep the transport unavailable until the corrupt fixture is in place. Otherwise a legitimate
            // background sync can finish in between restoring the transport and corrupting its file.
            try Data("{broken".utf8).write(to: cloudFile, options: .atomic)
            setenv("APP_LIFECYCLE_CLOUD_DIR", cloud.path, 1)
            let badRejected = !(await sync(config))
            let corruptPreserved = defaults.string(forKey: "fitcoach.baseURL") == "https://offline.invalid"
            try goodCloud.write(to: cloudFile, options: .atomic)
            let recovered = await sync(config)
            checks["icloud.corrupt_remote_rejected"] = badRejected
            checks["icloud.corrupt_remote_keeps_local"] = corruptPreserved
            checks["icloud.recovered_pending_import"] = recovered && defaults.string(forKey: "fitcoach.baseURL") == "https://offline.invalid"
            checks["icloud.conflict_or_corrupt_recovery"] = badRejected && corruptPreserved && recovered && defaults.string(forKey: "fitcoach.baseURL") == "https://offline.invalid"
            let beforeDisable = try config.exportData(), cloudBeforeDisable = try Data(contentsOf: cloudFile)
            model.lifecycle.setCloudEnabled(false)
            let afterDisable = try config.exportData(), cloudAfterDisable = try Data(contentsOf: cloudFile)
            checks["icloud.disable_preserves_data"] = !config.enabled && afterDisable == beforeDisable && cloudAfterDisable == cloudBeforeDisable
            let dataBeforeUpdate = try config.exportData()
            let identity = Bundle.main.bundleIdentifier!
            #if os(macOS)
            let feed = cloud.appendingPathComponent("TianliApps/Updates/\(identity)/private/release.json")
            try FileManager.default.createDirectory(at: feed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let manifest: [String: Any] = ["version": "99.0", "build": "999", "bundle_id": identity, "channel": "private", "filename": "fixture.zip", "sha256": String(repeating: "a", count: 64), "size_bytes": 1, "installation": "manual-bundle"]
            let feedData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try feedData.write(to: feed)
            #else
            try BasicsStoreTransport.install()
            BasicsStoreTransport.mode = .valid
            #endif
            model.lifecycle.checkForUpdates()
            let completed = await wait { !model.lifecycle.checking }
            checks["updates.check_result"] = completed && model.lifecycle.release?.version == "99.0" && model.lifecycle.updateStatus.contains("新版本")
            let updateEntry = model.lifecycle.updateURL
            #if os(macOS)
            try Data("{broken".utf8).write(to: feed, options: .atomic)
            #else
            BasicsStoreTransport.mode = .corrupt
            #endif
            model.lifecycle.checkForUpdates()
            let failed = await wait { !model.lifecycle.checking }
            let badFeed = failed && model.lifecycle.release == nil && model.lifecycle.updateStatus.contains("未完成")
            #if os(macOS)
            try FileManager.default.removeItem(at: feed)
            #else
            BasicsStoreTransport.mode = .unavailable
            #endif
            model.lifecycle.checkForUpdates()
            let failedAgain = await wait { !model.lifecycle.checking }
            let unavailableFeed = failedAgain && model.lifecycle.release == nil && model.lifecycle.updateStatus.contains("未完成")
            #if os(macOS)
            try feedData.write(to: feed)
            #else
            BasicsStoreTransport.mode = .valid
            #endif
            model.lifecycle.checkForUpdates()
            let updateRecovered = await wait { !model.lifecycle.checking }
            checks["updates.failure_recovery"] = badFeed && unavailableFeed && updateRecovered && model.lifecycle.release?.version == "99.0"
            var options = AppUpdatePreferences.options(identity); options.automaticCheck = true; options.intervalHours = 48
            try AppUpdatePreferences.save(options, identity)
            model.setAutomaticCheck(false)
            let optionOff = !AppUpdatePreferences.options(identity).automaticCheck
            model.setAutomaticCheck(true)
            #if os(macOS)
            checks["updates.options_or_store_entry"] = optionOff && AppUpdatePreferences.options(identity).automaticCheck && AppUpdatePreferences.options(identity).intervalHours == 48 && updateEntry?.lastPathComponent == "fixture.zip"
            #else
            checks["updates.options_or_store_entry"] = updateEntry?.absoluteString == "https://apps.apple.com/app/id6806698109" && BasicsStoreTransport.requests >= 4
            BasicsStoreTransport.uninstall()
            #endif
            checks["updates.data_preservation"] = (try config.exportData()) == dataBeforeUpdate && defaults.string(forKey: "fitcoach.coachCookie") == "private-cookie-sentinel"
            model.server = "https://restored.invalid"; model.saveServer()
            defaults.synchronize()
            checks["settings.persisted_readback"] = defaults.string(forKey: "fitcoach.baseURL") == "https://restored.invalid"
            try render(model)
            try write(["schema_version": 1, "platform": platform, "bundle_id": identity, "checks": checks,
                       "cloud_scope": "two independent local stores with shared isolated folder; Apple cross-device transfer unverified",
                       "shortcut_boundary": "Mac application menu; iOS touchscreen has no global/application keyboard requirement"], "ui.json")
        } catch {
            try? write(["schema_version": 1, "platform": platform, "error": error.localizedDescription, "checks": ["settings.suite_completed": false]], "ui.json")
        }
        #if os(iOS)
        LaneSignal.ready("product-basics")
        #endif
    }

    static var platform: String {
        #if os(macOS)
        return "mac"
        #else
        return "iphone-simulator"
        #endif
    }

    @discardableResult static func render(_ model: FitCoachSettingsModel) throws -> Bool {
        #if os(macOS)
        let view = NSHostingView(rootView: FitCoachSettingsPanel(model: model).preferredColorScheme(.light).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 760)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("settings.png"))
        let hidden = !window.isVisible && NSApp.activationPolicy() == .prohibited
        window.close()
        return hidden && bitmap.pixelsWide >= 600
        #else
        let controller = UIHostingController(rootView: FitCoachSettingsPanel(model: model))
        controller.overrideUserInterfaceStyle = .light
        BasicsPresentation.shared.model = model
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.backgroundColor = .systemBackground
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { context in controller.view.layer.render(in: context.cgContext) }
        try image.pngData()!.write(to: root.appendingPathComponent("settings.png"))
        return image.size.width == 390
        #endif
    }
}

#if os(iOS)
@MainActor final class BasicsPresentation: ObservableObject {
    static let shared = BasicsPresentation()
    @Published var model: FitCoachSettingsModel?
}

struct BasicsTestApp: App {
    @StateObject private var presentation = BasicsPresentation.shared
    var body: some Scene {
        WindowGroup {
            Group {
                if let model = presentation.model { FitCoachSettingsPanel(model: model) }
                else { Text("配置与更新 · 隔离验收") }
            }
            .preferredColorScheme(.light)
            .task { await ProductBasicsSelfTest.run() }
        }
    }
}

/// Transport fixture only: production MobileLifecycleModel and AppUpdateChecker parse every response.
final class BasicsStoreTransport: URLProtocol, @unchecked Sendable {
    enum Mode { case valid, corrupt, unavailable }
    static var mode = Mode.valid
    static var requests = 0
    static var exchanged = false
    static func install() throws {
        guard let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral)),
              let fixture = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.basicsEphemeral)) else {
            throw AppUpdateError("隔离更新传输入口不可用；拒绝改用外部网络冒充测试更新源。")
        }
        method_exchangeImplementations(original, fixture)
        exchanged = true
    }
    static func uninstall() {
        guard exchanged,
              let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral)),
              let fixture = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.basicsEphemeral)) else { return }
        method_exchangeImplementations(original, fixture)
        exchanged = false
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "itunes.apple.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if Self.mode == .unavailable { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let payload: Data
        if Self.mode == .corrupt { payload = Data("{broken".utf8) }
        else { payload = try! JSONSerialization.data(withJSONObject: ["results": [["trackId": "6806698109", "bundleId": Bundle.main.bundleIdentifier!, "version": "99.0", "trackViewUrl": "https://apps.apple.com/app/id6806698109"]]]) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLSessionConfiguration {
    /// Only exchanged inside the isolated product self-test; production fetch/parser/model stay unchanged.
    @objc dynamic class var basicsEphemeral: URLSessionConfiguration {
        let configuration = self.basicsEphemeral
        configuration.protocolClasses = [BasicsStoreTransport.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}
#endif

#else
@MainActor enum ProductBasicsSelfTest {
    static let requested = false
    static func launch() {}
}
#endif
