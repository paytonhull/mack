// Serves the bundled pages and the JSON API to the web views through a custom URL scheme (no local web server),
// and hosts the YouTube feed in a separate overlay web view (YouTube rejects embeds from a custom-scheme page: Error 153).
import Cocoa
import WebKit

let appScheme = "mack"
let appBase = URL(string: "\(appScheme)://app")!
/// Address the feed overlay claims as its origin. YouTube only needs a valid https referrer; use the project's own site.
let feedBaseURL = URL(string: "https://paytonhull.github.io/mack/")!

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()
    private let root = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true).standardizedFileURL
    private static let mime = ["html": "text/html; charset=utf-8", "js": "application/javascript", "json": "application/json", "wav": "audio/wav", "mp3": "audio/mpeg", "png": "image/png", "css": "text/css"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path == "" || path == "/" { path = "/index.html" } else if path == "/war" { path = "/war.html" }

        if path == "/api/stats" {
            let since = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value.flatMap(Int.init) ?? 0
            return finish(task, url, Stats.shared.apiStats(since: since), "application/json")
        }
        if path == "/api/live" {
            let ch = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "channel" }?.value ?? ""
            guard ch.range(of: #"^UC[\w-]{20,}$"#, options: .regularExpression) != nil else { return finish(task, url, Data(#"{"id":null}"#.utf8), "application/json") }
            return Stats.shared.liveVideo(channel: ch) { id in
                let body = (try? JSONSerialization.data(withJSONObject: ["id": id as Any])) ?? Data(#"{"id":null}"#.utf8)
                self.finish(task, url, body, "application/json") }
        }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else { return finish(task, url, Data(), "text/plain", status: 404) }
        finish(task, url, data, Self.mime[file.pathExtension] ?? "application/octet-stream")
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    private func finish(_ task: WKURLSchemeTask, _ url: URL, _ data: Data, _ mime: String, status: Int = 200) {
        DispatchQueue.main.async {
            if self.stopped.remove(ObjectIdentifier(task)) != nil { return }
            let r = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!
            task.didReceive(r); task.didReceive(data); task.didFinish()
        }
    }
}

/// A small web view laid over the Live Feed screen's video area; the war-room page tells us where, and what to play.
final class FeedOverlay: NSObject, WKScriptMessageHandler {
    let view: WKWebView
    private var src = ""
    var onState: ((String) -> Void)?
    init(host: WKWebView) {
        let cfg = WKWebViewConfiguration(); cfg.mediaTypesRequiringUserActionForPlayback = []
        view = WKWebView(frame: .zero, configuration: cfg); view.isHidden = true
        super.init()
        cfg.userContentController.add(self, name: "feedstate")
        host.addSubview(view)
    }
    func apply(_ m: [String: Any], in host: WKWebView) {
        guard (m["show"] as? Bool) == true, let s = m["src"] as? String, !s.isEmpty,
              let x = m["x"] as? Double, let y = m["y"] as? Double, let w = m["w"] as? Double, let h = m["h"] as? Double, w > 8, h > 8 else {
            view.isHidden = true; if (m["show"] as? Bool) == false { src = ""; view.loadHTMLString("", baseURL: nil) }; return }
        view.frame = NSRect(x: x, y: host.isFlipped ? y : host.bounds.height - y - h, width: w, height: h)
        view.isHidden = false
        if s != src {
            src = s
            let esc = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            view.loadHTMLString("""
            <html><body style="margin:0;background:#000;overflow:hidden"><iframe id="yt" src="\(esc)&enablejsapi=1" style="border:0;width:100vw;height:100vh"
             allow="autoplay; encrypted-media; picture-in-picture; fullscreen" referrerpolicy="strict-origin-when-cross-origin"></iframe>
            <script>const f=document.getElementById('yt');
            f.addEventListener('load',()=>f.contentWindow.postMessage(JSON.stringify({event:'listening',id:1,channel:'widget'}),'*'));
            addEventListener('message',e=>{if(!/youtube/.test(e.origin))return;try{const d=JSON.parse(e.data);
              if(d.event==='onError')webkit.messageHandlers.feedstate.postMessage('error '+JSON.stringify(d.info));
              else if(d.event==='infoDelivery'&&d.info&&d.info.playerState!==undefined)webkit.messageHandlers.feedstate.postMessage('state '+d.info.playerState);}catch(x){}});</script></body></html>
            """, baseURL: feedBaseURL)
        }
    }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) { onState?("\(message.body)") }
}
