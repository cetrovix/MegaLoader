// MegaLoader — скачивание с облачных дисков и видео/музыки с площадок. Работает автономно.
// Сборка: ./build.sh (release — ещё DMG и zip для релиза)
import SwiftUI
import AppKit
import Foundation

// MARK: - Модель

struct RemoteFile: Identifiable, Hashable, Codable {
    var id = UUID()
    let relPath: String      // путь внутри диска: "Папка/Подпапка/файл.mp4"
    let size: Int64?         // байты, если известно
    let source: Source
    enum Source: Hashable, Codable {
        case yandex(publicKey: String, path: String?, direct: URL?)   // path nil = ссылка на один файл
        case google(id: String)
        case dropbox(url: String)                                     // прямая ссылка dl=1 (папка — одним zip)
        case wetransfer(id: String, hash: String, recipient: String?, fileID: String)
        case mailru(weblink: String)
        case onedrive(token: String, itemID: String)
        case pcloud(api: String, code: String, fileID: Int64?)
        case media(url: String, quality: String, site: String)       // видео/музыка через yt-dlp; quality: best/2160/1440/1080/720/480/audio
    }
}

enum Provider: String, Codable, CaseIterable {
    case yandex = "Яндекс Диск", google = "Google Диск", dropbox = "Dropbox", wetransfer = "WeTransfer",
         mailru = "Облако Mail.ru", onedrive = "OneDrive", pcloud = "pCloud",
         video = "Видео", music = "Музыка"
    enum Category: String { case drive, video, music }
    var category: Category { self == .video ? .video : self == .music ? .music : .drive }
    static var drives: [Provider] { allCases.filter { $0.category == .drive } }
    var title: String {
        switch self {
        case .yandex: L("Яндекс Диск", "Yandex Disk"); case .google: L("Google Диск", "Google Drive")
        case .mailru: L("Облако Mail.ru", "Mail.ru Cloud"); case .video: L("Видео", "Video"); case .music: L("Музыка", "Music"); default: rawValue
        }
    }
    var color: Color {
        switch self {
        case .yandex: .yellow
        case .google: Color(red: 0.5, green: 0.7, blue: 1)
        case .dropbox: Color(red: 0.35, green: 0.55, blue: 1)
        case .wetransfer: Color(red: 0.75, green: 0.6, blue: 1)
        case .mailru: Color(red: 0.3, green: 0.75, blue: 1)
        case .onedrive: Color(red: 0.4, green: 0.65, blue: 0.95)
        case .pcloud: Color(red: 0.35, green: 0.85, blue: 0.75)
        case .video: Color(red: 1, green: 0.45, blue: 0.4)
        case .music: Color(red: 0.4, green: 0.85, blue: 0.5)
        }
    }
    var short: String {
        switch self { case .yandex: L("Яндекс", "Yandex"); case .google: "Google"; case .mailru: "Mail.ru"; case .video: L("Видео", "Video"); case .music: L("Музыка", "Music"); default: rawValue }
    }
}

struct ListResult { let rootName: String; let files: [RemoteFile]; let skipped: [String] }

enum LoaderError: LocalizedError {
    case badLink, http(Int), parse(String)
    var errorDescription: String? {
        switch self {
        case .badLink: return L("Не похоже на публичную ссылку Яндекс Диска или Google Диска", "This doesn't look like a public Yandex Disk or Google Drive link")
        case .http(let c): return L("Сервер ответил ошибкой \(c). Ссылка открыта для всех?", "The server returned error \(c). Is the link public?")
        case .parse(let s): return L("Не удалось разобрать ответ: \(s)", "Couldn't read the response: \(s)")
        }
    }
}

/// ошибка → понятный текст с подсказкой, что делать
func human(_ e: Error) -> String {
    if let l = e as? LoaderError {
        switch l {
        case .badLink: return L("Это не похоже на публичную ссылку Яндекс Диска или Google Диска. Проверь, что скопировал ссылку целиком.", "This doesn't look like a public cloud drive link. Make sure you copied the whole link.")
        case .http(let c):
            switch c {
            case 401, 403: return L("Доступ закрыт. Попроси владельца открыть ссылку для всех («Доступ по ссылке»).", "Access denied. Ask the owner to make the link public (“Anyone with the link”).")
            case 404, 410: return L("Файла по ссылке больше нет — его удалили или переместили на диске владельца.", "The file is no longer available — the owner deleted or moved it.")
            case 429: return L("Сервис временно ограничил скачивание. Подожди 10–15 минут и нажми «Продолжить».", "The service has temporarily limited downloads. Wait 10–15 minutes and press “Resume”.")
            case 500...599: return L("У сервиса сейчас сбой (ошибка \(c)). Попробуй «Продолжить» чуть позже.", "The service is having problems (error \(c)). Try “Resume” a bit later.")
            default: return L("Сервис ответил ошибкой \(c). Попробуй «Продолжить»; если повторится — открой Журнал.", "The service returned error \(c). Try “Resume”; if it happens again, open the Log.")
            }
        case .parse(let s): return s.prefix(1).uppercased() + s.dropFirst() + "."
        }
    }
    if let u = e as? URLError {
        switch u.code {
        case .notConnectedToInternet: return L("Нет интернета. Как только сеть появится — нажми «Продолжить», докачается с того же места.", "No internet. Once you're back online, press “Resume” — it will continue where it stopped.")
        case .timedOut: return L("Сервер слишком долго не отвечал. Нажми «Продолжить» — докачается с того же места.", "The server took too long to respond. Press “Resume” — it will continue where it stopped.")
        case .networkConnectionLost: return L("Связь оборвалась. Нажми «Продолжить» — докачается с того же места.", "The connection dropped. Press “Resume” — it will continue where it stopped.")
        case .cannotFindHost, .dnsLookupFailed: return L("Не получается найти сервер. Проверь интернет или VPN.", "Can't reach the server. Check your internet or VPN.")
        case .cancelled: return L("Остановлено.", "Stopped.")
        default: return L("Проблема с сетью (\(u.code.rawValue)). Нажми «Продолжить» — докачается с того же места.", "Network problem (\(u.code.rawValue)). Press “Resume” — it will continue where it stopped.")
        }
    }
    let n = e as NSError
    if n.domain == NSCocoaErrorDomain {
        switch n.code {
        case NSFileWriteOutOfSpaceError: return L("На диске закончилось место. Освободи место и нажми «Продолжить».", "The disk is full. Free up some space and press “Resume”.")
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return L("Нет доступа к папке загрузки. Выбери другую папку.", "No access to the download folder. Choose another folder.")
        case NSFileNoSuchFileError, NSFileWriteFileExistsError, 4: return L("Папку загрузки переместили или удалили. Укажи её новое место — загрузка продолжится.", "The download folder was moved or deleted. Show its new location and the download will continue.")
        case NSFileWriteVolumeReadOnlyError: return L("Диск только для чтения — выбери другую папку.", "The disk is read-only — choose another folder.")
        default: break
        }
    }
    if n.domain == NSPOSIXErrorDomain && n.code == 28 { return L("На диске закончилось место. Освободи место и нажми «Продолжить».", "The disk is full. Free up some space and press “Resume”.") }
    if n.domain == NSPOSIXErrorDomain && n.code == 2 { return L("Папку загрузки переместили или удалили. Укажи её новое место — загрузка продолжится.", "The download folder was moved or deleted. Show its new location and the download will continue.") }
    return e.localizedDescription
}

/// язык интерфейса: «ru» (по умолчанию) или «en»
var isEN: Bool { UserDefaults.standard.string(forKey: "lang") == "en" }
func L(_ ru: String, _ en: String) -> String { isEN ? en : ru }

let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36"

func fetch(_ url: URL) async throws -> Data {
    var r = URLRequest(url: url); r.setValue(UA, forHTTPHeaderField: "User-Agent")
    let (d, resp) = try await URLSession.shared.data(for: r)
    if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw LoaderError.http(h.statusCode) }
    return d
}

func detect(_ link: String) -> Provider? {
    let l = link.lowercased()
    if l.contains("disk.yandex") || l.contains("yadi.sk") || l.contains("disk.360.yandex") { return .yandex }
    if l.contains("drive.google") || l.contains("docs.google") { return .google }
    if l.contains("dropbox.com") || l.contains("db.tt") { return .dropbox }
    if l.contains("we.tl") || l.contains("wetransfer.com") { return .wetransfer }
    if l.contains("cloud.mail.ru") { return .mailru }
    if l.contains("1drv.ms") || l.contains("onedrive.live.com") || l.contains("sharepoint.com") { return .onedrive }
    if l.contains("pcloud.link") || l.contains("pcloud.com") { return .pcloud }
    if l.hasPrefix("http://") || l.hasPrefix("https://") || l.contains(".") && !l.contains(" ") {
        return Media.musicHosts.contains { l.contains($0) } ? .music : .video
    }
    return nil
}

// MARK: - Яндекс Диск (публичный API, без ключа)

enum Yandex {
    static func list(_ link: String) async throws -> ListResult {
        let root = try await meta(link, path: nil, offset: 0)
        let rootName = root["name"] as? String ?? L("Яндекс Диск", "Yandex Disk")
        if root["type"] as? String == "file" { return ListResult(rootName: "", files: [file(root, link: link, rel: rootName, single: true)], skipped: []) }
        var files: [RemoteFile] = []
        try await walk(link, path: "/", rel: "", into: &files)
        return ListResult(rootName: rootName, files: files, skipped: [])
    }
    // если основной адрес API перестанет отвечать — пробуем запасной
    static let hosts = ["https://cloud-api.yandex.net", "https://cloud-api.yandex.com"]
    static func api(_ path: String, _ q: [URLQueryItem]) async throws -> [String: Any] {
        var last: Error = LoaderError.parse(L("Яндекс", "Yandex"))
        for h in hosts {
            do {
                var c = URLComponents(string: h + path)!; c.queryItems = q
                let d = try await fetch(c.url!)
                if let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
            } catch { last = error; log("  Яндекс \(h)\(path): \(error.localizedDescription) — пробую дальше") }
        }
        throw last
    }
    static func meta(_ link: String, path: String?, offset: Int) async throws -> [String: Any] {
        var q: [URLQueryItem] = [.init(name: "public_key", value: link), .init(name: "limit", value: "1000"), .init(name: "offset", value: "\(offset)")]
        if let path { q.append(.init(name: "path", value: path)) }
        return try await api("/v1/disk/public/resources", q)
    }
    static func file(_ j: [String: Any], link: String, rel: String, single: Bool = false) -> RemoteFile {
        let size = (j["size"] as? NSNumber)?.int64Value
        let direct = (j["file"] as? String).flatMap(URL.init(string:))
        return RemoteFile(relPath: rel, size: size, source: .yandex(publicKey: link, path: single ? nil : j["path"] as? String, direct: direct))
    }
    static func walk(_ link: String, path: String, rel: String, into out: inout [RemoteFile]) async throws {
        var offset = 0
        while true {
            let j = try await meta(link, path: path, offset: offset)
            let emb = j["_embedded"] as? [String: Any] ?? [:]
            let items = emb["items"] as? [[String: Any]] ?? []
            for it in items {
                let name = it["name"] as? String ?? "?"
                let r = rel.isEmpty ? name : rel + "/" + name
                if it["type"] as? String == "dir" { try await walk(link, path: it["path"] as? String ?? "/", rel: r, into: &out) }
                else { out.append(file(it, link: link, rel: r)) }
            }
            let total = emb["total"] as? Int ?? items.count
            offset += items.count
            if items.isEmpty || offset >= total { break }
        }
    }
    static func resolve(publicKey: String, path: String?) async throws -> URL {
        var q: [URLQueryItem] = [.init(name: "public_key", value: publicKey)]
        if let path { q.append(.init(name: "path", value: path)) }
        let j = try await api("/v1/disk/public/resources/download", q)
        guard let h = j["href"] as? String, let u = URL(string: h) else { throw LoaderError.parse(L("ссылка Яндекса на скачивание", "Yandex download link")) }
        return u
    }
}

// MARK: - Google Диск (публичные файлы и папки, без ключа)

enum Google {
    static func id(from link: String, folder: inout Bool) -> String? {
        let pats = [("/folders/([A-Za-z0-9_-]{10,})", true), ("/file/d/([A-Za-z0-9_-]{10,})", false),
                    ("/d/([A-Za-z0-9_-]{10,})", false), ("[?&]id=([A-Za-z0-9_-]{10,})", false)]
        for (p, f) in pats {
            if let r = link.range(of: p, options: .regularExpression) {
                let m = String(link[r]); let id = m.replacingOccurrences(of: #"^.*?(?:/folders/|/file/d/|/d/|id=)"#, with: "", options: .regularExpression)
                folder = f; return id
            }
        }
        return nil
    }
    static func list(_ link: String) async throws -> ListResult {
        var isFolder = false
        guard let id = id(from: link, folder: &isFolder) else { throw LoaderError.badLink }
        if !isFolder {
            let name = try await fileName(id) ?? "файл_\(id)"
            return ListResult(rootName: "", files: [RemoteFile(relPath: name, size: nil, source: .google(id: id))], skipped: [])
        }
        var files: [RemoteFile] = []; var skipped: [String] = []
        // 1) без ключа — публичная страница папки; 2) если не вышло или пусто и задан ключ — Drive API (ещё и с размерами)
        do {
            let (title, _) = try await folderPage(id)
            try await walk(id, rel: "", into: &files, skipped: &skipped, depth: 0)
            if !files.isEmpty || apiKey == nil { return ListResult(rootName: title, files: files, skipped: skipped) }
            log("  Google: страница папки пустая — пробую Drive API")
        } catch {
            guard apiKey != nil else { throw error }
            log("  Google: страница папки не читается (\(error.localizedDescription)) — пробую Drive API")
        }
        files = []; skipped = []
        let title = try await apiName(id)
        try await apiWalk(id, rel: "", into: &files, skipped: &skipped, depth: 0)
        return ListResult(rootName: title, files: files, skipped: skipped)
    }
    static func folderPage(_ id: String) async throws -> (String, String) {
        let d = try await fetch(URL(string: "https://drive.google.com/embeddedfolderview?id=\(id)#list")!)
        let html = String(decoding: d, as: UTF8.self)
        let title = match(html, #"<title>(.*?)</title>"#).first.map(unescape) ?? L("Google Диск", "Google Drive")
        return (title, html)
    }
    static func walk(_ id: String, rel: String, into out: inout [RemoteFile], skipped: inout [String], depth: Int) async throws {
        if depth > 30 { return }
        let (_, html) = try await folderPage(id)
        // каждая запись: <div class="flip-entry" id="entry-ID"> ... <a href="..."> ... <div class="flip-entry-title">Имя</div>
        let entries = html.components(separatedBy: "class=\"flip-entry\"").dropFirst()
        for e in entries {
            guard let eid = match(e, #"id="entry-([A-Za-z0-9_-]+)""#).first,
                  let href = match(e, #"<a href="([^"]+)""#).first else { continue }
            let name = unescape(match(e, #"class="flip-entry-title">(.*?)</div>"#).first ?? eid)
            let r = rel.isEmpty ? name : rel + "/" + name
            if href.contains("/folders/") { try await walk(eid, rel: r, into: &out, skipped: &skipped, depth: depth + 1) }
            else if href.contains("docs.google.com") { skipped.append(r + L(" (документ Google — скачивается только экспортом)", " (Google document — can only be exported)")) }
            else { out.append(RemoteFile(relPath: r, size: nil, source: .google(id: eid))) }
        }
    }
    static var apiKey: String? { let k = UserDefaults.standard.string(forKey: "googleKey")?.trimmingCharacters(in: .whitespaces); return (k?.isEmpty ?? true) ? nil : k }
    static func apiName(_ id: String) async throws -> String {
        guard let k = apiKey else { throw LoaderError.parse(L("нет ключа Google API", "no Google API key")) }
        let j = try JSONSerialization.jsonObject(with: try await fetch(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=name&supportsAllDrives=true&key=\(k)")!)) as? [String: Any]
        return j?["name"] as? String ?? L("Google Диск", "Google Drive")
    }
    static func apiWalk(_ id: String, rel: String, into out: inout [RemoteFile], skipped: inout [String], depth: Int) async throws {
        guard let k = apiKey, depth <= 30 else { return }
        var token: String? = nil
        repeat {
            var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            c.queryItems = [.init(name: "q", value: "'\(id)' in parents and trashed=false"), .init(name: "fields", value: "nextPageToken,files(id,name,mimeType,size)"),
                            .init(name: "pageSize", value: "1000"), .init(name: "supportsAllDrives", value: "true"), .init(name: "includeItemsFromAllDrives", value: "true"), .init(name: "key", value: k)]
            if let token { c.queryItems!.append(.init(name: "pageToken", value: token)) }
            let j = try JSONSerialization.jsonObject(with: try await fetch(c.url!)) as? [String: Any] ?? [:]
            for f in j["files"] as? [[String: Any]] ?? [] {
                let name = f["name"] as? String ?? "?"; let fid = f["id"] as? String ?? ""; let mime = f["mimeType"] as? String ?? ""
                let r = rel.isEmpty ? name : rel + "/" + name
                if mime == "application/vnd.google-apps.folder" { try await apiWalk(fid, rel: r, into: &out, skipped: &skipped, depth: depth + 1) }
                else if mime.hasPrefix("application/vnd.google-apps") { skipped.append(r + L(" (документ Google — скачивается только экспортом)", " (Google document — can only be exported)")) }
                else { out.append(RemoteFile(relPath: r, size: (f["size"] as? String).flatMap { Int64($0) }, source: .google(id: fid))) }
            }
            token = j["nextPageToken"] as? String
        } while token != nil
    }
    // адреса скачивания по порядку: если первый перестанет работать, берём следующий
    static func downloadURLs(_ id: String) -> [URL] {
        var u = [downloadURL(id), URL(string: "https://drive.google.com/uc?export=download&id=\(id)&confirm=t")!]
        if let k = apiKey { u.append(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media&supportsAllDrives=true&key=\(k)")!) }
        return u
    }
    /// Google иногда отдаёт страницу «не удалось проверить на вирусы» — достаём из неё настоящую ссылку
    static func confirmURL(fromHTML html: String) -> URL? {
        guard let action = match(html, #"<form[^>]*action="([^"]+)""#).first else { return nil }
        var c = URLComponents(string: unescape(action))
        let names = match(html, #"<input[^>]*type="hidden"[^>]*name="([^"]+)""#)
        let values = match(html, #"<input[^>]*type="hidden"[^>]*value="([^"]*)""#)
        if names.count == values.count, !names.isEmpty { c?.queryItems = zip(names, values).map { URLQueryItem(name: $0, value: unescape($1)) } }
        return c?.url
    }
    static func fileName(_ id: String) async throws -> String? {
        var r = URLRequest(url: downloadURL(id)); r.httpMethod = "HEAD"; r.setValue(UA, forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await URLSession.shared.data(for: r)
        return (resp as? HTTPURLResponse).flatMap { dispositionName($0.value(forHTTPHeaderField: "Content-Disposition")) }
    }
    static func downloadURL(_ id: String) -> URL {
        URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t")!
    }
    static func match(_ s: String, _ p: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: 1), in: s).map { String(s[$0]) } }
    }
    static func unescape(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] { t = t.replacingOccurrences(of: a, with: b) }
        return t.replacingOccurrences(of: #"\s*-\s*Google\s*(Drive|Диск)$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Другие сервисы (публичные ссылки, без входа)

/// Dropbox отдаёт файл (а папку — zip) программам; браузерам — страницу. Поэтому для него свой User-Agent
let dropboxUA = "MegaLoader"
func isDropboxHost(_ u: URL) -> Bool { (u.host ?? "").contains("dropbox") }

func requestJSON(_ url: URL, method: String = "GET", body: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> Any {
    var r = URLRequest(url: url); r.httpMethod = method; r.setValue(UA, forHTTPHeaderField: "User-Agent")
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (d, resp) = try await URLSession.shared.data(for: r)
    if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw LoaderError.http(h.statusCode) }
    return try JSONSerialization.jsonObject(with: d)
}

enum Dropbox {
    static func dl(_ link: String) -> String {
        var c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines))!
        var q = (c.queryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" }; q.append(.init(name: "dl", value: "1")); c.queryItems = q
        return c.url!.absoluteString
    }
    static func list(_ link: String) async throws -> ListResult {
        let u = dl(link)
        let p = try await Engine.probe(URL(string: u)!)
        if p.html { throw LoaderError.parse(L("Dropbox не отдал файл — ссылка закрыта или удалена", "Dropbox didn't return a file \u{2014} the link is closed or deleted")) }
        let isFolder = link.contains("/fo/") || link.contains("/sh/")
        let name = p.name ?? (isFolder ? "Dropbox.zip" : (URL(string: link)?.lastPathComponent ?? "file"))
        return ListResult(rootName: "", files: [RemoteFile(relPath: name, size: p.size, source: .dropbox(url: u))], skipped: [])
    }
}

enum WeTransfer {
    static func ids(_ link: String) async throws -> (id: String, hash: String, recipient: String?) {
        var u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))!
        if (u.host ?? "").contains("we.tl") {   // короткая ссылка — узнаём полную
            var r = URLRequest(url: u); r.setValue(UA, forHTTPHeaderField: "User-Agent")
            let (_, resp) = try await URLSession.shared.data(for: r); u = resp.url ?? u
        }
        let parts = u.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "downloads"), parts.count >= i + 3 else { throw LoaderError.badLink }
        let rest = Array(parts[(i + 1)...])
        return rest.count >= 3 ? (rest[0], rest[2], rest[1]) : (rest[0], rest[1], nil)
    }
    static func api(_ id: String, _ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        let j = try await requestJSON(URL(string: "https://wetransfer.com/api/v4/transfers/\(id)/\(action)")!, method: "POST", body: body,
                                      headers: ["X-Requested-With": "XMLHttpRequest", "Origin": "https://wetransfer.com"])
        return j as? [String: Any] ?? [:]
    }
    static func list(_ link: String) async throws -> ListResult {
        let t = try await ids(link)
        var body: [String: Any] = ["security_hash": t.hash]; if let r = t.recipient { body["recipient_id"] = r }
        let j = try await api(t.id, "prepare-download", body)
        let items = j["items"] as? [[String: Any]] ?? j["files"] as? [[String: Any]] ?? []
        if items.isEmpty { throw LoaderError.parse(L("передача пустая или срок ссылки истёк (WeTransfer хранит 7 дней)", "the transfer is empty or expired (WeTransfer keeps files for 7 days)")) }
        let files = items.map { f in
            RemoteFile(relPath: (f["name"] as? String) ?? "file", size: (f["size"] as? NSNumber)?.int64Value,
                       source: .wetransfer(id: t.id, hash: t.hash, recipient: t.recipient, fileID: "\(f["id"] ?? "")"))
        }
        let title = (j["display_name"] as? String) ?? (files.count > 1 ? "WeTransfer" : "")
        return ListResult(rootName: files.count > 1 ? title : "", files: files, skipped: [])
    }
    static func resolve(id: String, hash: String, recipient: String?, fileID: String) async throws -> URL {
        var body: [String: Any] = ["security_hash": hash, "intent": "single_file", "file_ids": [fileID]]
        if let r = recipient { body["recipient_id"] = r }
        guard let d = try await api(id, "download", body)["direct_link"] as? String, let u = URL(string: d) else { throw LoaderError.parse(L("WeTransfer не выдал ссылку на файл", "WeTransfer didn't return a file link")) }
        return u
    }
}

enum MailRu {
    static func weblink(_ link: String) -> String? {
        guard let r = link.range(of: "/public/") else { return nil }
        var w = String(link[r.upperBound...]).components(separatedBy: "?").first ?? ""
        while w.hasSuffix("/") { w.removeLast() }
        return w.removingPercentEncoding ?? w
    }
    static func folder(_ w: String, offset: Int) async throws -> [String: Any] {
        var c = URLComponents(string: "https://cloud.mail.ru/api/v2/folder")!
        c.queryItems = [.init(name: "weblink", value: w), .init(name: "offset", value: "\(offset)"), .init(name: "limit", value: "500")]
        return ((try await requestJSON(c.url!)) as? [String: Any])?["body"] as? [String: Any] ?? [:]
    }
    static func list(_ link: String) async throws -> ListResult {
        guard let w = weblink(link) else { throw LoaderError.badLink }
        let root = try await folder(w, offset: 0)
        let name = root["name"] as? String ?? "Mail.ru"
        if root["kind"] as? String == "file" {
            return ListResult(rootName: "", files: [RemoteFile(relPath: name, size: (root["size"] as? NSNumber)?.int64Value, source: .mailru(weblink: w))], skipped: [])
        }
        var out: [RemoteFile] = []
        try await walk(w, rel: "", into: &out, depth: 0)
        return ListResult(rootName: name, files: out, skipped: [])
    }
    static func walk(_ w: String, rel: String, into out: inout [RemoteFile], depth: Int) async throws {
        if depth > 30 { return }
        var offset = 0
        while true {
            let b = try await folder(w, offset: offset)
            let items = b["list"] as? [[String: Any]] ?? []
            for it in items {
                let n = it["name"] as? String ?? "?"; let r = rel.isEmpty ? n : rel + "/" + n
                let wl = it["weblink"] as? String ?? (w + "/" + n)
                if it["kind"] as? String == "folder" { try await walk(wl, rel: r, into: &out, depth: depth + 1) }
                else { out.append(RemoteFile(relPath: r, size: (it["size"] as? NSNumber)?.int64Value, source: .mailru(weblink: wl))) }
            }
            offset += items.count
            let cnt = b["count"] as? [String: Any]; let total = ((cnt?["files"] as? Int) ?? 0) + ((cnt?["folders"] as? Int) ?? 0)
            if items.isEmpty || offset >= total { break }
        }
    }
    static func resolve(_ w: String) async throws -> URL {
        let d = ((try await requestJSON(URL(string: "https://cloud.mail.ru/api/v2/dispatcher")!)) as? [String: Any])?["body"] as? [String: Any]
        guard let base = ((d?["weblink_get"] as? [[String: Any]])?.first?["url"] as? String) else { throw LoaderError.parse(L("Облако Mail.ru не выдало сервер загрузки", "Mail.ru Cloud didn't return a download server")) }
        let path = w.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: base + "/" + path)!
    }
}

enum OneDrive {
    static func token(_ link: String) -> String {
        let b = Data(link.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return "u!" + b
    }
    static func item(_ t: String, _ path: String) async throws -> [String: Any] {
        (try await requestJSON(URL(string: "https://api.onedrive.com/v1.0/shares/\(t)/\(path)")!, headers: ["Prefer": "autoredeem"])) as? [String: Any] ?? [:]
    }
    static func list(_ link: String) async throws -> ListResult {
        let t = token(link)
        let root = try await item(t, "root?expand=children")
        let name = root["name"] as? String ?? "OneDrive"
        if root["folder"] == nil {
            return ListResult(rootName: "", files: [RemoteFile(relPath: name, size: (root["size"] as? NSNumber)?.int64Value, source: .onedrive(token: t, itemID: root["id"] as? String ?? ""))], skipped: [])
        }
        var out: [RemoteFile] = []
        try await walk(t, root, rel: "", into: &out, depth: 0)
        return ListResult(rootName: name, files: out, skipped: [])
    }
    static func walk(_ t: String, _ node: [String: Any], rel: String, into out: inout [RemoteFile], depth: Int) async throws {
        if depth > 30 { return }
        var children = node["children"] as? [[String: Any]] ?? []
        var next = node["children@odata.nextLink"] as? String
        while let n = next, let u = URL(string: n) {
            let j = (try await requestJSON(u)) as? [String: Any] ?? [:]
            children += j["value"] as? [[String: Any]] ?? []; next = j["@odata.nextLink"] as? String
        }
        for c in children {
            let nm = c["name"] as? String ?? "?"; let r = rel.isEmpty ? nm : rel + "/" + nm; let id = c["id"] as? String ?? ""
            if c["folder"] != nil { try await walk(t, try await item(t, "items/\(id)?expand=children"), rel: r, into: &out, depth: depth + 1) }
            else { out.append(RemoteFile(relPath: r, size: (c["size"] as? NSNumber)?.int64Value, source: .onedrive(token: t, itemID: id))) }
        }
    }
    static func resolve(token t: String, itemID: String) async throws -> URL {
        let j = try await item(t, itemID.isEmpty ? "root" : "items/\(itemID)")
        guard let s = j["@content.downloadUrl"] as? String, let u = URL(string: s) else { throw LoaderError.parse(L("OneDrive не выдал ссылку — возможно, владелец запретил скачивание", "OneDrive didn't return a link \u{2014} the owner may have blocked downloads")) }
        return u
    }
}

enum PCloud {
    static func code(_ link: String) -> String? { URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.queryItems?.first { $0.name == "code" }?.value }
    static func call(_ api: String, _ method: String, _ q: [URLQueryItem]) async throws -> [String: Any] {
        var c = URLComponents(string: "https://\(api)/\(method)")!; c.queryItems = q
        return (try await requestJSON(c.url!)) as? [String: Any] ?? [:]
    }
    static func list(_ link: String) async throws -> ListResult {
        guard let code = code(link) else { throw LoaderError.badLink }
        // у pCloud два региона: США и Европа — пробуем оба
        let hosts = link.contains("e.pcloud") ? ["eapi.pcloud.com", "api.pcloud.com"] : ["api.pcloud.com", "eapi.pcloud.com"]
        for api in hosts {
            let j = try await call(api, "showpublink", [.init(name: "code", value: code)])
            guard (j["result"] as? Int) == 0, let meta = j["metadata"] as? [String: Any] else { continue }
            let name = meta["name"] as? String ?? "pCloud"
            if (meta["isfolder"] as? Bool) != true {
                return ListResult(rootName: "", files: [RemoteFile(relPath: name, size: (meta["size"] as? NSNumber)?.int64Value, source: .pcloud(api: api, code: code, fileID: nil))], skipped: [])
            }
            var out: [RemoteFile] = []
            walk(meta, api: api, code: code, rel: "", into: &out)
            return ListResult(rootName: name, files: out, skipped: [])
        }
        throw LoaderError.parse(L("pCloud: ссылка недействительна или закрыта", "pCloud: the link is invalid or closed"))
    }
    static func walk(_ m: [String: Any], api: String, code: String, rel: String, into out: inout [RemoteFile]) {
        for c in m["contents"] as? [[String: Any]] ?? [] {
            let n = c["name"] as? String ?? "?"; let r = rel.isEmpty ? n : rel + "/" + n
            if (c["isfolder"] as? Bool) == true { walk(c, api: api, code: code, rel: r, into: &out) }
            else { out.append(RemoteFile(relPath: r, size: (c["size"] as? NSNumber)?.int64Value, source: .pcloud(api: api, code: code, fileID: (c["fileid"] as? NSNumber)?.int64Value))) }
        }
    }
    static func resolve(api: String, code: String, fileID: Int64?) async throws -> URL {
        var q: [URLQueryItem] = [.init(name: "code", value: code)]
        if let f = fileID { q.append(.init(name: "fileid", value: "\(f)")) }
        let j = try await call(api, "getpublinkdownload", q)
        guard let host = (j["hosts"] as? [String])?.first, let path = j["path"] as? String, let u = URL(string: "https://\(host)\(path)") else {
            throw LoaderError.parse(L("pCloud не выдал ссылку — возможно, исчерпан лимит трафика ссылки", "pCloud didn't return a link \u{2014} the link's traffic limit may be exhausted"))
        }
        return u
    }
}

// MARK: - Медиа: видео и музыка с площадок (движок yt-dlp + ffmpeg, качаются при первом использовании)

struct MediaInfo { let title: String; let site: String; let duration: Double?; let thumb: URL?; let isPlaylist: Bool; var heights: [Int] = [] }

enum Media {
    static let musicHosts = ["soundcloud.com", "bandcamp.com", "mixcloud.com", "audiomack.com", "open.spotify.com", "spotify.link", "music.youtube.com", "music.apple.com"]
    static var bin: URL { History.url.deletingLastPathComponent().appendingPathComponent("bin") }
    static var ytdlpDir: URL { bin.appendingPathComponent("yt-dlp-app") }
    static var ytdlp: URL { ytdlpDir.appendingPathComponent("yt-dlp_macos") }   // версия-папка: стартует за доли секунды
    static var ffmpeg: URL { bin.appendingPathComponent("ffmpeg") }
    static var ready: Bool { FileManager.default.isExecutableFile(atPath: ytdlp.path) && FileManager.default.isExecutableFile(atPath: ffmpeg.path) }

    /// движки скачиваются один раз (~60 МБ); yt-dlp обновляется сам раз в сутки — площадки часто меняют защиту
    static func ensure(_ status: @escaping (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func get(_ url: String, to dest: URL, what: String) async throws {
            let raw = Raw(); let fid = UUID()
            let t = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                let (b, e, _, _) = raw.snapshot()
                status(L("Готовлю \(what) (один раз)… ", "Preparing \(what) (one time)… ") + (e > 0 ? "\(Int(Double(b) / Double(e) * 100)) %" : fmtBytes(b)))
            }
            defer { t.invalidate() }
            _ = try await downloadFile(urls: [URL(string: url)!], dest: dest, renameFromServer: false, raw: raw, fid: fid, knownSize: nil, conns: 4)
        }
        if !FileManager.default.isExecutableFile(atPath: ytdlp.path) {
            try await installYtdlp { url, dest in try await get(url, to: dest, what: L("видеодвижок", "the video engine")) }
            UserDefaults.standard.set(Date(), forKey: "ytdlpChecked")
        }
        try? FileManager.default.removeItem(at: bin.appendingPathComponent("yt-dlp"))   // старая медленная версия-файл
        if !FileManager.default.isExecutableFile(atPath: ffmpeg.path) {
            log("МЕДИА: качаю ffmpeg")
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "amd64"
            #endif
            let zip = bin.appendingPathComponent("ffmpeg.zip")
            try await get("https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/ffmpeg.zip", to: zip, what: L("ffmpeg для склейки видео", "ffmpeg for merging video"))
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, bin.path]
            try p.run(); p.waitUntilExit(); try? FileManager.default.removeItem(at: zip)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
        }
        // раз в сутки — тихое обновление yt-dlp
        let last = UserDefaults.standard.object(forKey: "ytdlpChecked") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 86_400 {
            UserDefaults.standard.set(Date(), forKey: "ytdlpChecked")
            Task.detached {
                guard let j = try? await requestJSON(URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!) as? [String: Any],
                      let tag = j["tag_name"] as? String, let cur = try? await run(["--version"]) else { return }
                let have = cur.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if tag != have {
                    log("МЕДИА: обновляю yt-dlp \(have) → \(tag)")
                    try? await installYtdlp { url, dest in
                        _ = try await downloadFile(urls: [URL(string: url)!], dest: dest, renameFromServer: false, raw: Raw(), fid: UUID(), knownSize: nil, conns: 4) }
                }
            }
        }
    }

    /// yt-dlp в виде папки (zip): скачать и подменить целиком
    static func installYtdlp(_ get: (String, URL) async throws -> Void) async throws {
        log("МЕДИА: качаю yt-dlp")
        let zip = bin.appendingPathComponent("yt-dlp.zip"), tmp = bin.appendingPathComponent("yt-dlp-new")
        try? FileManager.default.removeItem(at: zip); try? FileManager.default.removeItem(at: tmp)
        try await get("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip", zip)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, tmp.path]
        try p.run(); p.waitUntilExit(); try? FileManager.default.removeItem(at: zip)
        guard FileManager.default.fileExists(atPath: tmp.appendingPathComponent("yt-dlp_macos").path) else { throw LoaderError.parse(L("не удалось распаковать видеодвижок", "couldn't unpack the video engine")) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.appendingPathComponent("yt-dlp_macos").path)
        try? FileManager.default.removeItem(at: ytdlpDir)
        try FileManager.default.moveItem(at: tmp, to: ytdlpDir)
    }

    static func cookieArgs() -> [String] {
        let b = UserDefaults.standard.string(forKey: "cookiesBrowser") ?? ""
        return b.isEmpty ? [] : ["--cookies-from-browser", b]
    }

    /// запустить yt-dlp и дождаться
    static func run(_ args: [String]) async throws -> (out: String, err: String, code: Int32) {
        try await withCheckedThrowingContinuation { c in
            let p = Process(); p.executableURL = ytdlp; p.arguments = args
            let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
            DispatchQueue.global().async {
                do { try p.run() } catch { c.resume(throwing: error); return }
                let od = o.fileHandleForReading.readDataToEndOfFile(); let ed = e.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: (String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self), p.terminationStatus))
            }
        }
    }

    static func errorText(_ err: String) -> String {
        let line = err.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? err.split(separator: "\n").last.map(String.init) ?? ""
        let l = line.lowercased()
        // сеть: сайт не находится / недоступен (VPN, провайдер, нет интернета)
        if l.contains("could not resolve host") || l.contains("dns") || l.contains("name or service not known") || l.contains("nodename nor servname") {
            let host = err.range(of: #"resolve host: ([A-Za-z0-9.\-]+)"#, options: .regularExpression).map { String(err[$0]).replacingOccurrences(of: "resolve host: ", with: "") } ?? L("сайтом", "the site")
            return L("Не удаётся связаться с \(host) — сайт недоступен в этой сети. Проверь интернет или включи/выключи VPN и попробуй снова.",
                     "Can't reach \(host) \u{2014} the site isn't reachable on this network. Check your internet or turn VPN on/off and try again.")
        }
        if l.contains("timed out") || l.contains("connection reset") || l.contains("transporterror") || l.contains("unable to download webpage") {
            return L("Площадка не ответила — похоже, проблема с сетью или VPN. Попробуй ещё раз чуть позже.", "The site didn't respond \u{2014} looks like a network or VPN issue. Try again a bit later.")
        }
        if l.contains("sign in") || l.contains("login") || l.contains("cookies") || l.contains("confirm you") {
            return L("Площадка просит вход. Включи «Вход через браузер» в Настройках и попробуй снова.", "The site requires sign-in. Turn on \u{201c}Sign in via browser\u{201d} in Settings and try again.") }
        if l.contains("private") { return L("Это приватное видео — скачать без доступа нельзя.", "This video is private.") }
        if l.contains("unsupported url") { return L("Эта ссылка не поддерживается.", "This link isn't supported.") }
        if l.contains("not available") || l.contains("unavailable") { return L("Видео недоступно (удалено или закрыто в этой стране).", "The video is unavailable (removed or blocked in this country).") }
        if l.contains("requested format") { return L("Нужного качества нет — выбери другое.", "That quality isn't available \u{2014} pick another.") }
        return line.replacingOccurrences(of: "ERROR: ", with: "")
    }

    static func prettySite(_ k: String) -> String {
        let map = ["youtube": "YouTube", "tiktok": "TikTok", "soundcloud": "SoundCloud", "instagram": "Instagram", "vimeo": "Vimeo", "vk": "VK",
                   "vkplay": "VK Видео", "twitter": "X (Twitter)", "facebook": "Facebook", "bandcamp": "Bandcamp", "mixcloud": "Mixcloud", "twitch": "Twitch",
                   "rutube": "Rutube", "dailymotion": "Dailymotion", "pinterest": "Pinterest", "reddit": "Reddit", "youtubemusic": "YouTube Music"]
        return map[k.lowercased()] ?? k
    }
    static func clean(_ s: String) -> String { safeName(s).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }

    /// что по ссылке: одно видео/трек или плейлист
    static func list(_ link: String, music: Bool, status: @escaping (String) -> Void) async throws -> (ListResult, MediaInfo) {
        if link.contains("spotify") { return try await Spotify.list(link) }
        try await ensure(status)
        status(L("Читаю ссылку…", "Reading the link…"))
        let r = try await run(["-J", "--flat-playlist", "--no-warnings"] + cookieArgs() + [link])
        guard r.code == 0, let j = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else { throw LoaderError.parse(errorText(r.err)) }
        let site = prettySite((j["extractor_key"] as? String ?? j["ie_key"] as? String ?? "").replacingOccurrences(of: "Tab", with: ""))
        let q = music ? "audio" : "2160"
        if (j["_type"] as? String) == "playlist" {
            let entries = (j["entries"] as? [[String: Any]] ?? [])
            let files = entries.enumerated().map { i, e -> RemoteFile in
                let t = (e["title"] as? String) ?? "\(i + 1)"
                let u = (e["url"] as? String) ?? (e["webpage_url"] as? String) ?? ""
                return RemoteFile(relPath: String(format: "%03d ", i + 1) + clean(t), size: nil, source: .media(url: u, quality: q, site: site))
            }
            let title = clean(j["title"] as? String ?? site)
            return (ListResult(rootName: title, files: files, skipped: []), MediaInfo(title: title, site: site, duration: nil, thumb: nil, isPlaylist: true))
        }
        let title = clean(j["title"] as? String ?? "video")
        let thumb = (j["thumbnail"] as? String).flatMap(URL.init(string:))
        // какие качества реально есть у ролика (по стандартным ступеням)
        let hs = Set((j["formats"] as? [[String: Any]] ?? []).compactMap { $0["height"] as? Int })
        // каждую реальную высоту относим к ближайшей ступени не выше её
        let std = [2160, 1440, 1080, 720, 480, 360, 240, 144]
        let steps = Array(Set(hs.compactMap { h in std.first { $0 <= Int(Double(h) * 1.05) } })).sorted(by: >)
        let f = RemoteFile(relPath: title, size: nil, source: .media(url: (j["webpage_url"] as? String) ?? link, quality: q, site: site))
        return (ListResult(rootName: "", files: [f], skipped: []), MediaInfo(title: title, site: site, duration: j["duration"] as? Double, thumb: thumb, isPlaylist: false, heights: steps))
    }

    /// скачать одно видео/трек; прогресс — в raw, пауза — остановкой процесса (докачка через .part)
    static func download(url: String, quality: String, dir: URL, name: String, raw: Raw, fid: UUID) async throws -> URL {
        try await ensure { _ in }
        var args = [url, "--no-playlist", "--newline", "--no-warnings", "--progress", "-c",
                    "--progress-template", "download:DLP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
                    "--print", "after_move:FINAL|%(filepath)s",
                    "-P", dir.path, "-o", name + ".%(ext)s", "--ffmpeg-location", ffmpeg.path] + cookieArgs()
        if quality == "audio" { args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"] }
        else {
            args += ["-f", "bv*+ba/b", "--merge-output-format", "mp4", "--concurrent-fragments", "8",
                     "-S", (Int(quality) == nil ? "res" : "res:\(quality)") + ",vcodec:avc1,acodec:m4a,ext:mp4:m4a"]
        }
        let p = Process(); p.executableURL = ytdlp; p.arguments = args
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        var final: String? = nil; var errText = ""
        var phaseBase: Int64 = 0, lastD: Int64 = 0, lastT: Int64 = 0
        let lock = NSLock()
        o.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
                if line.hasPrefix("DLP|") {
                    let v = line.split(separator: "|", omittingEmptySubsequences: false).map { Int64(Double($0) ?? -1) }
                    guard v.count >= 4 else { continue }
                    let dn = max(0, v[1]); let tot = v[2] > 0 ? v[2] : max(0, v[3])
                    lock.lock()
                    if dn + 1_000_000 < lastD { phaseBase += max(lastT, lastD) }   // началась следующая часть (видео → звук)
                    lastD = dn; lastT = tot
                    raw.setBytes(fid, phaseBase + dn, expected: phaseBase + tot)
                    lock.unlock()
                } else if line.hasPrefix("FINAL|") { final = String(line.dropFirst(6)) }
            }
        }
        e.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { lock.lock(); errText += String(decoding: d, as: UTF8.self); lock.unlock() } }
        try p.run()
        await withTaskCancellationHandler {
            while p.isRunning {
                if raw.cancelled { p.terminate() }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        } onCancel: { p.terminate() }
        o.fileHandleForReading.readabilityHandler = nil; e.fileHandleForReading.readabilityHandler = nil
        if raw.cancelled || Task.isCancelled { throw CancellationError() }
        guard p.terminationStatus == 0 else { throw LoaderError.parse(errorText(errText)) }
        let out = final.map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent(name)
        // итоговый размер — по самому файлу (если ролик уже был скачан, прогресса от yt-dlp нет)
        let sz = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? raw.snapshot().0
        raw.setBytes(fid, max(sz, 1), expected: max(sz, 1))
        return out
    }
}

/// Spotify защищён от скачивания: берём название и исполнителя, а звук находим на YouTube Music
enum Spotify {
    static func list(_ link: String) async throws -> (ListResult, MediaInfo) {
        guard let r = link.range(of: #"(track|album|playlist)/[A-Za-z0-9]+"#, options: .regularExpression) else { throw LoaderError.badLink }
        var req = URLRequest(url: URL(string: "https://open.spotify.com/embed/" + link[r])!); req.setValue(UA, forHTTPHeaderField: "User-Agent")
        let html = String(decoding: try await URLSession.shared.data(for: req).0, as: UTF8.self)
        guard let js = Google.match(html, #"<script id="__NEXT_DATA__"[^>]*>(.*?)</script>"#).first,
              let d = try? JSONSerialization.jsonObject(with: Data(js.utf8)) as? [String: Any],
              let e = (((d["props"] as? [String: Any])?["pageProps"] as? [String: Any])?["state"] as? [String: Any]).flatMap({ ($0["data"] as? [String: Any])?["entity"] as? [String: Any] })
        else { throw LoaderError.parse(L("Spotify не отдал данные — проверь, что ссылка открыта", "Spotify returned no data \u{2014} check that the link is public")) }
        func f(_ title: String, _ artist: String, _ i: Int?) -> RemoteFile {
            let name = Media.clean(artist.isEmpty ? title : artist + " - " + title)
            return RemoteFile(relPath: (i.map { String(format: "%03d ", $0) } ?? "") + name, size: nil,
                              source: .media(url: "ytsearch1:" + (artist.isEmpty ? title : artist + " " + title) + " audio", quality: "audio", site: "Spotify"))
        }
        let thumb = ((e["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]])?.first?["url"] as? String
        let list = e["trackList"] as? [[String: Any]] ?? []
        if list.isEmpty {
            let t = e["name"] as? String ?? e["title"] as? String ?? "track"
            let a = (e["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
            return (ListResult(rootName: "", files: [f(t, a, nil)], skipped: []),
                    MediaInfo(title: Media.clean(a.isEmpty ? t : a + " - " + t), site: "Spotify", duration: (e["duration"] as? Double).map { $0 / 1000 }, thumb: thumb.flatMap(URL.init(string:)), isPlaylist: false))
        }
        let files = list.enumerated().map { i, t in f(t["title"] as? String ?? "", (t["subtitle"] as? String ?? "").replacingOccurrences(of: "\u{a0}", with: " "), i + 1) }
        let title = Media.clean(e["name"] as? String ?? e["title"] as? String ?? "Spotify")
        return (ListResult(rootName: title, files: files, skipped: []), MediaInfo(title: title, site: "Spotify", duration: nil, thumb: thumb.flatMap(URL.init(string:)), isPlaylist: true))
    }
}

func dispositionName(_ h: String?) -> String? {
    guard let h else { return nil }
    if let r = h.range(of: #"filename\*=UTF-8''([^;]+)"#, options: .regularExpression) {
        return String(h[r]).replacingOccurrences(of: "filename*=UTF-8''", with: "").removingPercentEncoding
    }
    if let r = h.range(of: #"filename="([^"]+)""#, options: .regularExpression) {
        return String(h[r]).replacingOccurrences(of: "filename=", with: "").replacingOccurrences(of: "\"", with: "")
    }
    return nil
}

func safeName(_ s: String) -> String { s.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-") }

func fmtBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]; f.allowsNonnumericFormatting = false; return f.string(fromByteCount: b)
}

// MARK: - Журнал (~/Library/Logs/MegaLoader.log)

let logURL: URL = {
    let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("MegaLoader.log")
}()
let logQueue = DispatchQueue(label: "log")
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    logQueue.async {
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.data(using: .utf8)!.write(to: logURL) }
    }
}

// MARK: - История

extension Int { var nonZero: Int? { self == 0 ? nil : self } }

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    let date: Date; let title: String; let provider: String; let link: String; let path: String
    let files: Int; let total: Int; let bytes: Int64; let state: String
    var seconds: Double? = nil
    var bookmark: Data? = nil
    var site: String? = nil
}
enum History {
    static let url: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DiskLoader")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("history.json")
    }()
    static func load() -> [HistoryItem] { (try? JSONDecoder().decode([HistoryItem].self, from: Data(contentsOf: url))) ?? [] }
    static func save(_ h: [HistoryItem]) { try? JSONEncoder().encode(Array(h.prefix(500))).write(to: url) }
}

// MARK: - Сырые счётчики (без перерисовки интерфейса на каждый кусок)

final class Raw: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UUID: Int64] = [:], expected: [UUID: Int64] = [:]
    private var resumed: Int64 = 0                     // докачанное с прошлого раза — не считается в скорость
    private var tasks: [URLSessionTask] = []
    private(set) var cancelled = false
    func setExpected(_ f: UUID, _ n: Int64) { lock.lock(); expected[f] = n; lock.unlock() }
    func add(_ f: UUID, _ n: Int64) { lock.lock(); bytes[f, default: 0] += n; lock.unlock() }
    func addResumed(_ f: UUID, _ n: Int64) { lock.lock(); bytes[f, default: 0] += n; resumed += n; lock.unlock() }
    func reset(_ f: UUID) { lock.lock(); bytes[f] = 0; lock.unlock() }
    func setBytes(_ f: UUID, _ n: Int64, expected e: Int64) { lock.lock(); bytes[f] = n; if e > 0 { expected[f] = e }; lock.unlock() }
    func bytesOf(_ f: UUID) -> Int64 { lock.lock(); defer { lock.unlock() }; return bytes[f] ?? 0 }
    func track(_ t: URLSessionTask) -> Bool { lock.lock(); defer { lock.unlock() }; if cancelled { t.cancel(); return false }; tasks.append(t); tasks.removeAll { $0.state == .completed }; return true }
    func cancelAll() { lock.lock(); cancelled = true; let t = tasks; lock.unlock(); t.forEach { $0.cancel() } }
    func resume() { lock.lock(); cancelled = false; tasks = []; lock.unlock() }
    func clear() { lock.lock(); bytes = [:]; expected = [:]; resumed = 0; lock.unlock() }
    func snapshot() -> (Int64, Int64, Int64, [UUID: Double]) {
        lock.lock(); defer { lock.unlock() }
        var prog: [UUID: Double] = [:]
        for (f, b) in bytes { if let e = expected[f], e > 0 { prog[f] = min(1, Double(b) / Double(e)) } else { prog[f] = -1 } }
        return (bytes.values.reduce(0, +), expected.values.reduce(0, +), resumed, prog)
    }
}

// MARK: - Движок: каждый файл — в несколько потоков по частям, с докачкой и повторами

struct SegState: Codable { var size: Int64; var url: String; var segs: [[Int64]] }   // [начало, конец, скачано]

/// общий лимит одновременных подключений на всё приложение (иначе серверы душат и соединения висят)
actor Gate {
    static let shared = Gate()
    private var used = 0; private var waiting: [CheckedContinuation<Void, Never>] = []
    var limit: Int { max(2, UserDefaults.standard.integer(forKey: "totalConns").nonZero ?? 16) }
    func acquire() async throws {
        // простое ожидание с проверкой отмены: остановка задачи прерывает его сразу
        while used >= limit {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        used += 1
    }
    func release() { used = max(0, used - 1) }
}

final class Engine: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = Engine()
    final class Sink {
        let handle: FileHandle; var offset: UInt64; let wantRange: Bool
        let onBytes: (Int64) -> Void; var cont: CheckedContinuation<Void, Error>?; var error: Error?
        init(handle: FileHandle, offset: UInt64, wantRange: Bool, onBytes: @escaping (Int64) -> Void) {
            self.handle = handle; self.offset = offset; self.wantRange = wantRange; self.onBytes = onBytes
        }
    }
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: Sink] = [:]
    private(set) var session: URLSession!
    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 64
        cfg.timeoutIntervalForRequest = 60; cfg.timeoutIntervalForResource = 60 * 60 * 24
        cfg.httpAdditionalHeaders = ["User-Agent": UA]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData; cfg.urlCache = nil
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .userInitiated
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)   // одна сессия на всё приложение
    }

    /// скачать байты [from...to] (to = nil — до конца) в файл с позиции offset
    func fetch(_ url: URL, from: Int64, to: Int64?, into handle: FileHandle, offset: UInt64, raw: Raw, onBytes: @escaping (Int64) -> Void) async throws {
        try await Gate.shared.acquire()
        defer { Task { await Gate.shared.release() } }
        if raw.cancelled || Task.isCancelled { throw CancellationError() }
        var req = URLRequest(url: url)
        if isDropboxHost(url) { req.setValue(dropboxUA, forHTTPHeaderField: "User-Agent") }
        let wantRange = from > 0 || to != nil
        if wantRange { req.setValue("bytes=\(from)-" + (to.map(String.init) ?? ""), forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: req)
        let sink = Sink(handle: handle, offset: offset, wantRange: wantRange, onBytes: onBytes)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                sink.cont = c
                lock.lock(); sinks[ObjectIdentifier(task)] = sink; lock.unlock()
                if raw.track(task) { task.resume() } else { finish(task, CancellationError()) }
            }
        } onCancel: { task.cancel() }
    }
    private func finish(_ t: URLSessionTask, _ err: Error?) {
        lock.lock(); let s = sinks.removeValue(forKey: ObjectIdentifier(t)); lock.unlock()
        guard let s, let c = s.cont else { return }
        s.cont = nil
        if let e = s.error ?? err { c.resume(throwing: e) } else { c.resume() }
    }
    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive r: URLResponse, completionHandler ch: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let sink = sinks[ObjectIdentifier(t)]; lock.unlock()
        let code = (r as? HTTPURLResponse)?.statusCode ?? 200
        if code >= 400 { sink?.error = LoaderError.http(code); ch(.cancel); return }
        if sink?.wantRange == true && code != 206 { sink?.error = LoaderError.parse(L("сервер не поддерживает докачку частями", "the server doesn't support partial downloads")); ch(.cancel); return }
        ch(.allow)
    }
    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let sink = sinks[ObjectIdentifier(t)]; lock.unlock()
        guard let sink else { return }
        do { try sink.handle.seek(toOffset: sink.offset); try sink.handle.write(contentsOf: data) }
        catch { sink.error = error; t.cancel(); return }
        sink.offset += UInt64(data.count); sink.onBytes(Int64(data.count))
    }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError err: Error?) { finish(t, err) }

    struct Probe { let url: URL; let size: Int64?; let ranges: Bool; let name: String?; let html: Bool }
    /// узнать размер, поддержку частей и имя, не скачивая файл
    static func probe(_ url: URL) async throws -> Probe {
        var req = URLRequest(url: url); req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue(isDropboxHost(url) ? dropboxUA : UA, forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let h = resp as? HTTPURLResponse else { throw LoaderError.parse(L("нет ответа", "no response")) }
        let type = h.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/html") {
            var html = Data(); for try await b in bytes { html.append(b); if html.count > 400_000 { break } }
            return Probe(url: h.url ?? url, size: nil, ranges: false, name: nil, html: true).with(html: String(decoding: html, as: UTF8.self))
        }
        bytes.task.cancel()
        if h.statusCode >= 400 { throw LoaderError.http(h.statusCode) }
        let name = dispositionName(h.value(forHTTPHeaderField: "Content-Disposition"))
        if h.statusCode == 206, let cr = h.value(forHTTPHeaderField: "Content-Range"), let total = cr.split(separator: "/").last.flatMap({ Int64($0) }) {
            return Probe(url: h.url ?? url, size: total, ranges: true, name: name, html: false)
        }
        return Probe(url: h.url ?? url, size: h.expectedContentLength > 0 ? h.expectedContentLength : nil, ranges: false, name: name, html: false)
    }
}
extension Engine.Probe {
    func with(html: String) -> Engine.Probe { Engine.lastHTML = html; return self }
}
extension Engine { nonisolated(unsafe) static var lastHTML = "" }

/// один и тот же файл на диске не качают две задачи сразу
actor ActiveFiles {
    static let shared = ActiveFiles()
    private var busy: Set<String> = []
    func lock(_ p: String) async throws { while busy.contains(p) { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 300_000_000) }; busy.insert(p) }
    func unlock(_ p: String) { busy.remove(p) }
}

/// скачать один файл максимально быстро: части параллельно, докачка с места обрыва, повторы при сбоях
func downloadFile(urls: [URL], dest: URL, renameFromServer: Bool, raw: Raw, fid: UUID, knownSize: Int64?, conns: Int) async throws -> URL {
    // 1. какой адрес живой, размер, части
    var probe: Engine.Probe? = nil; var lastErr: Error = LoaderError.parse(L("нет адреса", "no address"))
    for u in urls {
        do {
            var p = try await Engine.probe(u)
            if p.html, let real = Google.confirmURL(fromHTML: Engine.lastHTML) {
                log("    Google вернул страницу-предупреждение — беру ссылку из неё"); p = try await Engine.probe(real)
            }
            if p.html { throw LoaderError.parse(L("вместо файла пришла веб-страница (доступ закрыт или сервис что-то поменял)", "got a web page instead of the file (access is closed or the service changed something)")) }
            probe = p; break
        } catch { lastErr = error; log("    адрес не сработал: \(u.host ?? "") — \(error.localizedDescription)") }
    }
    guard let p = probe else { throw lastErr }
    var final = dest
    if renameFromServer, let n = p.name { final = dest.deletingLastPathComponent().appendingPathComponent(safeName(n)) }
    let size = p.size ?? knownSize
    if let size { raw.setExpected(fid, size) }
    // уже скачан целиком — пропускаем
    if let size, let a = try? FileManager.default.attributesOfItem(atPath: final.path), (a[.size] as? NSNumber)?.int64Value == size {
        raw.addResumed(fid, size); log("    уже есть, пропускаю: \(final.lastPathComponent)"); return final
    }
    try await ActiveFiles.shared.lock(final.path)
    defer { Task { await ActiveFiles.shared.unlock(final.path) } }
    if let size, let a = try? FileManager.default.attributesOfItem(atPath: final.path), (a[.size] as? NSNumber)?.int64Value == size {
        raw.addResumed(fid, size); return final
    }
    let part = URL(fileURLWithPath: final.path + ".part"), stateURL = URL(fileURLWithPath: final.path + ".part.json")
    // 2. план частей (или продолжение прошлого)
    var st: SegState
    if let d = try? Data(contentsOf: stateURL), let old = try? JSONDecoder().decode(SegState.self, from: d), old.size == (size ?? -1),
       FileManager.default.fileExists(atPath: part.path) {
        st = old; let done = st.segs.map { $0[2] }.reduce(0, +); raw.addResumed(fid, done)
        log("    докачка с \(fmtBytes(done)) из \(fmtBytes(old.size))")
    } else {
        try? FileManager.default.removeItem(at: part)
        FileManager.default.createFile(atPath: part.path, contents: nil)
        if let size, p.ranges, size > 16 * 1_048_576 {
            let n = Int(min(Int64(max(1, conns)), max(1, size / (8 * 1_048_576))))
            let chunk = size / Int64(n)
            st = SegState(size: size, url: p.url.absoluteString, segs: (0..<n).map { i in
                let a = Int64(i) * chunk; let b = i == n - 1 ? size - 1 : a + chunk - 1; return [a, b, 0] })
            let h = try FileHandle(forWritingTo: part); try h.truncate(atOffset: UInt64(size)); try h.close()
        } else {
            st = SegState(size: size ?? -1, url: p.url.absoluteString, segs: [[0, (size ?? 0) - 1, 0]])
        }
    }
    let ranged = st.segs.count > 1 || (p.ranges && st.segs[0][2] > 0)
    log("    \(final.lastPathComponent): \(size.map(fmtBytes) ?? "размер неизвестен"), потоков \(st.segs.count)" + (p.ranges ? "" : " (сервер не даёт качать частями)"))
    // 3. качаем части параллельно; каждая сама повторяет при сбое
    let stLock = NSLock(); var stBox = st; var finished = false
    let saveState = { stLock.lock(); let s = stBox; let f = finished; stLock.unlock(); if !f { try? JSONEncoder().encode(s).write(to: stateURL) } }
    let saver = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); saveState() } }
    defer { saver.cancel() }
    let url = p.url
    try await withThrowingTaskGroup(of: Void.self) { g in
        for i in st.segs.indices {
            g.addTask {
                var attempt = 0
                while true {
                    stLock.lock(); let seg = stBox.segs[i]; stLock.unlock()
                    let start = seg[0] + seg[2], end = seg[1]
                    if st.size > 0 && start > end { return }
                    try Task.checkCancellation()
                    let h = try FileHandle(forWritingTo: part)
                    defer { try? h.close() }
                    do {
                        try await Engine.shared.fetch(url, from: ranged || st.segs.count > 1 ? start : 0,
                                                      to: st.segs.count > 1 ? end : nil, into: h, offset: UInt64(start), raw: raw) { n in
                            stLock.lock(); stBox.segs[i][2] += n; stLock.unlock(); raw.add(fid, n)
                        }
                        return
                    } catch {
                        if raw.cancelled || error is CancellationError { saveState(); throw CancellationError() }
                        if case LoaderError.http(let c) = error, [401, 403, 404, 410].contains(c) { saveState(); throw error }
                        attempt += 1
                        if attempt > 6 { saveState(); throw error }
                        if st.segs.count == 1 && !p.ranges { stLock.lock(); stBox.segs[i][2] = 0; stLock.unlock(); raw.reset(fid) }
                        log("    сбой части \(i + 1) (\(human(error))), повтор \(attempt)/6")
                        try await Task.sleep(nanoseconds: UInt64(min(30, 1 << attempt)) * 1_000_000_000)
                    }
                }
            }
        }
        try await g.waitForAll()
    }
    // 4. готово
    stLock.lock(); finished = true; stLock.unlock(); saver.cancel()
    guard FileManager.default.fileExists(atPath: part.path) else { throw LoaderError.parse(L("недокачанный файл пропал с диска", "the partial file disappeared from the disk")) }
    if FileManager.default.fileExists(atPath: final.path) { _ = try FileManager.default.replaceItemAt(final, withItemAt: part) }
    else { try FileManager.default.moveItem(at: part, to: final) }
    try? FileManager.default.removeItem(at: stateURL)
    if size == nil { raw.setExpected(fid, raw.bytesOf(fid)) }
    return final
}

// MARK: - Задача загрузки (одна ссылка)

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: String, Equatable, Codable { case waiting, running, done, stopped, failed }
    let id: UUID
    let link: String
    let provider: Provider
    let title: String
    let files: [RemoteFile]
    @Published var base: URL
    var bookmark: Data? = nil
    @Published var folderProblem: String? = nil     // папку удалили — нужно выбрать новую
    @Published var state: State = .waiting
    @Published var doneCount = 0
    @Published var failed: [String] = []
    @Published var bytesDone: Int64 = 0
    @Published var expected: Int64 = 0        // известный общий объём (Яндекс заранее, Google по мере старта)
    @Published var speed: Double = 0
    @Published var fileProgress: [UUID: Double] = [:]
    @Published var current: String = ""
    let raw = Raw()
    var completed: Set<UUID> = []          // файлы, скачанные целиком — при продолжении не трогаем
    var runTask: Task<Void, Never>? = nil
    var gen = 0                              // номер запуска: старый запуск не трогает состояние нового
    var started = Date()
    var lastBytes: Int64 = 0
    var cancelled = false

    init(id: UUID = UUID(), link: String, provider: Provider, title: String, files: [RemoteFile], base: URL) {
        self.id = id; self.link = link; self.provider = provider; self.title = title; self.files = files; self.base = base
        expected = files.compactMap(\.size).reduce(0, +)
    }
    var progress: Double {
        if expected > 0 { return min(1, Double(bytesDone) / Double(expected)) }
        return Double(doneCount) / Double(max(1, files.count))
    }
    func tick(_ dt: Double) {
        let (now, exp, resumed, prog) = raw.snapshot()
        let net = now - resumed
        speed = speed * 0.5 + Double(max(0, net - lastBytes)) / dt * 0.5
        lastBytes = net; bytesDone = now
        if files.allSatisfy({ $0.size == nil }) { expected = exp }
        if prog != fileProgress { fileProgress = prog }
    }
}

// MARK: - Сохранение очереди между запусками

struct JobRecord: Codable { let id: UUID; let link: String; let provider: Provider; let title: String; let files: [RemoteFile]; let base: URL; let state: Job.State; var completed: Set<UUID>? = nil; var bookmark: Data? = nil }
enum QueueStore {
    static let url = History.url.deletingLastPathComponent().appendingPathComponent("queue.json")
    @MainActor static func save(_ jobs: [Job]) {
        let recs = jobs.map { JobRecord(id: $0.id, link: $0.link, provider: $0.provider, title: $0.title, files: $0.files, base: $0.base, state: $0.state, completed: $0.completed, bookmark: $0.bookmark) }
        try? JSONEncoder().encode(recs).write(to: url, options: .atomic)
    }
    static func load() -> [JobRecord] { (try? JSONDecoder().decode([JobRecord].self, from: Data(contentsOf: url))) ?? [] }
}

// MARK: - Менеджер: проверка ссылки, очередь, сеть

@MainActor
final class Manager: NSObject, ObservableObject {
    // ввод и предпросмотр
    @Published var link = ""
    @Published var provider: Provider?
    @Published var previewTitle = ""
    @Published var preview: [RemoteFile] = []
    @Published var skipped: [String] = []
    @Published var status = L("Вставь публичную ссылку — увидишь, что будет скачано", "Paste a public link to see what will be downloaded")
    @Published var busy = false
    @Published var selected: Set<UUID> = []      // выбранные файлы
    @Published var cwd: [String] = []             // текущая папка в браузере
    @Published var media: MediaInfo? = nil        // превью видео/трека
    @AppStorage("mediaQuality") var mediaQuality = "2160"
    // очередь
    @Published var jobs: [Job] = []
    @Published var lastDir: URL?
    @Published var page: Page = .download
    struct Summary: Equatable { var running = 0; var percent = 0; var speed: Double = 0 }
    @Published var summary = Summary()
    @Published var update: (version: String, url: URL, zip: URL?)? = nil
    @Published var updateProgress: Double? = nil     // nil — не качаем; 0…1 — загрузка обновления
    @Published var updateNote = ""
    static let defaultRepo = "rxtxrxr/MegaLoader"
    private var activity: NSObjectProtocol?

    var perJob: Int { max(1, UserDefaults.standard.integer(forKey: "perJob").nonZero ?? 4) }
    var maxJobs: Int { max(1, UserDefaults.standard.integer(forKey: "maxJobs").nonZero ?? 2) }
    @Published var history: [HistoryItem] = History.load()
    var conns: Int { max(1, UserDefaults.standard.integer(forKey: "conns").nonZero ?? 8) }
    private var timer: Timer?

    override init() {
        super.init()
        Task {
            await checkUpdate(manual: false)
            if ProcessInfo.processInfo.environment["DL_AUTOUPDATE"] != nil, update != nil { installUpdate() }   // для проверки обновления
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.checkUpdate(manual: false) } }
        if let pg = ProcessInfo.processInfo.environment["DL_PAGE"], let p = Page.allCases.first(where: { "\($0)" == pg }) { page = p }   // для проверки сборки
        if let l = ProcessInfo.processInfo.environment["DL_LINK"] { link = l; DispatchQueue.main.async { self.check() } }   // для проверки сборки
        // восстановить очередь: незаконченное продолжаем в том же порядке
        let recs = QueueStore.load()
        if !recs.isEmpty {
            jobs = recs.map { r in
                let j = Job(id: r.id, link: r.link, provider: r.provider, title: r.title, files: r.files, base: r.base)
                j.state = (r.state == .running) ? .waiting : r.state
                j.completed = r.completed ?? []
                j.bookmark = r.bookmark
                j.doneCount = j.completed.count
                for f in j.files where j.completed.contains(f.id) { if let sz = f.size { j.raw.setExpected(f.id, sz); j.raw.addResumed(f.id, sz) } }
                j.tick(0.25); j.speed = 0
                return j
            }
            // дубли (та же ссылка в ту же папку) склеиваем — иначе две задачи пишут в один файл
            var seen = Set<String>(); var uniq: [Job] = []
            for j in jobs.reversed() {
                let k = j.base.standardizedFileURL.path + "|" + j.files.map(\.relPath).sorted().joined(separator: "/")
                if j.link.isEmpty || ([.waiting, .stopped, .failed].contains(j.state) && seen.contains(k)) { log("  дубль задачи «\(j.title)» убран"); continue }
                seen.insert(k); uniq.insert(j, at: 0)
            }
            jobs = uniq; QueueStore.save(jobs)
            let resume = jobs.filter { $0.state == .waiting }.count
            log("ВОССТАНОВЛЕНА очередь: задач \(jobs.count), продолжаю \(resume)")
            if resume > 0 { status = L("Продолжаю незаконченные загрузки: \(resume)", "Resuming unfinished downloads: \(resume)") }
            DispatchQueue.main.async { self.pump() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let s = self else { return }
                let run = s.jobs.filter { $0.state == .running }
                run.forEach { $0.tick(0.25) }
                let p = run.isEmpty ? 0 : run.map(\.progress).reduce(0, +) / Double(run.count)
                let sum = Summary(running: run.count, percent: Int((p * 100).rounded()), speed: run.map(\.speed).reduce(0, +))
                if sum != s.summary { s.summary = sum }
            }
        }
    }

    var previewSize: Int64 { preview.compactMap(\.size).reduce(0, +) }
    var isSingleFile: Bool { previewTitle.isEmpty && preview.count == 1 }
    var selectedFiles: [RemoteFile] { preview.filter { selected.contains($0.id) } }

    // браузер папок
    func comps(_ f: RemoteFile) -> [String] { f.relPath.split(separator: "/").map(String.init) }
    func filesUnder(_ path: [String]) -> [RemoteFile] { preview.filter { Array(comps($0).prefix(path.count)) == path && comps($0).count > path.count } }
    var folderHere: [String] {
        var seen: [String] = []
        for f in preview { let c = comps(f); if c.count > cwd.count + 1, Array(c.prefix(cwd.count)) == cwd, !seen.contains(c[cwd.count]) { seen.append(c[cwd.count]) } }
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var filesHere: [RemoteFile] { preview.filter { let c = comps($0); return c.count == cwd.count + 1 && Array(c.prefix(cwd.count)) == cwd } }
    enum Mark { case none, some, all }
    func mark(_ fs: [RemoteFile]) -> Mark {
        let n = fs.filter { selected.contains($0.id) }.count
        return n == 0 ? .none : n == fs.count ? .all : .some
    }
    func toggle(_ fs: [RemoteFile]) {
        if mark(fs) == .all { fs.forEach { selected.remove($0.id) } } else { fs.forEach { selected.insert($0.id) } }
    }
    var totalSpeed: Double { jobs.filter { $0.state == .running }.map(\.speed).reduce(0, +) }

    func check() {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        guard let p = detect(l) else { status = LoaderError.badLink.localizedDescription; provider = nil; preview = []; return }
        provider = p; busy = true; preview = []; skipped = []; media = nil
        status = L("Читаю содержимое \(p.title)…", "Reading \(p.title)…")
        Task {
            do {
                let r: ListResult
                switch p {
                case .yandex: r = try await Yandex.list(l)
                case .google: r = try await Google.list(l)
                case .dropbox: r = try await Dropbox.list(l)
                case .wetransfer: r = try await WeTransfer.list(l)
                case .mailru: r = try await MailRu.list(l)
                case .onedrive: r = try await OneDrive.list(l)
                case .pcloud: r = try await PCloud.list(l)
                case .video, .music:
                    let (res, info) = try await Media.list(l, music: p == .music) { st in Task { @MainActor in self.status = st } }
                    r = res; media = info
                    if p == .video { mediaQuality = info.heights.first.map(String.init) ?? "2160" }
                }
                guard link.trimmingCharacters(in: .whitespacesAndNewlines) == l else { busy = false; return }
                previewTitle = r.rootName
                preview = r.files.sorted { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
                skipped = r.skipped
                selected = []; cwd = []
                log("ПРОВЕРКА \(p.rawValue): \(l) → «\(r.rootName)», файлов \(preview.count), \(fmtBytes(previewSize)), пропущено \(skipped.count)")
                if let mi = media, p.category != .drive {
                    status = mi.isPlaylist ? L("Плейлист: \(preview.count)", "Playlist: \(preview.count)") + " · " + mi.site : mi.site + (mi.duration.map { " · " + fmtDur($0) } ?? "")
                } else {
                status = preview.isEmpty ? L("Файлов не найдено", "No files found") :
                    L("Файлов: \(preview.count)", "Files: \(preview.count)") + (previewSize > 0 ? " · \(fmtBytes(previewSize))" : "")
                }
            } catch { status = human(error); log("ОШИБКА проверки \(l): \(error.localizedDescription)") }
            busy = false
        }
    }

    private var enqueuing = false
    @Published var flash: Set<UUID> = []      // подсветка файлов на полсекунды перед скачиванием
    func flashThenQueue(_ chosen: [RemoteFile]) {
        guard !chosen.isEmpty, flash.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) { flash = Set(chosen.map(\.id)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeIn(duration: 0.2)) { self.flash = [] }
            self.addToQueue(chosen)
        }
    }
    func addToQueue(_ chosen: [RemoteFile]) {
        guard !enqueuing else { log("НАЖАТО «Скачать» повторно — игнорирую"); return }
        let snap = (link: link.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider, title: previewTitle, preview: preview)
        guard let p = snap.provider, !snap.link.isEmpty, !chosen.isEmpty else { log("НАЖАТО «Скачать», но нечего скачивать"); return }
        enqueuing = true
        log("НАЖАТО «Скачать»: \(chosen.count) файлов")
        DispatchQueue.main.async { self.enqueue(chosen, link: snap.link, p: p, previewTitle: snap.title, preview: snap.preview); self.enqueuing = false }
    }
    private func enqueue(_ chosen: [RemoteFile], link: String, p: Provider, previewTitle: String, preview: [RemoteFile]) {
        let ud = UserDefaults.standard
        let def = ud.string(forKey: "defaultDir").map { URL(fileURLWithPath: $0) }
        let ask = ud.object(forKey: "askEachTime") as? Bool ?? true
        var dir: URL
        if !ask, let d = def, FileManager.default.fileExists(atPath: d.path) { dir = d }
        else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = L("Скачать сюда", "Download here"); panel.message = L("Куда положить скачанное?", "Where should the files go?")
            panel.directoryURL = lastDir ?? def
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let u = panel.url else { log("  выбор папки отменён"); return }
            dir = u
        }
        lastDir = dir
        let title = previewTitle.isEmpty ? (preview.first?.relPath ?? L("файл", "file")) : previewTitle
        let rootFolder = UserDefaults.standard.object(forKey: "makeRoot") as? Bool ?? true
        let base = (previewTitle.isEmpty || !rootFolder) ? dir : dir.appendingPathComponent(safeName(previewTitle))
        let part = chosen.count == preview.count ? "" : L(" (выбрано \(chosen.count) из \(preview.count))", " (\(chosen.count) of \(preview.count) selected)")
        var chosen = chosen
        if p == .video { chosen = chosen.map { f in
            if case .media(let u, _, let site) = f.source { return RemoteFile(id: f.id, relPath: f.relPath, size: f.size, source: .media(url: u, quality: mediaQuality, site: site)) }
            return f } }
        let key = Set(chosen.map(\.relPath))
        if jobs.contains(where: { $0.base.standardizedFileURL == base.standardizedFileURL && !key.isDisjoint(with: $0.files.map(\.relPath)) && [.running, .waiting].contains($0.state) }) {
            status = L("Эти файлы уже качаются в эту папку — дубль не добавлен", "These files are already downloading to this folder — duplicate skipped"); log("  дубль не добавлен: \(link) → \(base.path)"); return
        }
        let job = Job(link: link, provider: p, title: title + part, files: chosen, base: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        job.bookmark = try? base.bookmarkData()
        log("В ОЧЕРЕДЬ «\(job.title)»: \(chosen.count) файлов → \(base.path)")
        chosen.forEach { log("   • \($0.relPath)") }
        jobs.insert(job, at: 0); QueueStore.save(jobs)
        // поле свободно под следующую ссылку
        self.link = ""; self.preview = []; skipped = []; self.provider = nil; self.previewTitle = ""; selected = []; cwd = []
        status = L("Добавлено в очередь. Можно вставлять следующую ссылку", "Added to the queue. You can paste the next link")
        pump()
    }

    func pump() {
        for j in jobs.reversed() where j.state == .waiting {
            if jobs.filter({ $0.state == .running }).count >= maxJobs { break }
            run(j)
        }
    }

    func stop(_ j: Job) {
        log("СТОП «\(j.title)»")
        j.cancelled = true
        if j.state == .waiting { j.state = .stopped; QueueStore.save(jobs); return }
        guard j.state == .running else { return }
        j.raw.cancelAll(); j.runTask?.cancel()
        j.state = .stopped; j.speed = 0; QueueStore.save(jobs)
    }
    /// папка на месте? если перенесли — находим по закладке и «перелинковываем»; если удалили — просим выбрать
    @discardableResult
    func ensureFolder(_ j: Job) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: j.base.path, isDirectory: &isDir), isDir.boolValue { j.folderProblem = nil; return true }
        if let b = j.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &stale), !u.path.contains("/.Trash"),
               FileManager.default.fileExists(atPath: u.path) {
                log("ПАПКА ПЕРЕНЕСЕНА «\(j.title)»: \(j.base.path) → \(u.path), продолжаю там")
                j.base = u; if stale { j.bookmark = try? u.bookmarkData() }
                j.folderProblem = nil; QueueStore.save(jobs); return true
            }
        }
        let left = j.files.count - j.completed.count
        j.folderProblem = L("Папку «\(j.base.lastPathComponent)» удалили или унесли на другой диск. Готово было \(j.completed.count) из \(j.files.count). Можно докачать оставшиеся \(left) в новую папку или скачать всё заново.", "The folder “\(j.base.lastPathComponent)” was deleted or moved to another disk. \(j.completed.count) of \(j.files.count) were done. You can download the remaining \(left) to a new folder or download everything again.")
        log("ПАПКА ПРОПАЛА «\(j.title)»: \(j.base.path)")
        return false
    }
    /// пользователь сам показывает новое место папки. fresh = скачать всё содержимое заново
    func relink(_ j: Job, fresh: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = fresh ? L("Скачать всё сюда", "Download everything here") : L("Докачать сюда", "Resume here")
        panel.message = fresh ? L("Куда скачать всё содержимое «\(j.base.lastPathComponent)» заново?", "Where should “\(j.base.lastPathComponent)” be downloaded again?") : L("Куда докачать оставшиеся файлы «\(j.base.lastPathComponent)»? Если папка просто переехала — покажи её новое место.", "Where should the remaining files of “\(j.base.lastPathComponent)” go? If the folder just moved, show its new location.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, var u = panel.url else { return }
        // выбрали родительскую папку — кладём внутрь неё папку с прежним названием, а не россыпью
        let name = j.base.lastPathComponent
        if u.lastPathComponent != name {
            u = u.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        log("ПАПКА УКАЗАНА ВРУЧНУЮ «\(j.title)»: \(u.path)" + (fresh ? " — качаю всё заново" : " — докачиваю оставшееся"))
        if fresh { j.completed = []; j.doneCount = 0; j.raw.clear(); j.lastBytes = 0; j.bytesDone = 0; j.fileProgress = [:]
                   j.expected = j.files.compactMap(\.size).reduce(0, +) }
        j.base = u; j.bookmark = try? u.bookmarkData(); j.folderProblem = nil
        resume(j)
    }

    /// продолжить с того места, где встали: готовые файлы пропускаем, недокачанный докачиваем
    func resume(_ j: Job) {
        if !ensureFolder(j) { return }
        log("ПРОДОЛЖИТЬ «\(j.title)»: готово \(j.completed.count) из \(j.files.count)")
        j.cancelled = false; j.raw.resume(); j.failed = []; j.state = .waiting
        QueueStore.save(jobs); pump()
    }
    func remove(_ j: Job) { if j.state == .running { j.raw.cancelAll(); j.runTask?.cancel(); j.cancelled = true }; jobs.removeAll { $0 === j }; QueueStore.save(jobs) }
    func retry(_ j: Job) {
        log("ПОВТОР «\(j.title)»")
        let nj = Job(link: j.link, provider: j.provider, title: j.title, files: j.files, base: j.base)
        if let i = jobs.firstIndex(where: { $0 === j }) { jobs[i] = nj } else { jobs.insert(nj, at: 0) }
        QueueStore.save(jobs)
        pump()
    }
    /// только то, что скачано на 100% — паузы и ошибки убираются вручную
    func clearFinished() { jobs.removeAll { $0.state == .done }; QueueStore.save(jobs) }

    private func keepAwake() {
        let any = jobs.contains { $0.state == .running }
        if any, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: L("Идёт загрузка", "Downloading"))
        } else if !any, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    private func run(_ j: Job) {
        let previous = j.runTask
        j.gen += 1; let myGen = j.gen
        j.state = .running; j.started = Date()
        QueueStore.save(jobs)
        keepAwake()
        log("СТАРТ «\(j.title)» → \(j.base.path)")
        // сначала вся структура папок — сразу видно, что и куда ляжет
        if ensureFolder(j) {
            let dirs = Set(j.files.map { f -> String in
                let parts = f.relPath.split(separator: "/").map { safeName(String($0)) }
                return parts.dropLast().joined(separator: "/") })
            for d in dirs.sorted() { try? FileManager.default.createDirectory(at: d.isEmpty ? j.base : j.base.appendingPathComponent(d), withIntermediateDirectories: true) }
            log("  структура папок создана: \(dirs.filter { !$0.isEmpty }.count) папок")
        }
        j.runTask = Task {
            await previous?.value          // прошлый запуск этой задачи должен полностью закончиться
            await withTaskGroup(of: Void.self) { g in
                var it = j.files.filter { !j.completed.contains($0.id) }.makeIterator(); var started = 0
                while started < perJob, let f = it.next() { started += 1; g.addTask { await self.one(j, f) } }
                while await g.next() != nil { if !j.cancelled && !Task.isCancelled, let f = it.next() { g.addTask { await self.one(j, f) } } }
            }
            j.tick(0.25); j.speed = 0; j.current = ""
            if j.gen != myGen { return }   // задачу уже перезапустили — итог подведёт новый запуск
            j.state = j.cancelled ? .stopped : (j.failed.isEmpty ? .done : .failed)
            if j.folderProblem != nil { j.state = .stopped }
            if j.state != .stopped { history.insert(HistoryItem(date: Date(), title: j.title, provider: j.provider.rawValue, link: j.link, path: j.base.path,
                                       files: j.doneCount, total: j.files.count, bytes: j.bytesDone, state: "\(j.state)",
                                       seconds: Date().timeIntervalSince(j.started), bookmark: j.bookmark ?? (try? j.base.bookmarkData()), site: siteOf(j.files)), at: 0)
            History.save(history) }
            if j.state == .done, UserDefaults.standard.object(forKey: "revealDone") as? Bool ?? false { NSWorkspace.shared.activateFileViewerSelecting([j.base]) }
            keepAwake(); QueueStore.save(jobs)
            log("КОНЕЦ «\(j.title)»: \(j.state), скачано \(j.doneCount)/\(j.files.count), \(fmtBytes(j.bytesDone)), ошибок \(j.failed.count)")
            pump()
        }
    }

    private func one(_ j: Job, _ f: RemoteFile) async {
        if j.cancelled { return }
        if !ensureFolder(j) { j.cancelled = true; j.raw.cancelAll(); return }
        let dest = j.base.appendingPathComponent(f.relPath.split(separator: "/").map { safeName(String($0)) }.joined(separator: "/"))
        j.current = f.relPath
        log("  ↓ \(f.relPath)")
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            var urls: [URL] = []; var rename = false
            switch f.source {
            case .yandex(let k, let p, let direct):
                if let direct { urls.append(direct) }
                if let fresh = try? await Yandex.resolve(publicKey: k, path: p), !urls.contains(fresh) { urls.append(fresh) }
            case .google(let id): urls = Google.downloadURLs(id); rename = dest.pathExtension.isEmpty
            case .dropbox(let u): urls = [URL(string: u)!]
            case .wetransfer(let id, let h, let r, let fid): urls = [try await WeTransfer.resolve(id: id, hash: h, recipient: r, fileID: fid)]
            case .mailru(let w): urls = [try await MailRu.resolve(w)]
            case .onedrive(let t, let id): urls = [try await OneDrive.resolve(token: t, itemID: id)]
            case .pcloud(let api, let c, let fid): urls = [try await PCloud.resolve(api: api, code: c, fileID: fid)]
            case .media(let u, let q, _):
                let saved = try await Media.download(url: u, quality: q, dir: dest.deletingLastPathComponent(), name: dest.lastPathComponent, raw: j.raw, fid: f.id)
                j.completed.insert(f.id); j.doneCount = j.completed.count; QueueStore.save(jobs)
                log("  ✓ \(f.relPath) → \(saved.path)")
                return
            }
            if urls.isEmpty { throw LoaderError.parse(L("не удалось получить ссылку на скачивание", "couldn't get a download link")) }
            let saved = try await downloadFile(urls: urls, dest: dest, renameFromServer: rename, raw: j.raw, fid: f.id, knownSize: f.size, conns: conns)
            j.completed.insert(f.id); j.doneCount = j.completed.count
            QueueStore.save(jobs)
            log("  ✓ \(f.relPath) → \(saved.path) (\(fmtBytes(j.raw.bytesOf(f.id))))")
        } catch {
            // папку унесли прямо во время загрузки — находим её и пробуем этот файл ещё раз
            if !j.cancelled, !FileManager.default.fileExists(atPath: j.base.path) {
                if ensureFolder(j) { log("  ↻ \(f.relPath): повтор в перенесённой папке"); await one(j, f); return }
                j.cancelled = true; j.raw.cancelAll(); return
            }
            if j.cancelled || error is CancellationError || Task.isCancelled { log("  ■ \(f.relPath): остановлено, недокачанное сохранено для докачки"); return }
            log("  ✗ \(f.relPath): \(error.localizedDescription)")
            j.failed.append(f.relPath + " — " + human(error))
        }
    }

    // проверка новой версии на GitHub (репозиторий задаётся в настройках)
    /// проверка новой версии: один маленький запрос к GitHub (при запуске и раз в 6 часов), всё внутри приложения
    func checkUpdate(manual: Bool) async {
        let custom = UserDefaults.standard.string(forKey: "ghRepo")?.trimmingCharacters(in: .whitespaces) ?? ""
        let repo = custom.contains("/") ? custom : Manager.defaultRepo
        do {
            let j = try JSONSerialization.jsonObject(with: try await fetch(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)) as? [String: Any]
            let tag = (j?["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let assets = j?["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".zip") }?["browser_download_url"] as? String
            if !tag.isEmpty, tag.compare(cur, options: .numeric) == .orderedDescending, let u = (j?["html_url"] as? String).flatMap(URL.init(string:)) {
                update = (tag, u, zip.flatMap(URL.init(string:))); log("ОБНОВЛЕНИЕ доступно: \(tag) (сейчас \(cur))")
                if manual { status = L("Доступна версия \(tag) — нажми плашку внизу окна", "Version \(tag) is available — click the banner at the bottom") }
            } else { update = nil; if manual { status = L("Установлена последняя версия \(cur)", "You have the latest version \(cur)") } }
        } catch { if manual { status = L("Не удалось проверить обновления: \(human(error))", "Couldn't check for updates: \(human(error))") }; log("ОБНОВЛЕНИЯ: \(error.localizedDescription)") }
    }

    /// скачать обновление, заменить приложение и перезапустить (очередь загрузок продолжится сама)
    func installUpdate() {
        guard let u = update, updateProgress == nil else { return }
        guard let zip = u.zip else { NSWorkspace.shared.open(u.url); return }   // в релизе нет zip — открываем страницу
        let appURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            updateNote = L("Нет прав на папку с приложением — открываю страницу загрузки", "No permission for the app folder — opening the download page"); NSWorkspace.shared.open(u.url); return
        }
        updateProgress = 0; updateNote = ""
        log("ОБНОВЛЕНИЕ: качаю \(u.version) — \(zip.absoluteString)")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MegaLoader-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let raw = Raw(); let fid = UUID()
        let poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in let (b, e, _, _) = raw.snapshot(); if e > 0 { self.updateProgress = min(0.99, Double(b) / Double(e)) } }
        }
        Task {
            defer { poll.invalidate() }
            do {
                let file = try await downloadFile(urls: [zip], dest: tmp.appendingPathComponent("update.zip"), renameFromServer: false, raw: raw, fid: fid, knownSize: nil, conns: 4)
                updateNote = L("Устанавливаю…", "Installing…"); updateProgress = 1
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", file.path, tmp.path]
                try p.run(); p.waitUntilExit()
                guard let newApp = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                    throw LoaderError.parse(L("в архиве обновления нет приложения", "the update archive has no app inside"))
                }
                // после выхода: заменить старое приложение новым, снять карантин, открыть
                let pid = ProcessInfo.processInfo.processIdentifier
                let target = appURL.deletingLastPathComponent().appendingPathComponent(newApp.lastPathComponent)   // имя приложения могло поменяться
                let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
                rm -rf "\(appURL.path)" "\(target.path)" && mv "\(newApp.path)" "\(target.path)"
                xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
                open "\(target.path)"
                rm -rf "\(tmp.path)"
                """
                let sh = Process(); sh.executableURL = URL(fileURLWithPath: "/bin/sh"); sh.arguments = ["-c", script]
                try sh.run()
                log("ОБНОВЛЕНИЕ: перезапуск в версию \(u.version)")
                QueueStore.save(jobs)
                NSApp.terminate(nil)
            } catch {
                updateProgress = nil; updateNote = L("Не получилось обновиться: \(human(error))", "Update failed: \(human(error))")
                log("ОБНОВЛЕНИЕ не удалось: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Интерфейс (стиль: тёмный тёплый, розовый акцент, боковое меню)

enum Theme {
    static let bg = Color(red: 0.15, green: 0.135, blue: 0.125)
    static let side = Color(red: 0.135, green: 0.12, blue: 0.11)
    static let card = Color(red: 0.19, green: 0.175, blue: 0.165)
    static let row = Color(red: 0.225, green: 0.21, blue: 0.2)
    static let line = Color.white.opacity(0.07)
    // акцент = системный цвет акцента macOS
    static let pink = Color(nsColor: .controlAccentColor)
    static let pinkSoft = Color(nsColor: .controlAccentColor).opacity(0.85)
    static let text = Color(red: 0.95, green: 0.93, blue: 0.91)
    static let dim = Color(red: 0.62, green: 0.59, blue: 0.56)
}

func fileIcon(_ p: String) -> String {
    let e = (p as NSString).pathExtension.lowercased()
    if ["mp4", "mov", "mxf", "avi", "mkv", "m4v", "braw", "r3d"].contains(e) { return "film" }
    if ["mp3", "wav", "aac", "m4a", "flac", "aif", "aiff"].contains(e) { return "waveform" }
    if ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr3", "psd"].contains(e) { return "photo" }
    if ["zip", "rar", "7z"].contains(e) { return "archivebox" }
    return "doc"
}

struct TapStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.contentShape(Rectangle()).opacity(c.isPressed ? 0.6 : 1)
    }
}
extension ButtonStyle where Self == TapStyle { static var tap: TapStyle { TapStyle() } }

struct Pill: View {
    let text: String; var color: Color = Theme.dim
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
    }
}

struct ProviderBadge: View {
    let p: Provider
    var body: some View { Pill(text: p.short, color: p.color) }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(1).foregroundStyle(Theme.dim)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line).allowsHitTesting(false))
    }
}

struct PinkButton: View {
    let title: String; var icon: String? = nil; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let icon { Image(systemName: icon) }; Text(title) }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.pink, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.tap)
    }
}
struct GhostButton: View {
    let title: String; var icon: String? = nil; var disabled = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let icon { Image(systemName: icon) }; Text(title) }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(disabled ? Theme.dim.opacity(0.5) : Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.tap).disabled(disabled)
    }
}

struct CheckBox: View {
    let mark: Manager.Mark; let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(mark == .none ? Color.clear : Theme.pink).frame(width: 20, height: 20)
                Circle().stroke(mark == .none ? Theme.dim : Theme.pink, lineWidth: 1.5).frame(width: 20, height: 20)
                if mark != .none { Image(systemName: mark == .all ? "checkmark" : "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
            }.frame(width: 26, height: 26).contentShape(Circle())
        }.buttonStyle(.tap)
    }
}

struct PinkBar: View {
    let value: Double; var color: Color = Theme.pink
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: max(6, g.size.width * min(1, max(0, value))))
            }
        }.frame(height: 6)
    }
}

// --- Скачать

/// аккуратный переключатель: в папку по умолчанию или спрашивать каждый раз
struct SaveModeSwitch: View {
    @AppStorage("askEachTime") var ask = true
    @AppStorage("defaultDirSetupDone") var setupDone = false     // папку по умолчанию предлагали один раз
    @State private var hint = false
    @AppStorage("defaultDir") var defaultDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                seg(L("Спрашивать путь", "Ask for folder"), icon: "questionmark.folder", on: ask) { ask = true }
                seg(L("По умолчанию", "Default folder"), icon: "folder.fill", on: !ask) { switchToDefault() }
            }.fixedSize().padding(3).background(Theme.card, in: Capsule()).overlay(Capsule().stroke(Theme.line).allowsHitTesting(false))
            if !ask {
                Button { pickFolder() } label: {
                    HStack(spacing: 4) { Text(shortName).lineLimit(1).fixedSize(); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }.fixedSize()
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                }.buttonStyle(.tap).help(defaultDir + L(" — нажми, чтобы сменить", " — click to change"))
                .popover(isPresented: $hint, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("Создал папку для загрузок", "Created a downloads folder"), systemImage: "folder.badge.plus").font(.system(size: 13, weight: .semibold))
                        Text(L("Теперь всё будет качаться в «Загрузки/MegaLoader» — как у браузера. Можно оставить или выбрать любую другую папку.", "Everything will now go to “Downloads/MegaLoader”, just like a browser. Keep it or choose any other folder."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(L("Выбрать другую…", "Choose another…")) { hint = false; pickFolder() }
                            Spacer()
                            Button(L("Оставить", "Keep")) { hint = false }.keyboardShortcut(.defaultAction)
                        }
                    }.padding(14).frame(width: 300)
                }
            }
        }
    }
    /// первый переход на «По умолчанию»: создаём Загрузки/MegaLoader и предлагаем; дальше человек выбирает сам
    func switchToDefault() {
        ask = false
        guard !setupDone else { return }
        setupDone = true
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MegaLoader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaultDir = dir.path
        log("НАСТРОЙКИ первый выбор «По умолчанию»: создана папка \(dir.path)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { hint = true }
    }
    func pickFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: defaultDir)
        if p.runModal() == .OK, let u = p.url { defaultDir = u.path; log("НАСТРОЙКИ папка по умолчанию → \(u.path)") }
    }
    var shortName: String {
        let n = (defaultDir as NSString).lastPathComponent
        return n.count > 20 ? String(n.prefix(9)) + "…" + String(n.suffix(9)) : n
    }
    func seg(_ t: String, icon: String, on: Bool, _ a: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { a() } } label: {
            HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 10)); Text(t).lineLimit(1) }
                .fixedSize()
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? Color.white : Theme.dim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? Theme.pink : Color.clear, in: Capsule())
        }.buttonStyle(.tap)
    }
}

func siteOf(_ files: [RemoteFile]) -> String? {
    for f in files { if case .media(_, _, let site) = f.source { return site } }
    return nil
}

struct QualityPicker: View {
    @ObservedObject var m: Manager
    var heights: [Int] = []          // пусто — плейлист: общий набор «до …»
    static func label(_ h: Int) -> String { h == 2160 ? "4K" : h == 1440 ? "2K" : "\(h)p" }
    var options: [(String, String, String)] {
        let hs = heights.isEmpty ? [2160, 1080, 720] : heights   // пусто — плейлист: «до 4K / до 1080p / до 720p»
        return hs.map { (String($0), QualityPicker.label($0), QualityPicker.label($0)) } + [("audio", "Только звук", "Audio only")]
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { o in
                let on = m.mediaQuality == o.0
                Button { withAnimation(.easeInOut(duration: 0.15)) { m.mediaQuality = o.0 } } label: {
                    Text(L(o.1, o.2)).lineLimit(1).fixedSize().font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Theme.dim).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(on ? Theme.pink : Color.clear, in: Capsule())
                }.buttonStyle(.tap)
            }
        }.fixedSize().padding(3).background(Theme.bg, in: Capsule())
    }
}

struct MediaCard: View {
    @ObservedObject var m: Manager
    let info: MediaInfo
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.row)
                    if let t = info.thumb {
                        AsyncImage(url: t) { img in img.resizable().scaledToFill() } placeholder: { ProgressView().controlSize(.small) }
                    } else { Image(systemName: m.provider == .music ? "music.note" : "play.rectangle.fill").font(.system(size: 30)).foregroundStyle(Theme.dim) }
                }.frame(width: 180, height: 101).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text(info.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    HStack(spacing: 8) {
                        Pill(text: info.site, color: (m.provider ?? .video).color)
                        if let d = info.duration { Label(fmtDur(d), systemImage: "clock").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        if m.provider == .video { QualityPicker(m: m, heights: info.heights) }
                        else { Label(L("MP3, лучшее качество", "MP3, best quality"), systemImage: "music.note").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                        Spacer(minLength: 8)
                        PinkButton(title: L("Скачать", "Download"), icon: "arrow.down") { m.addToQueue(m.preview) }.keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(14)
        }
    }
}

struct PickerView: View {
    @ObservedObject var m: Manager
    var listMax: CGFloat = 380
    var body: some View {
        Card {
            if m.isSingleFile, let f = m.preview.first {
                SectionHeader(text: L("Один файл", "Single file"))
                HStack(spacing: 12) {
                    Image(systemName: fileIcon(f.relPath)).font(.system(size: 18)).foregroundStyle(Theme.pink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.relPath).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        if let s = f.size { Text(fmtBytes(s)).font(.system(size: 12)).foregroundStyle(Theme.dim) }
                    }
                    Spacer()
                    PinkButton(title: L("Скачать", "Download"), icon: "arrow.down") { m.addToQueue(m.preview) }.keyboardShortcut(.defaultAction)
                }.padding(14).background(Theme.row, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 10).padding(.bottom, 10)
            } else {
                HStack(spacing: 4) {
                    Button { m.cwd = [] } label: { Label(m.previewTitle.isEmpty ? L("Корень", "Root") : m.previewTitle, systemImage: "externaldrive") }
                        .buttonStyle(.tap).foregroundStyle(m.cwd.isEmpty ? Theme.text : Theme.dim)
                    ForEach(Array(m.cwd.enumerated()), id: \.offset) { i, c in
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.dim)
                        Button(c) { m.cwd = Array(m.cwd.prefix(i + 1)) }.buttonStyle(.tap)
                            .foregroundStyle(i == m.cwd.count - 1 ? Theme.text : Theme.dim)
                    }
                    Spacer()
                    let here = m.filesUnder(m.cwd)
                    Button(m.mark(here) == .all ? L("Снять выбор", "Deselect") : L("Выбрать всё здесь", "Select all here")) { m.toggle(here) }.buttonStyle(.tap).foregroundStyle(Theme.pink)
                    if !m.cwd.isEmpty { Button { m.cwd.removeLast() } label: { Label(L("Назад", "Back"), systemImage: "arrow.uturn.left") }.buttonStyle(.tap).foregroundStyle(Theme.dim).padding(.leading, 10) }
                }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                Divider().overlay(Theme.line)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(m.folderHere, id: \.self) { name in
                            let fs = m.filesUnder(m.cwd + [name]); let sz = fs.compactMap(\.size).reduce(0, +)
                            HStack(spacing: 10) {
                                CheckBox(mark: fs.contains { m.flash.contains($0.id) } ? .all : m.mark(fs)) { m.toggle(fs) }
                                Image(systemName: "folder.fill").foregroundStyle(Theme.pinkSoft)
                                Text(name).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Text(L("\(fs.count) файлов", "\(fs.count) files") + (sz > 0 ? " · " + fmtBytes(sz) : "")).foregroundStyle(Theme.dim).font(.system(size: 11))
                                Spacer()
                                Button { m.cwd.append(name) } label: {
                                    HStack(spacing: 4) { Text(L("Открыть", "Open")); Image(systemName: "chevron.right") }
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                                        .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.card, in: Capsule())
                                }.buttonStyle(.tap).help(L("Зайти в папку (или двойной клик по строке)", "Open the folder (or double-click the row)"))
                            }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(fs.contains { m.flash.contains($0.id) } ? Theme.pink.opacity(0.45) : m.mark(fs) == .none ? Theme.row.opacity(0.6) : Theme.pink.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { m.cwd.append(name) }
                            .onTapGesture { m.toggle(fs) }
                        }
                        ForEach(m.filesHere) { f in
                            let on = m.selected.contains(f.id); let fl = m.flash.contains(f.id)
                            HStack(spacing: 10) {
                                CheckBox(mark: on || fl ? .all : .none) { m.toggle([f]) }
                                Image(systemName: m.provider == .music ? "music.note" : m.provider == .video ? "play.rectangle" : fileIcon(f.relPath)).frame(width: 16).foregroundStyle(Theme.dim)
                                Text((f.relPath as NSString).lastPathComponent).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let s = f.size { Text(fmtBytes(s)).foregroundStyle(Theme.dim).monospacedDigit() }
                            }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(fl ? Theme.pink.opacity(0.45) : on ? Theme.pink.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onTapGesture { m.toggle([f]) }
                        }
                    }.padding(8)
                }.frame(minHeight: 120, maxHeight: listMax)
                if !m.skipped.isEmpty { Text(L("Пропущено: ", "Skipped: ") + m.skipped.joined(separator: "; ")).font(.caption).foregroundStyle(.orange).lineLimit(2).padding(.horizontal, 16) }
                Divider().overlay(Theme.line)
                PickerFooter(m: m).padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }
}

/// панель действий выбора — всегда видна внизу окна, сколько бы ни было файлов
struct PickerFooter: View {
    @ObservedObject var m: Manager
    var body: some View {
        let sel = m.selectedFiles; let sz = sel.compactMap(\.size).reduce(0, +)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if m.provider == .video { QualityPicker(m: m) }
                Text(sel.isEmpty ? L("Ничего не выбрано", "Nothing selected") : L("Выбрано \(sel.count)", "\(sel.count) selected") + (sz > 0 ? " · " + fmtBytes(sz) : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                Spacer(minLength: 8)
                GhostButton(title: L("Скачать выбранное", "Download selected"), disabled: sel.isEmpty) { m.flashThenQueue(m.selectedFiles) }
                PinkButton(title: L("Скачать всё", "Download all"), icon: "arrow.down") { m.flashThenQueue(m.preview) }.keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(sel.isEmpty ? L("Ничего не выбрано", "Nothing selected") : L("Выбрано \(sel.count)", "\(sel.count) selected")).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer(minLength: 8)
                    GhostButton(title: L("Выбранное", "Selected"), disabled: sel.isEmpty) { m.flashThenQueue(m.selectedFiles) }
                    PinkButton(title: L("Всё", "All"), icon: "arrow.down") { m.flashThenQueue(m.preview) }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var j: Job
    @ObservedObject var m: Manager
    @State var open = false
    var color: Color { j.state == .failed ? .red : j.state == .done ? Color(red: 0.45, green: 0.8, blue: 0.55) : Theme.pink }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(Int((j.progress * 100).rounded()))%").font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(color).monospacedDigit().frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(j.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        if let site = siteOf(j.files) { Pill(text: site, color: j.provider.color) } else { ProviderBadge(p: j.provider) }
                    }
                    Text(j.base.path).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                stateLabel
                if j.state == .running || j.state == .waiting {
                    Button { m.stop(j) } label: { Image(systemName: "pause.circle.fill") }.buttonStyle(.tap).foregroundStyle(Theme.pink).help(L("Пауза", "Pause"))
                } else {
                    if j.state != .done { Button { m.resume(j) } label: { Image(systemName: "play.circle.fill") }.buttonStyle(.tap).foregroundStyle(Theme.pink).help(L("Продолжить с места остановки", "Resume where it stopped")) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([j.base]) } label: { Image(systemName: "folder") }.buttonStyle(.tap).foregroundStyle(Theme.dim).help(L("Показать в Finder", "Show in Finder"))
                }
                Button { m.remove(j) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.tap).foregroundStyle(Theme.dim).help(L("Убрать задачу (скачанное останется)", "Remove task (downloaded files stay)"))
            }.font(.system(size: 15))
            PinkBar(value: j.progress, color: color)
            HStack(spacing: 16) {
                Label(L("\(j.doneCount) из \(j.files.count)", "\(j.doneCount) of \(j.files.count)"), systemImage: "doc.on.doc")
                Label(fmtBytes(j.bytesDone) + (j.expected > 0 ? L(" из ", " of ") + fmtBytes(j.expected) : ""), systemImage: "internaldrive")
                if j.state == .running { Label(fmtBytes(Int64(j.speed)) + L("/с", "/s"), systemImage: "speedometer").foregroundStyle(Theme.pink) }
                Spacer()
                Button(open ? L("Скрыть файлы", "Hide files") : L("Файлы", "Files")) { open.toggle() }.buttonStyle(.tap).foregroundStyle(Theme.dim)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim).monospacedDigit()
            if let fp = j.folderProblem {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange)
                    Text(fp).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        PinkButton(title: L("Докачать оставшееся…", "Download the rest…"), icon: "arrow.down.to.line") { m.relink(j) }.keyboardShortcut(.defaultAction)
                        GhostButton(title: L("Скачать всё заново…", "Download everything again…"), icon: "arrow.clockwise") { m.relink(j, fresh: true) }
                    }
                }.padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if !j.failed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(j.failed.prefix(4).enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                            Text(t).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if j.failed.count > 4 { Text(L("и ещё \(j.failed.count - 4) — подробности в Журнале", "and \(j.failed.count - 4) more — see the Log")).foregroundStyle(Theme.dim) }
                }.font(.system(size: 12)).padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if open {
                ForEach(j.files) { f in
                    HStack(spacing: 8) {
                        Image(systemName: fileIcon(f.relPath)).frame(width: 14).foregroundStyle(Theme.dim)
                        Text(f.relPath).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let p = j.fileProgress[f.id] {
                            if p >= 1 { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if p >= 0 { Text("\(Int(p * 100))%").foregroundStyle(Theme.pink).monospacedDigit() } else { ProgressView().controlSize(.mini) }
                        }
                    }.font(.system(size: 11))
                }
            }
        }
        .padding(14).background(Theme.row, in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder var stateLabel: some View {
        switch j.state {
        case .waiting: Pill(text: L("в очереди", "queued"))
        case .running: Pill(text: L("качаю", "downloading"), color: Theme.pink)
        case .done: Pill(text: L("готово", "done"), color: .green)
        case .stopped: Pill(text: L("на паузе", "paused"), color: .orange)
        case .failed: Pill(text: L("ошибки", "errors"), color: .red)
        }
    }
}

struct DownloadPage: View {
    @ObservedObject var m: Manager
    var body: some View {
      GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(text: L("Скачать", "Download"), trailing: AnyView(SaveModeSwitch()))
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(Theme.dim)
                        TextField("", text: $m.link)
                            .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.text).onSubmit { m.check() }
                            .background(alignment: .leading) { if m.link.isEmpty { RotatingHint() } }
                        Divider().frame(height: 22)
                        Button { if let s = NSPasteboard.general.string(forType: .string) { m.link = s; m.check() } } label: { Label(L("Вставить", "Paste"), systemImage: "doc.on.clipboard") }
                            .buttonStyle(.tap).foregroundStyle(Theme.dim)
                        Button { m.check() } label: { Label(L("Проверить", "Check"), systemImage: "magnifyingglass") }
                            .buttonStyle(.tap).foregroundStyle(m.link.isEmpty ? Theme.dim.opacity(0.5) : Theme.text).disabled(m.busy || m.link.isEmpty)
                    }.padding(16)
                    Divider().overlay(Theme.line)
                    HStack(spacing: 8) {
                        if m.busy { ProgressView().controlSize(.small) }
                        if let p = m.provider { ProviderBadge(p: p) }
                        Text(m.status).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }
                if let mi = m.media, !mi.isPlaylist, !m.preview.isEmpty { MediaCard(m: m, info: mi) }
                else if !m.preview.isEmpty { PickerView(m: m, listMax: max(120, min(460, geo.size.height - 360))) }
                HStack {
                    Text(L("ЗАГРУЗКИ", "DOWNLOADS")).font(.system(size: 11, weight: .semibold)).kerning(1).foregroundStyle(Theme.dim)
                    if m.summary.speed > 0 { Text(fmtBytes(Int64(m.summary.speed)) + L("/с", "/s")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.pink).monospacedDigit() }
                    Spacer()
                    if m.jobs.contains(where: { $0.state == .done }) {
                        Button(L("Убрать завершённые", "Clear completed")) { m.clearFinished() }.buttonStyle(.tap).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }.padding(.top, 4)
                if m.jobs.isEmpty {
                    Text(L("Пока пусто. Каждая ссылка — отдельная задача, новые можно добавлять, пока идут старые.", "Nothing here yet. Each link is a separate task — you can add new ones while others are running."))
                        .font(.system(size: 13)).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, minHeight: 90)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    LazyVStack(spacing: 10) { ForEach(m.jobs) { JobRow(j: $0, m: m) } }
                }
                        }.padding(28)
        }
        .frame(maxHeight: .infinity)
      }
    }
}

/// подсказка в поле ссылки: площадки и диски по очереди, по убыванию популярности
struct RotatingHint: View {
    static let names: [(String, String)] = [("YouTube", "YouTube"), ("Google Диск", "Google Drive"), ("TikTok", "TikTok"), ("Яндекс Диск", "Yandex Disk"),
        ("Instagram", "Instagram"), ("Dropbox", "Dropbox"), ("Spotify", "Spotify"), ("OneDrive", "OneDrive"), ("SoundCloud", "SoundCloud"),
        ("Облако Mail.ru", "Mail.ru Cloud"), ("VK Видео", "VK Video"), ("WeTransfer", "WeTransfer"), ("Vimeo", "Vimeo"), ("pCloud", "pCloud"), ("X (Twitter)", "X (Twitter)")]
    @State private var i = 0
    let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            Text(L("Ссылка на ", "Link to ")).foregroundStyle(Theme.dim.opacity(0.7))
            Text(L(RotatingHint.names[i].0, RotatingHint.names[i].1)).foregroundStyle(Theme.pink.opacity(0.75))
                .id(i).transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
        }.font(.system(size: 15)).allowsHitTesting(false).clipped()
        .onReceive(timer) { _ in withAnimation(.easeInOut(duration: 0.35)) { i = (i + 1) % RotatingHint.names.count } }
    }
}

struct PageTitle: View {
    let text: String; var trailing: AnyView? = nil
    var body: some View {
        // заголовок не режется: если рядом не помещается — переключатель уходит строкой ниже
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(text).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                Spacer(minLength: 12)
                trailing?.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                trailing?.fixedSize()
            }
        }
    }
}

// --- История

var ruDate: DateFormatter {
    let f = DateFormatter()
    if isEN { f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMMM d, yyyy 'at' HH:mm" }
    else { f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy 'г. в' HH:mm" }
    return f
}
func fmtDur(_ s: Double) -> String { s < 60 ? L("\(Int(s)) с", "\(Int(s)) s") : s < 3600 ? L("\(Int(s / 60)) мин \(Int(s) % 60) с", "\(Int(s / 60)) min \(Int(s) % 60) s") : L("\(Int(s / 3600)) ч \(Int(s) % 3600 / 60) мин", "\(Int(s / 3600)) h \(Int(s) % 3600 / 60) min") }

struct IconBtn: View {
    let icon: String; let help: String; var color: Color = Theme.dim; var disabled = false; let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 16)).frame(width: 30, height: 30) }
            .buttonStyle(.tap).foregroundStyle(disabled ? Theme.dim.opacity(0.35) : color).disabled(disabled).help(help)
    }
}

struct HistoryRow: View {
    let h: HistoryItem; @ObservedObject var m: Manager
    var exists: Bool { FileManager.default.fileExists(atPath: h.path) }
    var movedTo: String? {
        guard !exists, let b = h.bookmark else { return nil }
        var st = false
        guard let u = try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &st), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u.path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(ruDate.string(from: h.date)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                IconBtn(icon: "folder", help: exists ? L("Показать в Finder", "Show in Finder") : L("Папки нет на месте", "Folder is missing"), disabled: !exists) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.path)]) }
                IconBtn(icon: "doc.on.doc", help: L("Скопировать ссылку", "Copy link")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.link, forType: .string) }
                IconBtn(icon: "arrow.counterclockwise", help: L("Открыть ссылку снова", "Open the link again"), color: Theme.pink) { m.link = h.link; m.page = .download; m.check() }
                IconBtn(icon: "trash", help: L("Убрать из истории", "Remove from history")) { m.history.removeAll { $0.id == h.id }; History.save(m.history) }
            }
            HStack(spacing: 8) {
                Text(h.title).font(.system(size: 14).italic()).foregroundStyle(Theme.text).lineLimit(2)
                if let st = h.site, let pv = Provider(rawValue: h.provider) { Pill(text: st, color: pv.color) }
                else if let pv = Provider(rawValue: h.provider) { ProviderBadge(p: pv) } else { Pill(text: h.provider) }
                statePill
            }
            HStack(spacing: 16) {
                Label(L("\(h.files) из \(h.total) файлов", "\(h.files) of \(h.total) files"), systemImage: "doc.on.doc")
                Label(fmtBytes(h.bytes), systemImage: "internaldrive")
                if let s = h.seconds, s > 1 {
                    Label(fmtBytes(Int64(Double(h.bytes) / s)) + L("/с в среднем", "/s average"), systemImage: "speedometer")
                    Label(fmtDur(s), systemImage: "clock")
                }
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim).monospacedDigit()
            HStack(spacing: 6) {
                if exists {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.dim)
                    Text(h.path).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                } else if let to = movedTo, to.contains("/.Trash") {
                    Image(systemName: "trash.fill").foregroundStyle(.orange)
                    Text(L("Папка в Корзине", "Folder is in the Trash")).foregroundStyle(.orange)
                } else if let to = movedTo {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.orange)
                    Text(L("Папку перенесли:", "Folder moved to:")).foregroundStyle(.orange)
                    Button(to) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: to)]) }.buttonStyle(.tap).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L("Папка перемещена или удалена с устройства", "Folder was moved or deleted from this Mac")).foregroundStyle(.orange)
                    Text(h.path).foregroundStyle(Theme.dim.opacity(0.6)).lineLimit(1).truncationMode(.head).strikethrough()
                }
            }.font(.system(size: 11))
        }.padding(.horizontal, 18).padding(.vertical, 16)
    }
    @ViewBuilder var statePill: some View {
        switch h.state {
        case "done": Pill(text: L("готово", "done"), color: .green)
        case "failed": Pill(text: L("с ошибками", "with errors"), color: .red)
        default: Pill(text: L("остановлено", "stopped"), color: .orange)
        }
    }
}

struct HistoryPage: View {
    @ObservedObject var m: Manager
    @State var q = ""
    @AppStorage("defaultDir") var defaultDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    @AppStorage("historyTab") var tab = "drive"
    var items: [HistoryItem] {
        m.history.filter { (Provider(rawValue: $0.provider)?.category.rawValue ?? "drive") == tab }
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) }
    }
    // «Сейчас качается» — только задачи выбранной вкладки (диски / видео / музыка)
    var active: [Job] { m.jobs.filter { ($0.state == .running || $0.state == .waiting) && $0.provider.category.rawValue == tab } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(L("ИСТОРИЯ", "HISTORY")).font(.system(size: 13, weight: .semibold)).kerning(1.2).foregroundStyle(Theme.dim)
                    Spacer()
                    GhostButton(title: L("Открыть папку загрузок", "Open downloads folder"), icon: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: defaultDir)) }
                    if !m.history.isEmpty { GhostButton(title: L("Очистить", "Clear"), icon: "trash") { m.history = []; History.save([]); log("ИСТОРИЯ очищена") } }
                }
                HStack(spacing: 2) {
                    ForEach([("drive", "externaldrive", "Диски", "Drives"), ("video", "play.rectangle", "Видео", "Video"), ("music", "music.note", "Музыка", "Music")], id: \.0) { t in
                        let on = tab == t.0
                        Button { withAnimation(.easeInOut(duration: 0.15)) { tab = t.0 } } label: {
                            HStack(spacing: 6) { Image(systemName: t.1); Text(L(t.2, t.3)) }.font(.system(size: 12, weight: .semibold)).fixedSize()
                                .foregroundStyle(on ? Color.white : Theme.dim).padding(.horizontal, 14).padding(.vertical, 6)
                                .background(on ? Theme.pink : Color.clear, in: Capsule())
                        }.buttonStyle(.tap)
                    }
                }.fixedSize().padding(3).background(Theme.card, in: Capsule()).overlay(Capsule().stroke(Theme.line).allowsHitTesting(false))
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                    TextField(L("Поиск по названию или папке", "Search by name or folder"), text: $q).textFieldStyle(.plain).foregroundStyle(Theme.text)
                }.padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                if !active.isEmpty {
                    Text(L("СЕЙЧАС КАЧАЕТСЯ", "DOWNLOADING NOW")).font(.system(size: 11, weight: .semibold)).kerning(1).foregroundStyle(Theme.dim)
                    ForEach(active) { JobRow(j: $0, m: m) }
                }
                if items.isEmpty {
                    Text(m.history.isEmpty ? L("Здесь появятся завершённые загрузки", "Finished downloads will appear here") : L("Ничего не найдено", "Nothing found"))
                        .font(.system(size: 13)).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, minHeight: 100)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, h in
                            if i > 0 { Divider().overlay(Theme.line) }
                            HistoryRow(h: h, m: m)
                        }
                    }.background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line).allowsHitTesting(false))
                }
            }.padding(24)
        }
    }
}

// --- Настройки

struct SettingRow<Trailing: View>: View {
    let title: String; let sub: String; @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)
            }
            Spacer(); trailing
        }.padding(14).background(Theme.row, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsPage: View {
    @AppStorage("defaultDir") var defaultDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    @AppStorage("askEachTime") var ask = true
    @AppStorage("makeRoot") var makeRoot = true
    @AppStorage("revealDone") var reveal = false
    @AppStorage("perJob") var perJob = 4
    @AppStorage("maxJobs") var maxJobs = 2
    @AppStorage("conns") var conns = 8
    @AppStorage("lang") var lang = "ru"
    @AppStorage("totalConns") var totalConns = 16
    @AppStorage("googleKey") var googleKey = ""
    @AppStorage("ghRepo") var ghRepo = ""
    @AppStorage("cookiesBrowser") var cookiesBrowser = ""
    @ObservedObject var m: Manager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(text: L("Настройки", "Settings"))
                Card {
                    SectionHeader(text: L("Язык", "Language"))
                    SettingRow(title: L("Язык интерфейса", "Interface language"), sub: L("Русский или английский — меняется сразу", "Russian or English — changes instantly")) {
                        Picker("", selection: $lang) {
                            Text("Русский").tag("ru")
                            Text("English").tag("en")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: L("Куда скачивать", "Where to download"))
                    VStack(spacing: 8) {
                        SettingRow(title: L("Папка по умолчанию", "Default folder"), sub: defaultDir) {
                            GhostButton(title: L("Выбрать…", "Choose…"), icon: "folder") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                                p.directoryURL = URL(fileURLWithPath: defaultDir)
                                if p.runModal() == .OK, let u = p.url { defaultDir = u.path; log("НАСТРОЙКИ папка по умолчанию → \(u.path)") }
                            }
                        }
                        SettingRow(title: L("Спрашивать каждый раз", "Ask every time"), sub: ask ? L("Перед скачиванием откроется окно выбора папки (начнёт с папки по умолчанию)", "A folder picker opens before each download (starting from the default folder)") : L("Скачивание сразу в папку по умолчанию, без вопросов", "Downloads go straight to the default folder, no questions asked")) {
                            Toggle("", isOn: $ask).toggleStyle(.switch).tint(Theme.pink).labelsHidden()
                        }
                        SettingRow(title: L("Создавать папку с названием", "Create a folder with the name"), sub: L("Папка с диска кладётся внутрь своей папки, а не россыпью", "A shared folder is saved inside its own folder, not scattered")) {
                            Toggle("", isOn: $makeRoot).toggleStyle(.switch).tint(Theme.pink).labelsHidden()
                        }
                        SettingRow(title: L("Показать в Finder после загрузки", "Show in Finder when done"), sub: L("Открывать папку, когда задача завершилась без ошибок", "Open the folder when a task finishes without errors")) {
                            Toggle("", isOn: $reveal).toggleStyle(.switch).tint(Theme.pink).labelsHidden()
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: L("Скорость", "Speed"))
                    VStack(spacing: 8) {
                        SettingRow(title: L("Файлов одновременно", "Files at once"), sub: L("В одной задаче. Больше — быстрее на мелких файлах", "Per task. More is faster for small files")) {
                            Stepper("\(perJob)", value: $perJob, in: 1...8).foregroundStyle(Theme.text).monospacedDigit()
                        }
                        SettingRow(title: L("Задач одновременно", "Tasks at once"), sub: L("Остальные ждут в очереди", "The rest wait in the queue")) {
                            Stepper("\(maxJobs)", value: $maxJobs, in: 1...4).foregroundStyle(Theme.text).monospacedDigit()
                        }
                        SettingRow(title: L("Всего подключений", "Total connections"), sub: L("Общий потолок на всё приложение. Больше 16–24 серверы обычно начинают придерживать", "Overall limit for the whole app. Above 16–24, servers usually start throttling")) {
                            Stepper("\(totalConns)", value: $totalConns, in: 4...48, step: 4).foregroundStyle(Theme.text).monospacedDigit()
                        }
                        SettingRow(title: L("Потоков на один файл", "Threads per file"), sub: L("Большой файл качается частями параллельно. 8 — обычно максимум скорости", "Large files are downloaded in parallel parts. 8 is usually the fastest")) {
                            Stepper("\(conns)", value: $conns, in: 1...16).foregroundStyle(Theme.text).monospacedDigit()
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: L("Видео и музыка", "Video and music"))
                    SettingRow(title: L("Вход через браузер", "Sign in via browser"),
                               sub: L("Для роликов, которые площадка показывает только после входа (часть Instagram, TikTok, YouTube 18+). Приложение возьмёт вход из выбранного браузера. По умолчанию выключено.",
                                      "For videos a site only shows after sign-in (some Instagram, TikTok, YouTube 18+). The app uses your sign-in from the chosen browser. Off by default.")) {
                        Picker("", selection: $cookiesBrowser) {
                            Text(L("Выключено", "Off")).tag(""); Text("Chrome").tag("chrome"); Text("Safari").tag("safari"); Text("Firefox").tag("firefox"); Text("Arc").tag("arc")
                        }.labelsHidden().frame(width: 140)
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: L("Запасные пути и обновления", "Fallbacks and updates"))
                    VStack(spacing: 8) {
                        SettingRow(title: L("Ключ Google API (необязательно)", "Google API key (optional)"), sub: L("Если Google изменит публичные страницы — приложение пойдёт через официальный Drive API. Ключ бесплатный: console.cloud.google.com → Drive API → Credentials", "If Google changes its public pages, the app will use the official Drive API. The key is free: console.cloud.google.com → Drive API → Credentials")) {
                            SecureField("AIza…", text: $googleKey).textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                        SettingRow(title: L("Обновления", "Updates"), sub: L("Приложение само проверяет новые версии на GitHub (\(Manager.defaultRepo)) и предлагает обновиться внизу окна", "The app checks GitHub (\(Manager.defaultRepo)) for new versions and offers to update at the bottom of the window")) {
                            HStack {
                                TextField(Manager.defaultRepo, text: $ghRepo).textFieldStyle(.roundedBorder).frame(width: 170)
                                GhostButton(title: L("Проверить", "Check")) { Task { await m.checkUpdate(manual: true) }; m.page = .download }
                            }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: L("Журнал", "Log"))
                    SettingRow(title: L("Журнал работы", "Activity log"), sub: logURL.path) {
                        GhostButton(title: L("Открыть", "Open"), icon: "list.bullet.rectangle") { NSWorkspace.shared.open(logURL) }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
            }.padding(28)
        }
    }
}

/// значки в строку с переносом
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600; var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0
        for v in subviews { let s = v.sizeThatFits(.unspecified); if x + s.width > w, x > 0 { x = 0; y += h + spacing; h = 0 }; x += s.width + spacing; h = max(h, s.height) }
        return CGSize(width: w, height: y + h)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, h: CGFloat = 0
        for v in subviews { let s = v.sizeThatFits(.unspecified); if x + s.width > b.maxX, x > b.minX { x = b.minX; y += h + spacing; h = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified); x += s.width + spacing; h = max(h, s.height) }
    }
}

struct AboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(text: L("О программе", "About"))
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Logo(size: 26)
                    Text(L("Скачивает всё по одной ссылке: файлы и папки с облачных дисков, видео и музыку с площадок. Работает автономно, без нейросетей.", "Downloads anything from one link: files and folders from cloud drives, video and music from online platforms. Works on its own, no AI involved."))
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                    Text(L("Версия ", "Version ") + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Text(L("Поддерживаемые сервисы", "Supported services")).font(.system(size: 11, weight: .semibold)).kerning(1)
                        .foregroundStyle(Theme.dim).padding(.top, 10)
                    FlowRow(spacing: 6) { ForEach(Provider.drives, id: \.self) { ProviderBadge(p: $0) } }
                    Text(L("Видео и музыка", "Video and music")).font(.system(size: 11, weight: .semibold)).kerning(1)
                        .foregroundStyle(Theme.dim).padding(.top, 6)
                    FlowRow(spacing: 6) {
                        ForEach(["YouTube", "TikTok", "Instagram", "VK", "Vimeo", "X (Twitter)", "Twitch", "Rutube"], id: \.self) { Pill(text: $0, color: Provider.video.color) }
                        ForEach(["Spotify", "SoundCloud", "YouTube Music", "Bandcamp", "Mixcloud"], id: \.self) { Pill(text: $0, color: Provider.music.color) }
                        Pill(text: L("и ещё 1000+ сайтов", "and 1000+ more sites"))
                    }
                    Text(L("Работает с публичными ссылками и роликами в открытом доступе. Папки Dropbox скачиваются одним архивом. Spotify защищён от скачивания — треки находятся по названию на YouTube Music. Движок видео (yt-dlp) скачивается при первом использовании и обновляется сам.",
                           "Works with public links and publicly available videos. Dropbox folders download as a single archive. Spotify is copy-protected \u{2014} tracks are matched by name on YouTube Music. The video engine (yt-dlp) is downloaded on first use and updates itself."))
                        .font(.system(size: 11)).foregroundStyle(Theme.dim.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }.padding(18)
            }
            Spacer()
            // подпись автора — внизу, ненавязчиво
            HStack(spacing: 6) {
                Spacer()
                Text("made by").foregroundStyle(Theme.dim.opacity(0.6))
                Button { NSWorkspace.shared.open(URL(string: "https://t.me/cetrovix")!) } label: {
                    Text("cetrovix").fontWeight(.semibold).foregroundStyle(Theme.pink.opacity(0.85))
                }.buttonStyle(.tap).help("Telegram: t.me/cetrovix")
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                Spacer()
            }.font(.system(size: 11, design: .rounded))
        }.padding(28)
    }
}

// --- Каркас

enum Page: String, CaseIterable { case download = "Скачать", history = "История", settings = "Настройки", about = "О программе"
    var title: String {
        switch self { case .download: L("Скачать", "Download"); case .history: L("История", "History"); case .settings: L("Настройки", "Settings"); case .about: L("О программе", "About") }
    }
    var icon: String { switch self { case .download: "arrow.down.circle"; case .history: "clock.arrow.circlepath"; case .settings: "gearshape"; case .about: "info.circle" } }
}

extension Manager { }

struct Logo: View {
    var size: CGFloat = 24
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: size * 0.95, weight: .semibold)).foregroundStyle(Theme.pink)
            Text("MegaLoader").font(.system(size: size, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                .minimumScaleFactor(0.6)
        }.lineLimit(1)
    }
}

struct SideItem: View {
    let page: Page; let selected: Bool; var badge: String? = nil; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: page.icon).font(.system(size: 17)).frame(width: 22)
                Text(page.title).font(.system(size: 15, weight: .medium))
                Spacer()
                if let badge { Text(badge).font(.system(size: 11, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.25) : Theme.pink.opacity(0.3), in: Capsule()) }
            }
            .foregroundStyle(selected ? Color.white : Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(selected ? Theme.pinkSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.tap)
    }
}

struct ResizeHandle: View {
    @Binding var width: Double; @Binding var hidden: Bool
    @State private var start: Double? = nil
    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 8).contentShape(Rectangle())
            .overlay(Rectangle().fill(Theme.line).frame(width: 1))
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if start == nil { start = width }
                    width = min(380, max(120, (start ?? width) + v.translation.width))
                }
                .onEnded { v in
                    if (start ?? width) + v.translation.width < 150 { withAnimation(.easeInOut(duration: 0.2)) { hidden = true }; width = max(width, 200) }
                    start = nil
                })
    }
}

struct ContentView: View {
    @StateObject var m = Manager()
    @AppStorage("lang") var lang = "ru"
    @AppStorage("sideW") var sideW: Double = 230
    @AppStorage("sideHidden") var sideHidden = false
    var running: Int { m.summary.running }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !sideHidden {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Logo(size: sideW < 190 ? 16 : sideW < 250 ? 20 : 24)
                            Spacer(minLength: 0)
                            IconBtn(icon: "sidebar.left", help: L("Скрыть меню", "Hide sidebar")) { withAnimation(.easeInOut(duration: 0.2)) { sideHidden = true } }
                        }.padding(.leading, 10).padding(.top, 8).padding(.bottom, 10)
                        Divider().overlay(Theme.line).padding(.bottom, 8)
                        ForEach(Page.allCases, id: \.self) { p in
                            SideItem(page: p, selected: m.page == p, badge: p == .download && running > 0 ? "\(running)" : nil) { m.page = p }
                        }
                        Spacer()
                    }.padding(12).frame(width: sideW).background(Theme.side)
                    .transition(.move(edge: .leading))
                    ResizeHandle(width: $sideW, hidden: $sideHidden)
                }
                VStack(spacing: 0) {
                    if sideHidden {
                        HStack(spacing: 10) {
                            IconBtn(icon: "sidebar.left", help: L("Показать меню", "Show sidebar"), color: Theme.text) { withAnimation(.easeInOut(duration: 0.2)) { sideHidden = false } }
                            Logo(size: 15)
                            Spacer()
                        }.padding(.horizontal, 14).padding(.vertical, 8).background(Theme.side)
                        Divider().overlay(Theme.line)
                    }
                    Group {
                        switch m.page {
                        case .download: DownloadPage(m: m)
                        case .history: HistoryPage(m: m)
                        case .settings: SettingsPage(m: m)
                        case .about: AboutPage()
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.background(Theme.bg)
            }
            Divider().overlay(Theme.line)
            HStack(spacing: 8) {
                Circle().fill(running == 0 ? Color.green : Theme.pink).frame(width: 8, height: 8)
                if running == 0 { Text(m.jobs.isEmpty ? L("Готов к работе", "Ready") : L("Всё скачано", "All downloaded")).foregroundStyle(Theme.dim) }
                else {
                    Text(L("Качаю: \(running) · \(m.summary.percent)% · \(fmtBytes(Int64(m.summary.speed)))/с", "Downloading: \(running) · \(m.summary.percent)% · \(fmtBytes(Int64(m.summary.speed)))/s")).foregroundStyle(Theme.text).monospacedDigit()
                }
                Spacer()
                if let u = m.update {
                    if let p = m.updateProgress {
                        Text(p >= 1 ? L("Устанавливаю…", "Installing…") : L("Загрузка… \(Int(p * 100)) %", "Downloading… \(Int(p * 100)) %")).foregroundStyle(Theme.dim).monospacedDigit()
                        PinkBar(value: p).frame(width: 180)
                    } else {
                        Button(L("Доступно обновление \(u.version)", "Update available \(u.version)")) { m.installUpdate() }.buttonStyle(.tap).foregroundStyle(Theme.pink)
                            .help(L("Скачать и установить — очередь загрузок продолжится сама", "Download and install — the download queue will resume automatically"))
                    }
                    Text("·").foregroundStyle(Theme.dim)
                }
                if !m.updateNote.isEmpty && m.updateProgress == nil { Text(m.updateNote).foregroundStyle(.orange).lineLimit(1); Text("·").foregroundStyle(Theme.dim) }
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).foregroundStyle(Theme.dim)
            }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 9).background(Theme.side)
        }
        .frame(minWidth: 780, minHeight: 640)
        .preferredColorScheme(.dark)
        .id(lang)                                   // язык поменяли — перерисовываем всё
        .onChange(of: lang) { _, _ in m.status = L("Вставь публичную ссылку — увидишь, что будет скачано", "Paste a public link to see what will be downloaded") }
        // меню схлопнули — всегда возвращаемся на «Скачать»
        .onChange(of: sideHidden) { _, hidden in if hidden { m.page = .download } }
    }
}

#if !TEST
@main
struct MegaLoaderApp: App {
    init() {
        // уже запущен другой MegaLoader (например, вторая копия) — показываем его и выходим
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.diskloader").first(where: { $0.processIdentifier != me }) {
            other.activate(); exit(0)
        }
        NSApplication.shared.setActivationPolicy(.regular); log("=== MegaLoader запущен ===")
    }
    var body: some Scene {
        WindowGroup("MegaLoader") { ContentView() }.windowResizability(.contentMinSize)
    }
}
#endif
