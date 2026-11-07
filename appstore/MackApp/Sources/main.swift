import Cocoa
import WebKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    var item: NSStatusItem!
    var popover = NSPopover()
    var warWindow: NSWindow?
    var feed: FeedOverlay?
    var timer: Timer?
    var settingsWindow: NSWindow?
    var loginBox: NSButton?
    var loginNote: NSTextField?
    let args = CommandLine.arguments

    func config(_ name: String...) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.setURLSchemeHandler(SchemeHandler(), forURLScheme: appScheme)
        c.mediaTypesRequiringUserActionForPlayback = []   // let the hum and sound effects start without a click
        for n in name { c.userContentController.add(self, name: n) }
        return c
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Stats.shared.start()
        buildMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "M.A.C.K.")
            b.imagePosition = .imageLeading; b.target = self; b.action = #selector(clicked); b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setReadout(nil)
        let cfg = config("warroom")
        let css = "body{padding:10px!important;min-height:0!important} .card{box-shadow:none!important;border:0!important}"
        cfg.userContentController.addUserScript(WKUserScript(source: "var s=document.createElement('style');s.textContent='\(css)';document.head.appendChild(s);", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), configuration: cfg)
        let vc = NSViewController(); vc.view = web
        popover.contentViewController = vc; popover.contentSize = NSSize(width: 500, height: 800); popover.behavior = .transient; popover.appearance = NSAppearance(named: .darkAqua)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.setReadout(Stats.shared.latest) }
        let a = args; if a.contains("--war") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openWarRoom() } }
        if let i = a.firstIndex(of: "--selftest") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.selfTest(a.count > i + 1 ? a[i + 1] : "war") } }
    }

    func color(_ v: Double, warn: Double, crit: Double) -> NSColor { v >= crit ? .systemRed : v >= warn ? .systemYellow : .systemGreen }
    func setReadout(_ s: (cpu: Double, gpu: Double, mem: Double)?) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        guard let s else { item.button?.attributedTitle = NSAttributedString(string: " C --% G --% M --%", attributes: [.font: font]); return }
        let out = NSMutableAttributedString(string: " ", attributes: [.font: font])
        for (i, (label, v, warn, crit)) in [("C", s.cpu, 60.0, 85.0), ("G", s.gpu, 60.0, 85.0), ("M", s.mem, 75.0, 90.0)].enumerated() {
            if i > 0 { out.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            out.append(NSAttributedString(string: label, attributes: [.font: font]))
            out.append(NSAttributedString(string: String(format: "%3.0f%%", v), attributes: [.font: font, .foregroundColor: color(v, warn: warn, crit: crit)]))
        }
        item.button?.attributedTitle = out
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Open War Room", action: #selector(openWarRoom), keyEquivalent: "").target = self
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(withTitle: "About M.A.C.K.", action: #selector(showAbout), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit M.A.C.K.", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = m; item.button?.performClick(nil); item.menu = nil; return
        }
        if popover.isShown { popover.performClose(nil) }
        else if let b = item.button {
            (popover.contentViewController?.view as? WKWebView)?.load(URLRequest(url: appBase))
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY); popover.contentViewController?.view.window?.makeKey()
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "fullscreen": warWindow?.toggleFullScreen(nil)
        case "feed": if let m = message.body as? [String: Any], let web = warWindow?.contentView as? WKWebView { feed?.apply(m, in: web) }
        default: openWarRoom()
        }
    }

    @objc func openWarRoom() {
        popover.performClose(nil)
        if warWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "M.A.C.K. War Room"; w.titlebarAppearsTransparent = true; w.backgroundColor = .black; w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false; w.delegate = self; w.collectionBehavior = [.fullScreenPrimary]
            let web = WKWebView(frame: w.contentView!.bounds, configuration: config("fullscreen", "feed"))
            web.autoresizingMask = [.width, .height]; web.navigationDelegate = self
            w.contentView = web; feed = FeedOverlay(host: web)
            web.load(URLRequest(url: appBase.appendingPathComponent("war")))
            w.center(); warWindow = w
        } else if let web = warWindow?.contentView as? WKWebView, web.url?.path != "/war" { web.load(URLRequest(url: appBase.appendingPathComponent("war"))) }
        NSApp.activate(ignoringOtherApps: true); warWindow?.makeKeyAndOrderFront(nil)
    }

    // closing the window must also stop the page, or its hum keeps playing
    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === warWindow, let web = warWindow?.contentView as? WKWebView { feed?.view.isHidden = true; web.load(URLRequest(url: URL(string: "about:blank")!)) }
    }
    func windowDidEnterFullScreen(_ n: Notification) { (warWindow?.contentView as? WKWebView)?.evaluateJavaScript("window.setNativeFS && setNativeFS(true)") }
    func windowDidExitFullScreen(_ n: Notification) { (warWindow?.contentView as? WKWebView)?.evaluateJavaScript("window.setNativeFS && setNativeFS(false)") }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: menus, About, Settings
    /// A menu-bar-only app still needs a main menu so Cmd-C / Cmd-V / Cmd-A work in the web views (for example when pasting a YouTube link).
    func buildMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector?, String)]) -> NSMenuItem {
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let m = NSMenu(title: title)
            for (t, sel, key) in items { if t == "-" { m.addItem(.separator()) } else { let i = m.addItem(withTitle: t, action: sel, keyEquivalent: key); if sel == #selector(showAbout) || sel == #selector(openSettings) || sel == #selector(quit) { i.target = self } } }
            host.submenu = m; return host
        }
        main.addItem(submenu("M.A.C.K.", [("About M.A.C.K.", #selector(showAbout), ""), ("-", nil, ""), ("Settings…", #selector(openSettings), ","), ("-", nil, ""), ("Quit M.A.C.K.", #selector(quit), "q")]))
        main.addItem(submenu("Edit", [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("-", nil, ""), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")]))
        main.addItem(submenu("Window", [("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), ("Close", #selector(NSWindow.performClose(_:)), "w")]))
        NSApp.mainMenu = main
    }

    @objc func showAbout() { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }   // credits come from Credits.html in the bundle

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "M.A.C.K. Settings"; w.isReleasedWhenClosed = false
            let box = NSButton(checkboxWithTitle: "Open M.A.C.K. when I log in", target: self, action: #selector(toggleLogin(_:)))
            box.frame = NSRect(x: 24, y: 92, width: 330, height: 22)
            let note = NSTextField(wrappingLabelWithString: "M.A.C.K. shows its readout in the menu bar. It only starts at login if you turn this on.")
            note.frame = NSRect(x: 24, y: 30, width: 330, height: 52); note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
            w.contentView?.addSubview(box); w.contentView?.addSubview(note)
            loginBox = box; loginNote = note; settingsWindow = w; w.center()
        }
        loginBox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func toggleLogin(_ sender: NSButton) {
        do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginNote?.stringValue = "M.A.C.K. shows its readout in the menu bar. It only starts at login if you turn this on." }
        catch { sender.state = sender.state == .on ? .off : .on; loginNote?.stringValue = "Couldn't change this setting: \(error.localizedDescription)" }
    }
    func applicationWillTerminate(_ n: Notification) { Stats.shared.save() }

    // MARK: --selftest (used for automated checks; prints results and writes snapshots to the sandbox temp folder)
    func selfTest(_ what: String) {
        let a = args
        func snap(_ web: WKWebView, _ name: String, done: @escaping () -> Void) {
            web.takeSnapshot(with: nil) { img, _ in
                if let t = img?.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + name)) }
                done() }
        }
        func js(_ web: WKWebView, _ code: String, _ done: @escaping (String) -> Void) { web.evaluateJavaScript(code) { r, e in done("\(r ?? e.map { "\($0)" } ?? "nil")") } }
        if what == "shots" {   // App Store screenshots: 1440x900 points captured at 2880 px wide
            // a borderless 1440x900 window, so the captured view is exactly 900 points tall (Apple's 2880x1800 screenshot size)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 40, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: config("fullscreen", "feed"))
            w.contentView = web; w.backgroundColor = .black; warWindow = w; feed = FeedOverlay(host: web)
            web.load(URLRequest(url: appBase.appendingPathComponent("war"))); w.makeKeyAndOrderFront(nil)
            enum Step { case wait(Double), js(String), snap(String) }
            let focus = { (id: String) in Step.js("focusOn(screens.find(s => s.def.id === '\(id)'))") }
            let press = { (b: String) in Step.js("focused.btns.find(b => b.id === '\(b)').fn()") }
            let steps: [Step] = [.wait(9), .snap("01-war-room"),
                focus("cpu"), .wait(4.5), .snap("02-cpu"), .js("dismiss()"), .wait(4),
                focus("grades"), .wait(4), press("login"), .wait(4.5), press("g0"), press("g0"), press("g1"), .wait(1.5), .snap("03-grades"), .js("dismiss()"), .wait(4),
                focus("games"), .wait(4), .snap("04-games"), .js("dismiss()"), .wait(4),
                .js("startShow(); SHOW.t0 -= 20000"), .wait(1.6), .snap("05-global-meltdown"), .js("endShow()"), .wait(1), .js("1")]
            func run(_ i: Int) {
                if i >= steps.count { print("DONE"); NSApp.terminate(nil); return }
                switch steps[i] {
                case .wait(let t): DispatchQueue.main.asyncAfter(deadline: .now() + t) { run(i + 1) }
                case .js(let c): web.evaluateJavaScript(c) { _, e in if let e { print("js error:", e) }; run(i + 1) }
                case .snap(let n):
                    let cfg = WKSnapshotConfiguration(); cfg.snapshotWidth = 1440
                    web.takeSnapshot(with: cfg) { img, _ in
                        if let t = img?.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "shot-\(n).png")); print("shot", n, r.pixelsWide, "x", r.pixelsHigh) }
                        run(i + 1) }
                }
            }
            run(0); return
        }
        if what == "popover" {
            let w = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 500, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), configuration: config("warroom")); w.contentView = web; w.makeKeyAndOrderFront(nil)
            web.load(URLRequest(url: appBase))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { js(web, "document.getElementById('host').textContent + ' | ' + document.body.innerText.slice(0, 200).replace(/\\n/g,' / ')") { print("popover:", $0); snap(web, "selftest-popover.png") { print("DONE"); NSApp.terminate(nil) } } }
            return
        }
        openWarRoom(); guard let web = warWindow?.contentView as? WKWebView else { return }
        feed?.onState = { print("feed overlay:", $0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            js(web, "JSON.stringify({err: document.getElementById('err').textContent, screens: screens.length, host: D && D.st && D.st.host, cpu: D && D.now && D.now.cpu, procs: D && D.now && D.now.procs && D.now.procs.slice(0,3).map(p => p.name + ' ' + p.cpu + '%'), hist: H ? H.length : -1})") { print("war:", $0)
                if what == "feed" { let preset = a.count > 3 ? a[3] : "0"; js(web, "focusOn(screens.find(s => s.def.id === 'feed')); setTimeout(() => Feed.load(\(preset)), 3500); 'focusing preset \(preset)'") { print($0) 

                    DispatchQueue.main.asyncAfter(deadline: .now() + 14) { print("overlay frame:", self.feed?.view.frame ?? .zero, "hidden:", self.feed?.view.isHidden ?? true)
                        snap(self.feed!.view, "selftest-feed.png") { snap(web, "selftest-war.png") { print("DONE"); NSApp.terminate(nil) } } } } }
                else if what == "audio" { js(web, "Snd.on = true; Snd.music = true; Snd.start(); 'started'") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { js(web, "JSON.stringify({ctx: Snd.ctx && Snd.ctx.state, samples: Object.keys(Snd.samples).length, ambient: !!Snd.ambBuf, song: !!Snd.songBuf, ambientPlaying: !!Snd.amb_, err: document.getElementById('err').textContent})") { print("audio:", $0)
                        js(web, "Snd.click(); Snd.servo(1, .5); 'played effects'") { print($0); print("DONE"); NSApp.terminate(nil) } } } } }
                else { snap(web, "selftest-war.png") { print("DONE"); NSApp.terminate(nil) } } }
        }
    }
}

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main); term.setEventHandler { NSApp.terminate(nil) }; term.resume()
let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate
app.setActivationPolicy(CommandLine.arguments.contains("--selftest") ? .regular : .accessory)
app.run()
