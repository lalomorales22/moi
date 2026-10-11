import Foundation

enum BrowserPage {
    struct Asset {
        let body: Data
        let contentType: String
    }
    private static let assets: [String: Asset] = {
        let files = [("index", "html", "text/html; charset=utf-8"),
                     ("moi-web", "css", "text/css; charset=utf-8"),
                     ("moi-web", "js", "text/javascript; charset=utf-8"),
                     ("moi-icon", "svg", "image/svg+xml")]
        var result: [String: Asset] = [:]
        for (name, ext, type) in files {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext),
                  let data = try? Data(contentsOf: url) else { continue }
            result["/\(name).\(ext)"] = Asset(body: data, contentType: type)
        }
        return result
    }()
    static func asset(for path: String) -> Asset? {
        // Older QR codes pointed at /v1. Keep those useful in a browser, too.
        assets[["/", "/v1", "/v1/"].contains(path) ? "/index.html" : path]
    }
}
