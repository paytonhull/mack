import Cocoa
import WebKit

let port = 8765
let base = URL(string: "http://127.0.0.1:\(port)")!

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    var warWindow: NSWindow?
    func log(_ m: String) { try? (m+"\n").appendToFile("/tmp/macmon-debug.log") }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log("fail \(e)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { log("provisional \(e)"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if w === self.warWindow?.contentView { w.load(URLRequest(url: base.appendingPathComponent("war"))) } else { self.loadPage() }
        } }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        log("finished \(w.url?.path ?? "")")
        if w === warWindow?.contentView {
            if CommandLine.arguments.contains("--war") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { w.evaluateJavaScript("Snd.start()", completionHandler: nil) } }   // debug launch: start the audio engine regardless of the mute setting
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                w.evaluateJavaScript("document.getElementById('err').textContent + ' | webgl2=' + !!document.createElement('canvas').getContext('webgl2') + ' | samples=' + (typeof Snd !== 'undefined' ? Snd.ctx ? Snd.ctx.state + ':' + Object.keys(Snd.samples).join(',') : 'noctx' : 'n/a')") { r, e in self.log("war: \(r ?? e ?? "?")") }
            }
        }
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { log("terminated") }
    var item: NSStatusItem!
    var popover = NSPopover()
    var server: Process?
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        startServer()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.title = " C --% G --% M --%"
            b.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "MacMon")
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let cfg = WKWebViewConfiguration()
        let css = "body{padding:10px!important;min-height:0!important} .card{box-shadow:none!important;border:0!important}"
        let js = "var s=document.createElement('style');s.textContent='\(css)';document.head.appendChild(s);"
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.add(self, name: "warroom")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), configuration: cfg)
        web.navigationDelegate = self
        let vc = NSViewController(); vc.view = web
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 500, height: 800)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        loadPage()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if CommandLine.arguments.contains("--war") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.openWarRoom() } }
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.clicked() } }
    }

    func loadPage() {
        (popover.contentViewController?.view as? WKWebView)?.load(URLRequest(url: base))
    }

    func startServer() {
        // reuse a server that's already running
        if (try? Data(contentsOf: base.appendingPathComponent("api/stats"))) != nil { return }
        guard let script = Bundle.main.path(forResource: "server", ofType: "py") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script]
        p.environment = ProcessInfo.processInfo.environment.merging(["PORT": "\(port)", "MACMON_APP": "1"]) { _, new in new }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        server = p
    }

    // green < warn, yellow < crit, red beyond. Memory runs high on macOS by design, so its bands are higher.
    func color(_ v: Double, warn: Double, crit: Double) -> NSColor {
        v >= crit ? .systemRed : v >= warn ? .systemYellow : .systemGreen
    }

    func setReadout(cpu: Double, gpu: Double, mem: Double) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let out = NSMutableAttributedString(string: " ", attributes: [.font: font])
        for (i, (label, v, warn, crit)) in [("C", cpu, 60.0, 85.0), ("G", gpu, 60.0, 85.0), ("M", mem, 75.0, 90.0)].enumerated() {
            if i > 0 { out.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            out.append(NSAttributedString(string: label, attributes: [.font: font]))
            out.append(NSAttributedString(string: String(format: "%3.0f%%", v),
                                          attributes: [.font: font, .foregroundColor: color(v, warn: warn, crit: crit)]))
        }
        item.button?.attributedTitle = out
    }

    func refresh() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("api/stats?since=9999999999")) { data, _, _ in
            guard let data else {
                // server is gone: bring it back
                DispatchQueue.main.async {
                    self.item.button?.attributedTitle = NSAttributedString(string: " C --% G --% M --%", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
                    if self.server?.isRunning != true { self.server = nil; self.startServer() }
                }
                return
            }
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let now = j["now"] as? [String: Any],
                  let cpu = now["cpu"] as? Double, let gpu = now["gpu"] as? Double,
                  let mem = now["mem"] as? Double else { return }
            DispatchQueue.main.async {
                self.setReadout(cpu: cpu, gpu: gpu, mem: mem)
            }
        }.resume()
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Open War Room", action: #selector(openWarRoom), keyEquivalent: "").target = self
            m.addItem(withTitle: "Open in Browser", action: #selector(openBrowser), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit MacMon", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = m; item.button?.performClick(nil); item.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else if let b = item.button {
            loadPage()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "fullscreen" { warWindow?.toggleFullScreen(nil) } else { openWarRoom() }
    }

    @objc func openWarRoom() {
        popover.performClose(nil)
        if warWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "M.A.C.K. War Room"
            w.titlebarAppearsTransparent = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.delegate = self
            let wc = WKWebViewConfiguration()
            wc.mediaTypesRequiringUserActionForPlayback = []   // let the hum and the video feed autoplay
            wc.userContentController.add(self, name: "fullscreen")
            w.collectionBehavior = [.fullScreenPrimary]
            let web = WKWebView(frame: w.contentView!.bounds, configuration: wc)
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            web.load(URLRequest(url: base.appendingPathComponent("war")))
            w.contentView = web
            w.center()
            warWindow = w
        } else if let web = warWindow?.contentView as? WKWebView, web.url?.path != "/war" {
            web.load(URLRequest(url: base.appendingPathComponent("war")))
        }
        NSApp.activate(ignoringOtherApps: true)
        warWindow?.makeKeyAndOrderFront(nil)
    }

    // closing the window must also stop the page, or its hum keeps playing
    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === warWindow, let web = warWindow?.contentView as? WKWebView { web.load(URLRequest(url: URL(string: "about:blank")!)) }
    }

    // tell the page when the window enters / leaves full screen so its icon can invert
    func windowDidEnterFullScreen(_ n: Notification) { (warWindow?.contentView as? WKWebView)?.evaluateJavaScript("window.setNativeFS && setNativeFS(true)") }
    func windowDidExitFullScreen(_ n: Notification) { (warWindow?.contentView as? WKWebView)?.evaluateJavaScript("window.setNativeFS && setNativeFS(false)") }

    @objc func openBrowser() { NSWorkspace.shared.open(base) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) { server?.terminate() }
}

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { NSApp.terminate(nil) }
term.resume()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension String { func appendToFile(_ p: String) throws {
    if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(data(using: .utf8)!); h.closeFile() }
    else { try write(toFile: p, atomically: true, encoding: .utf8) } } }
