// DiskLoader — скачивание по публичным ссылкам Яндекс Диска и Google Диска. Работает автономно.
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
    }
}

enum Provider: String, Codable { case yandex = "Яндекс Диск", google = "Google Диск" }

struct ListResult { let rootName: String; let files: [RemoteFile]; let skipped: [String] }

enum LoaderError: LocalizedError {
    case badLink, http(Int), parse(String)
    var errorDescription: String? {
        switch self {
        case .badLink: return "Не похоже на публичную ссылку Яндекс Диска или Google Диска"
        case .http(let c): return "Сервер ответил ошибкой \(c). Ссылка открыта для всех?"
        case .parse(let s): return "Не удалось разобрать ответ: \(s)"
        }
    }
}

/// ошибка → понятный текст с подсказкой, что делать
func human(_ e: Error) -> String {
    if let l = e as? LoaderError {
        switch l {
        case .badLink: return "Это не похоже на публичную ссылку Яндекс Диска или Google Диска. Проверь, что скопировал ссылку целиком."
        case .http(let c):
            switch c {
            case 401, 403: return "Доступ закрыт. Попроси владельца открыть ссылку для всех («Доступ по ссылке»)."
            case 404, 410: return "Файла по ссылке больше нет — его удалили или переместили на диске владельца."
            case 429: return "Сервис временно ограничил скачивание. Подожди 10–15 минут и нажми «Продолжить»."
            case 500...599: return "У сервиса сейчас сбой (ошибка \(c)). Попробуй «Продолжить» чуть позже."
            default: return "Сервис ответил ошибкой \(c). Попробуй «Продолжить»; если повторится — открой Журнал."
            }
        case .parse(let s): return s.prefix(1).uppercased() + s.dropFirst() + "."
        }
    }
    if let u = e as? URLError {
        switch u.code {
        case .notConnectedToInternet: return "Нет интернета. Как только сеть появится — нажми «Продолжить», докачается с того же места."
        case .timedOut: return "Сервер слишком долго не отвечал. Нажми «Продолжить» — докачается с того же места."
        case .networkConnectionLost: return "Связь оборвалась. Нажми «Продолжить» — докачается с того же места."
        case .cannotFindHost, .dnsLookupFailed: return "Не получается найти сервер. Проверь интернет или VPN."
        case .cancelled: return "Остановлено."
        default: return "Проблема с сетью (\(u.code.rawValue)). Нажми «Продолжить» — докачается с того же места."
        }
    }
    let n = e as NSError
    if n.domain == NSCocoaErrorDomain {
        switch n.code {
        case NSFileWriteOutOfSpaceError: return "На диске закончилось место. Освободи место и нажми «Продолжить»."
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "Нет доступа к папке загрузки. Выбери другую папку."
        case NSFileNoSuchFileError, NSFileWriteFileExistsError, 4: return "Папку загрузки переместили или удалили. Укажи её новое место — загрузка продолжится."
        case NSFileWriteVolumeReadOnlyError: return "Диск только для чтения — выбери другую папку."
        default: break
        }
    }
    if n.domain == NSPOSIXErrorDomain && n.code == 28 { return "На диске закончилось место. Освободи место и нажми «Продолжить»." }
    if n.domain == NSPOSIXErrorDomain && n.code == 2 { return "Папку загрузки переместили или удалили. Укажи её новое место — загрузка продолжится." }
    return e.localizedDescription
}

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
    return nil
}

// MARK: - Яндекс Диск (публичный API, без ключа)

enum Yandex {
    static func list(_ link: String) async throws -> ListResult {
        let root = try await meta(link, path: nil, offset: 0)
        let rootName = root["name"] as? String ?? "Яндекс Диск"
        if root["type"] as? String == "file" { return ListResult(rootName: "", files: [file(root, link: link, rel: rootName, single: true)], skipped: []) }
        var files: [RemoteFile] = []
        try await walk(link, path: "/", rel: "", into: &files)
        return ListResult(rootName: rootName, files: files, skipped: [])
    }
    // если основной адрес API перестанет отвечать — пробуем запасной
    static let hosts = ["https://cloud-api.yandex.net", "https://cloud-api.yandex.com"]
    static func api(_ path: String, _ q: [URLQueryItem]) async throws -> [String: Any] {
        var last: Error = LoaderError.parse("Яндекс")
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
        guard let h = j["href"] as? String, let u = URL(string: h) else { throw LoaderError.parse("ссылка Яндекса на скачивание") }
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
        let title = match(html, #"<title>(.*?)</title>"#).first.map(unescape) ?? "Google Диск"
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
            else if href.contains("docs.google.com") { skipped.append(r + " (документ Google — скачивается только экспортом)") }
            else { out.append(RemoteFile(relPath: r, size: nil, source: .google(id: eid))) }
        }
    }
    static var apiKey: String? { let k = UserDefaults.standard.string(forKey: "googleKey")?.trimmingCharacters(in: .whitespaces); return (k?.isEmpty ?? true) ? nil : k }
    static func apiName(_ id: String) async throws -> String {
        guard let k = apiKey else { throw LoaderError.parse("нет ключа Google API") }
        let j = try JSONSerialization.jsonObject(with: try await fetch(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=name&supportsAllDrives=true&key=\(k)")!)) as? [String: Any]
        return j?["name"] as? String ?? "Google Диск"
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
                else if mime.hasPrefix("application/vnd.google-apps") { skipped.append(r + " (документ Google — скачивается только экспортом)") }
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
    let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]; return f.string(fromByteCount: b)
}

// MARK: - Журнал (~/Library/Logs/DiskLoader.log)

let logURL: URL = {
    let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("DiskLoader.log")
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
        if sink?.wantRange == true && code != 206 { sink?.error = LoaderError.parse("сервер не поддерживает докачку частями"); ch(.cancel); return }
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
        var req = URLRequest(url: url); req.setValue("bytes=0-0", forHTTPHeaderField: "Range"); req.setValue(UA, forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let h = resp as? HTTPURLResponse else { throw LoaderError.parse("нет ответа") }
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
    var probe: Engine.Probe? = nil; var lastErr: Error = LoaderError.parse("нет адреса")
    for u in urls {
        do {
            var p = try await Engine.probe(u)
            if p.html, let real = Google.confirmURL(fromHTML: Engine.lastHTML) {
                log("    Google вернул страницу-предупреждение — беру ссылку из неё"); p = try await Engine.probe(real)
            }
            if p.html { throw LoaderError.parse("вместо файла пришла веб-страница (доступ закрыт или сервис что-то поменял)") }
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
    let stLock = NSLock(); var stBox = st
    let saveState = { stLock.lock(); let s = stBox; stLock.unlock(); try? JSONEncoder().encode(s).write(to: stateURL) }
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
    guard FileManager.default.fileExists(atPath: part.path) else { throw LoaderError.parse("недокачанный файл пропал с диска") }
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
    @Published var status = "Вставь публичную ссылку — увидишь, что будет скачано"
    @Published var busy = false
    @Published var selected: Set<UUID> = []      // выбранные файлы
    @Published var cwd: [String] = []             // текущая папка в браузере
    // очередь
    @Published var jobs: [Job] = []
    @Published var lastDir: URL?
    @Published var page: Page = .download
    struct Summary: Equatable { var running = 0; var percent = 0; var speed: Double = 0 }
    @Published var summary = Summary()
    @Published var update: (version: String, url: URL, zip: URL?)? = nil
    @Published var updateProgress: Double? = nil     // nil — не качаем; 0…1 — загрузка обновления
    @Published var updateNote = ""
    static let defaultRepo = "rxtxrxr/DiskLoader"
    private var activity: NSObjectProtocol?

    var perJob: Int { max(1, UserDefaults.standard.integer(forKey: "perJob").nonZero ?? 4) }
    var maxJobs: Int { max(1, UserDefaults.standard.integer(forKey: "maxJobs").nonZero ?? 2) }
    @Published var history: [HistoryItem] = History.load()
    var conns: Int { max(1, UserDefaults.standard.integer(forKey: "conns").nonZero ?? 8) }
    private var timer: Timer?

    override init() {
        super.init()
        Task { await checkUpdate(manual: false) }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.checkUpdate(manual: false) } }
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
            if resume > 0 { status = "Продолжаю незаконченные загрузки: \(resume)" }
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
        provider = p; busy = true; preview = []; skipped = []
        status = "Читаю содержимое \(p.rawValue)…"
        Task {
            do {
                let r = p == .yandex ? try await Yandex.list(l) : try await Google.list(l)
                guard link.trimmingCharacters(in: .whitespacesAndNewlines) == l else { busy = false; return }
                previewTitle = r.rootName
                preview = r.files.sorted { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
                skipped = r.skipped
                selected = []; cwd = []
                log("ПРОВЕРКА \(p.rawValue): \(l) → «\(r.rootName)», файлов \(preview.count), \(fmtBytes(previewSize)), пропущено \(skipped.count)")
                status = preview.isEmpty ? "Файлов не найдено" :
                    "Файлов: \(preview.count)" + (previewSize > 0 ? " · \(fmtBytes(previewSize))" : "")
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
            panel.prompt = "Скачать сюда"; panel.message = "Куда положить скачанное?"
            panel.directoryURL = lastDir ?? def
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let u = panel.url else { log("  выбор папки отменён"); return }
            dir = u
        }
        lastDir = dir
        let title = previewTitle.isEmpty ? (preview.first?.relPath ?? "файл") : previewTitle
        let rootFolder = UserDefaults.standard.object(forKey: "makeRoot") as? Bool ?? true
        let base = (previewTitle.isEmpty || !rootFolder) ? dir : dir.appendingPathComponent(safeName(previewTitle))
        let part = chosen.count == preview.count ? "" : " (выбрано \(chosen.count) из \(preview.count))"
        let key = Set(chosen.map(\.relPath))
        if jobs.contains(where: { $0.base.standardizedFileURL == base.standardizedFileURL && !key.isDisjoint(with: $0.files.map(\.relPath)) && [.running, .waiting].contains($0.state) }) {
            status = "Эти файлы уже качаются в эту папку — дубль не добавлен"; log("  дубль не добавлен: \(link) → \(base.path)"); return
        }
        let job = Job(link: link, provider: p, title: title + part, files: chosen, base: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        job.bookmark = try? base.bookmarkData()
        log("В ОЧЕРЕДЬ «\(job.title)»: \(chosen.count) файлов → \(base.path)")
        chosen.forEach { log("   • \($0.relPath)") }
        jobs.insert(job, at: 0); QueueStore.save(jobs)
        // поле свободно под следующую ссылку
        self.link = ""; self.preview = []; skipped = []; self.provider = nil; self.previewTitle = ""; selected = []; cwd = []
        status = "Добавлено в очередь. Можно вставлять следующую ссылку"
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
        j.folderProblem = "Папку «\(j.base.lastPathComponent)» удалили или унесли на другой диск. Готово было \(j.completed.count) из \(j.files.count). Можно докачать оставшиеся \(left) в новую папку или скачать всё заново."
        log("ПАПКА ПРОПАЛА «\(j.title)»: \(j.base.path)")
        return false
    }
    /// пользователь сам показывает новое место папки. fresh = скачать всё содержимое заново
    func relink(_ j: Job, fresh: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = fresh ? "Скачать всё сюда" : "Докачать сюда"
        panel.message = fresh ? "Куда скачать всё содержимое «\(j.base.lastPathComponent)» заново?" : "Куда докачать оставшиеся файлы «\(j.base.lastPathComponent)»? Если папка просто переехала — покажи её новое место."
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
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Идёт загрузка")
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
                                       seconds: Date().timeIntervalSince(j.started), bookmark: j.bookmark ?? (try? j.base.bookmarkData())), at: 0)
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
            }
            if urls.isEmpty { throw LoaderError.parse("не удалось получить ссылку на скачивание") }
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
                if manual { status = "Доступна версия \(tag) — нажми плашку внизу окна" }
            } else { update = nil; if manual { status = "Установлена последняя версия \(cur)" } }
        } catch { if manual { status = "Не удалось проверить обновления: \(human(error))" }; log("ОБНОВЛЕНИЯ: \(error.localizedDescription)") }
    }

    /// скачать обновление, заменить приложение и перезапустить (очередь загрузок продолжится сама)
    func installUpdate() {
        guard let u = update, updateProgress == nil else { return }
        guard let zip = u.zip else { NSWorkspace.shared.open(u.url); return }   // в релизе нет zip — открываем страницу
        let appURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            updateNote = "Нет прав на папку с приложением — открываю страницу загрузки"; NSWorkspace.shared.open(u.url); return
        }
        updateProgress = 0; updateNote = ""
        log("ОБНОВЛЕНИЕ: качаю \(u.version) — \(zip.absoluteString)")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLoader-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let raw = Raw(); let fid = UUID()
        let poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in let (b, e, _, _) = raw.snapshot(); if e > 0 { self.updateProgress = min(0.99, Double(b) / Double(e)) } }
        }
        Task {
            defer { poll.invalidate() }
            do {
                let file = try await downloadFile(urls: [zip], dest: tmp.appendingPathComponent("update.zip"), renameFromServer: false, raw: raw, fid: fid, knownSize: nil, conns: 4)
                updateNote = "Устанавливаю…"; updateProgress = 1
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", file.path, tmp.path]
                try p.run(); p.waitUntilExit()
                guard let newApp = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                    throw LoaderError.parse("в архиве обновления нет приложения")
                }
                // после выхода: заменить старое приложение новым, снять карантин, открыть
                let pid = ProcessInfo.processInfo.processIdentifier
                let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
                rm -rf "\(appURL.path)" && mv "\(newApp.path)" "\(appURL.path)"
                xattr -dr com.apple.quarantine "\(appURL.path)" 2>/dev/null
                open "\(appURL.path)"
                rm -rf "\(tmp.path)"
                """
                let sh = Process(); sh.executableURL = URL(fileURLWithPath: "/bin/sh"); sh.arguments = ["-c", script]
                try sh.run()
                log("ОБНОВЛЕНИЕ: перезапуск в версию \(u.version)")
                QueueStore.save(jobs)
                NSApp.terminate(nil)
            } catch {
                updateProgress = nil; updateNote = "Не получилось обновиться: \(human(error))"
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
    var body: some View { Pill(text: p == .yandex ? "Яндекс" : "Google", color: p == .yandex ? .yellow : Color(red: 0.5, green: 0.7, blue: 1)) }
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
                seg("Спрашивать путь", icon: "questionmark.folder", on: ask) { ask = true }
                seg("По умолчанию", icon: "folder.fill", on: !ask) { switchToDefault() }
            }.fixedSize().padding(3).background(Theme.card, in: Capsule()).overlay(Capsule().stroke(Theme.line).allowsHitTesting(false))
            if !ask {
                Button { pickFolder() } label: {
                    HStack(spacing: 4) { Text(shortName).lineLimit(1).fixedSize(); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }.fixedSize()
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                }.buttonStyle(.tap).help(defaultDir + " — нажми, чтобы сменить")
                .popover(isPresented: $hint, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Создал папку для загрузок", systemImage: "folder.badge.plus").font(.system(size: 13, weight: .semibold))
                        Text("Теперь всё будет качаться в «Загрузки/DiskLoader» — как у браузера. Можно оставить или выбрать любую другую папку.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Выбрать другую…") { hint = false; pickFolder() }
                            Spacer()
                            Button("Оставить") { hint = false }.keyboardShortcut(.defaultAction)
                        }
                    }.padding(14).frame(width: 300)
                }
            }
        }
    }
    /// первый переход на «По умолчанию»: создаём Загрузки/DiskLoader и предлагаем; дальше человек выбирает сам
    func switchToDefault() {
        ask = false
        guard !setupDone else { return }
        setupDone = true
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/DiskLoader")
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

struct PickerView: View {
    @ObservedObject var m: Manager
    var listMax: CGFloat = 380
    var body: some View {
        Card {
            if m.isSingleFile, let f = m.preview.first {
                SectionHeader(text: "Один файл")
                HStack(spacing: 12) {
                    Image(systemName: fileIcon(f.relPath)).font(.system(size: 18)).foregroundStyle(Theme.pink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.relPath).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        if let s = f.size { Text(fmtBytes(s)).font(.system(size: 12)).foregroundStyle(Theme.dim) }
                    }
                    Spacer()
                    PinkButton(title: "Скачать", icon: "arrow.down") { m.addToQueue(m.preview) }.keyboardShortcut(.defaultAction)
                }.padding(14).background(Theme.row, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 10).padding(.bottom, 10)
            } else {
                HStack(spacing: 4) {
                    Button { m.cwd = [] } label: { Label(m.previewTitle.isEmpty ? "Корень" : m.previewTitle, systemImage: "externaldrive") }
                        .buttonStyle(.tap).foregroundStyle(m.cwd.isEmpty ? Theme.text : Theme.dim)
                    ForEach(Array(m.cwd.enumerated()), id: \.offset) { i, c in
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.dim)
                        Button(c) { m.cwd = Array(m.cwd.prefix(i + 1)) }.buttonStyle(.tap)
                            .foregroundStyle(i == m.cwd.count - 1 ? Theme.text : Theme.dim)
                    }
                    Spacer()
                    let here = m.filesUnder(m.cwd)
                    Button(m.mark(here) == .all ? "Снять выбор" : "Выбрать всё здесь") { m.toggle(here) }.buttonStyle(.tap).foregroundStyle(Theme.pink)
                    if !m.cwd.isEmpty { Button { m.cwd.removeLast() } label: { Label("Назад", systemImage: "arrow.uturn.left") }.buttonStyle(.tap).foregroundStyle(Theme.dim).padding(.leading, 10) }
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
                                Text("\(fs.count) файлов" + (sz > 0 ? " · " + fmtBytes(sz) : "")).foregroundStyle(Theme.dim).font(.system(size: 11))
                                Spacer()
                                Button { m.cwd.append(name) } label: {
                                    HStack(spacing: 4) { Text("Открыть"); Image(systemName: "chevron.right") }
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                                        .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.card, in: Capsule())
                                }.buttonStyle(.tap).help("Зайти в папку (или двойной клик по строке)")
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
                                Image(systemName: fileIcon(f.relPath)).frame(width: 16).foregroundStyle(Theme.dim)
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
                if !m.skipped.isEmpty { Text("Пропущено: " + m.skipped.joined(separator: "; ")).font(.caption).foregroundStyle(.orange).lineLimit(2).padding(.horizontal, 16) }
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
                Text(sel.isEmpty ? "Ничего не выбрано" : "Выбрано \(sel.count)" + (sz > 0 ? " · " + fmtBytes(sz) : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                Spacer(minLength: 8)
                GhostButton(title: "Скачать выбранное", disabled: sel.isEmpty) { m.flashThenQueue(m.selectedFiles) }
                PinkButton(title: "Скачать всё", icon: "arrow.down") { m.flashThenQueue(m.preview) }.keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(sel.isEmpty ? "Ничего не выбрано" : "Выбрано \(sel.count)").font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer(minLength: 8)
                    GhostButton(title: "Выбранное", disabled: sel.isEmpty) { m.flashThenQueue(m.selectedFiles) }
                    PinkButton(title: "Всё", icon: "arrow.down") { m.flashThenQueue(m.preview) }.keyboardShortcut(.defaultAction)
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
                        ProviderBadge(p: j.provider)
                    }
                    Text(j.base.path).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                stateLabel
                if j.state == .running || j.state == .waiting {
                    Button { m.stop(j) } label: { Image(systemName: "pause.circle.fill") }.buttonStyle(.tap).foregroundStyle(Theme.pink).help("Пауза")
                } else {
                    if j.state != .done { Button { m.resume(j) } label: { Image(systemName: "play.circle.fill") }.buttonStyle(.tap).foregroundStyle(Theme.pink).help("Продолжить с места остановки") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([j.base]) } label: { Image(systemName: "folder") }.buttonStyle(.tap).foregroundStyle(Theme.dim).help("Показать в Finder")
                }
                Button { m.remove(j) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.tap).foregroundStyle(Theme.dim).help("Убрать задачу (скачанное останется)")
            }.font(.system(size: 15))
            PinkBar(value: j.progress, color: color)
            HStack(spacing: 16) {
                Label("\(j.doneCount) из \(j.files.count)", systemImage: "doc.on.doc")
                Label(fmtBytes(j.bytesDone) + (j.expected > 0 ? " из " + fmtBytes(j.expected) : ""), systemImage: "internaldrive")
                if j.state == .running { Label(fmtBytes(Int64(j.speed)) + "/с", systemImage: "speedometer").foregroundStyle(Theme.pink) }
                Spacer()
                Button(open ? "Скрыть файлы" : "Файлы") { open.toggle() }.buttonStyle(.tap).foregroundStyle(Theme.dim)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim).monospacedDigit()
            if let fp = j.folderProblem {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange)
                    Text(fp).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        PinkButton(title: "Докачать оставшееся…", icon: "arrow.down.to.line") { m.relink(j) }.keyboardShortcut(.defaultAction)
                        GhostButton(title: "Скачать всё заново…", icon: "arrow.clockwise") { m.relink(j, fresh: true) }
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
                    if j.failed.count > 4 { Text("и ещё \(j.failed.count - 4) — подробности в Журнале").foregroundStyle(Theme.dim) }
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
        case .waiting: Pill(text: "в очереди")
        case .running: Pill(text: "качаю", color: Theme.pink)
        case .done: Pill(text: "готово", color: .green)
        case .stopped: Pill(text: "на паузе", color: .orange)
        case .failed: Pill(text: "ошибки", color: .red)
        }
    }
}

struct DownloadPage: View {
    @ObservedObject var m: Manager
    var body: some View {
      GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(text: "Скачать", trailing: AnyView(SaveModeSwitch()))
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(Theme.dim)
                        TextField("Ссылка на Яндекс Диск или Google Диск", text: $m.link)
                            .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.text).onSubmit { m.check() }
                        Divider().frame(height: 22)
                        Button { if let s = NSPasteboard.general.string(forType: .string) { m.link = s; m.check() } } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                            .buttonStyle(.tap).foregroundStyle(Theme.dim)
                        Button { m.check() } label: { Label("Проверить", systemImage: "magnifyingglass") }
                            .buttonStyle(.tap).foregroundStyle(m.link.isEmpty ? Theme.dim.opacity(0.5) : Theme.text).disabled(m.busy || m.link.isEmpty)
                    }.padding(16)
                    Divider().overlay(Theme.line)
                    HStack(spacing: 8) {
                        if m.busy { ProgressView().controlSize(.small) }
                        if let p = m.provider { ProviderBadge(p: p) }
                        Text(m.status).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }
                if !m.preview.isEmpty { PickerView(m: m, listMax: max(120, min(460, geo.size.height - 360))) }
                HStack {
                    Text("ЗАГРУЗКИ").font(.system(size: 11, weight: .semibold)).kerning(1).foregroundStyle(Theme.dim)
                    if m.summary.speed > 0 { Text(fmtBytes(Int64(m.summary.speed)) + "/с").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.pink).monospacedDigit() }
                    Spacer()
                    if m.jobs.contains(where: { $0.state == .done }) {
                        Button("Убрать завершённые") { m.clearFinished() }.buttonStyle(.tap).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }.padding(.top, 4)
                if m.jobs.isEmpty {
                    Text("Пока пусто. Каждая ссылка — отдельная задача, новые можно добавлять, пока идут старые.")
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

let ruDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy 'г. в' HH:mm"; return f }()
func fmtDur(_ s: Double) -> String { s < 60 ? "\(Int(s)) с" : s < 3600 ? "\(Int(s / 60)) мин \(Int(s) % 60) с" : "\(Int(s / 3600)) ч \(Int(s) % 3600 / 60) мин" }

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
                IconBtn(icon: "folder", help: exists ? "Показать в Finder" : "Папки нет на месте", disabled: !exists) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.path)]) }
                IconBtn(icon: "doc.on.doc", help: "Скопировать ссылку") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.link, forType: .string) }
                IconBtn(icon: "arrow.counterclockwise", help: "Открыть ссылку снова", color: Theme.pink) { m.link = h.link; m.page = .download; m.check() }
                IconBtn(icon: "trash", help: "Убрать из истории") { m.history.removeAll { $0.id == h.id }; History.save(m.history) }
            }
            HStack(spacing: 8) {
                Text(h.title).font(.system(size: 14).italic()).foregroundStyle(Theme.text).lineLimit(2)
                Pill(text: h.provider == Provider.yandex.rawValue ? "Яндекс" : "Google")
                statePill
            }
            HStack(spacing: 16) {
                Label("\(h.files) из \(h.total) файлов", systemImage: "doc.on.doc")
                Label(fmtBytes(h.bytes), systemImage: "internaldrive")
                if let s = h.seconds, s > 1 {
                    Label(fmtBytes(Int64(Double(h.bytes) / s)) + "/с в среднем", systemImage: "speedometer")
                    Label(fmtDur(s), systemImage: "clock")
                }
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim).monospacedDigit()
            HStack(spacing: 6) {
                if exists {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.dim)
                    Text(h.path).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                } else if let to = movedTo, to.contains("/.Trash") {
                    Image(systemName: "trash.fill").foregroundStyle(.orange)
                    Text("Папка в Корзине").foregroundStyle(.orange)
                } else if let to = movedTo {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.orange)
                    Text("Папку перенесли:").foregroundStyle(.orange)
                    Button(to) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: to)]) }.buttonStyle(.tap).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Папка перемещена или удалена с устройства").foregroundStyle(.orange)
                    Text(h.path).foregroundStyle(Theme.dim.opacity(0.6)).lineLimit(1).truncationMode(.head).strikethrough()
                }
            }.font(.system(size: 11))
        }.padding(.horizontal, 18).padding(.vertical, 16)
    }
    @ViewBuilder var statePill: some View {
        switch h.state {
        case "done": Pill(text: "готово", color: .green)
        case "failed": Pill(text: "с ошибками", color: .red)
        default: Pill(text: "остановлено", color: .orange)
        }
    }
}

struct HistoryPage: View {
    @ObservedObject var m: Manager
    @State var q = ""
    @AppStorage("defaultDir") var defaultDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    var items: [HistoryItem] { q.isEmpty ? m.history : m.history.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) } }
    var active: [Job] { m.jobs.filter { $0.state == .running || $0.state == .waiting } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("ИСТОРИЯ").font(.system(size: 13, weight: .semibold)).kerning(1.2).foregroundStyle(Theme.dim)
                    Spacer()
                    GhostButton(title: "Открыть папку загрузок", icon: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: defaultDir)) }
                    if !m.history.isEmpty { GhostButton(title: "Очистить", icon: "trash") { m.history = []; History.save([]); log("ИСТОРИЯ очищена") } }
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                    TextField("Поиск по названию или папке", text: $q).textFieldStyle(.plain).foregroundStyle(Theme.text)
                }.padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                if !active.isEmpty {
                    Text("СЕЙЧАС КАЧАЕТСЯ").font(.system(size: 11, weight: .semibold)).kerning(1).foregroundStyle(Theme.dim)
                    ForEach(active) { JobRow(j: $0, m: m) }
                }
                if items.isEmpty {
                    Text(m.history.isEmpty ? "Здесь появятся завершённые загрузки" : "Ничего не найдено")
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
    @AppStorage("totalConns") var totalConns = 16
    @AppStorage("googleKey") var googleKey = ""
    @AppStorage("ghRepo") var ghRepo = ""
    @ObservedObject var m: Manager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(text: "Настройки")
                Card {
                    SectionHeader(text: "Куда скачивать")
                    VStack(spacing: 8) {
                        SettingRow(title: "Папка по умолчанию", sub: defaultDir) {
                            GhostButton(title: "Выбрать…", icon: "folder") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                                p.directoryURL = URL(fileURLWithPath: defaultDir)
                                if p.runModal() == .OK, let u = p.url { defaultDir = u.path; log("НАСТРОЙКИ папка по умолчанию → \(u.path)") }
                            }
                        }
                        SettingRow(title: "Спрашивать каждый раз", sub: ask ? "Перед скачиванием откроется окно выбора папки (начнёт с папки по умолчанию)" : "Скачивание сразу в папку по умолчанию, без вопросов") {
                            Toggle("", isOn: $ask).toggleStyle(.switch).tint(Theme.pink).labelsHidden()
                        }
                        SettingRow(title: "Создавать папку с названием", sub: "Папка с диска кладётся внутрь своей папки, а не россыпью") {
                            Toggle("", isOn: $makeRoot).toggleStyle(.switch).tint(Theme.pink).labelsHidden()
                        }
                        SettingRow(title: "Показать в Finder после загрузки", sub: "Открывать папку, когда задача завершилась без ошибок") {
                            Toggle("", isOn: $reveal).toggleStyle(.switch).tint(Theme.pink).labelsHidden()
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: "Скорость")
                    VStack(spacing: 8) {
                        SettingRow(title: "Файлов одновременно", sub: "В одной задаче. Больше — быстрее на мелких файлах") {
                            Stepper("\(perJob)", value: $perJob, in: 1...8).foregroundStyle(Theme.text).monospacedDigit()
                        }
                        SettingRow(title: "Задач одновременно", sub: "Остальные ждут в очереди") {
                            Stepper("\(maxJobs)", value: $maxJobs, in: 1...4).foregroundStyle(Theme.text).monospacedDigit()
                        }
                        SettingRow(title: "Всего подключений", sub: "Общий потолок на всё приложение. Больше 16–24 серверы обычно начинают придерживать") {
                            Stepper("\(totalConns)", value: $totalConns, in: 4...48, step: 4).foregroundStyle(Theme.text).monospacedDigit()
                        }
                        SettingRow(title: "Потоков на один файл", sub: "Большой файл качается частями параллельно. 8 — обычно максимум скорости") {
                            Stepper("\(conns)", value: $conns, in: 1...16).foregroundStyle(Theme.text).monospacedDigit()
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: "Запасные пути и обновления")
                    VStack(spacing: 8) {
                        SettingRow(title: "Ключ Google API (необязательно)", sub: "Если Google изменит публичные страницы — приложение пойдёт через официальный Drive API. Ключ бесплатный: console.cloud.google.com → Drive API → Credentials") {
                            SecureField("AIza…", text: $googleKey).textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                        SettingRow(title: "Обновления", sub: "Приложение само проверяет новые версии на GitHub (\(Manager.defaultRepo)) и предлагает обновиться внизу окна") {
                            HStack {
                                TextField(Manager.defaultRepo, text: $ghRepo).textFieldStyle(.roundedBorder).frame(width: 170)
                                GhostButton(title: "Проверить") { Task { await m.checkUpdate(manual: true) }; m.page = .download }
                            }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
                Card {
                    SectionHeader(text: "Журнал")
                    SettingRow(title: "Журнал работы", sub: logURL.path) {
                        GhostButton(title: "Открыть", icon: "list.bullet.rectangle") { NSWorkspace.shared.open(logURL) }
                    }.padding(.horizontal, 10).padding(.bottom, 10)
                }
            }.padding(28)
        }
    }
}

struct AboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(text: "О программе")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Logo(size: 26)
                    Text("Скачивание по публичным ссылкам Яндекс Диска и Google Диска. Работает автономно, без нейросетей.")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                    Text("Версия " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).font(.system(size: 12)).foregroundStyle(Theme.dim)
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
    var icon: String { switch self { case .download: "arrow.down.circle"; case .history: "clock.arrow.circlepath"; case .settings: "gearshape"; case .about: "info.circle" } }
}

extension Manager { }

struct Logo: View {
    var size: CGFloat = 24
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: size * 0.95, weight: .semibold)).foregroundStyle(Theme.pink)
            Text("DiskLoader").font(.system(size: size, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
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
                Text(page.rawValue).font(.system(size: 15, weight: .medium))
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
                            IconBtn(icon: "sidebar.left", help: "Скрыть меню") { withAnimation(.easeInOut(duration: 0.2)) { sideHidden = true } }
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
                            IconBtn(icon: "sidebar.left", help: "Показать меню", color: Theme.text) { withAnimation(.easeInOut(duration: 0.2)) { sideHidden = false } }
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
                if running == 0 { Text(m.jobs.isEmpty ? "Готов к работе" : "Всё скачано").foregroundStyle(Theme.dim) }
                else {
                    Text("Качаю: \(running) · \(m.summary.percent)% · \(fmtBytes(Int64(m.summary.speed)))/с").foregroundStyle(Theme.text).monospacedDigit()
                }
                Spacer()
                if let u = m.update {
                    if let p = m.updateProgress {
                        Text(p >= 1 ? "Устанавливаю…" : "Загрузка… \(Int(p * 100)) %").foregroundStyle(Theme.dim).monospacedDigit()
                        PinkBar(value: p).frame(width: 180)
                    } else {
                        Button("Доступно обновление \(u.version)") { m.installUpdate() }.buttonStyle(.tap).foregroundStyle(Theme.pink)
                            .help("Скачать и установить — очередь загрузок продолжится сама")
                    }
                    Text("·").foregroundStyle(Theme.dim)
                }
                if !m.updateNote.isEmpty && m.updateProgress == nil { Text(m.updateNote).foregroundStyle(.orange).lineLimit(1); Text("·").foregroundStyle(Theme.dim) }
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).foregroundStyle(Theme.dim)
            }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 9).background(Theme.side)
        }
        .frame(minWidth: 780, minHeight: 640)
        .preferredColorScheme(.dark)
        // меню схлопнули — всегда возвращаемся на «Скачать»
        .onChange(of: sideHidden) { _, hidden in if hidden { m.page = .download } }
    }
}

#if !TEST
@main
struct DiskLoaderApp: App {
    init() {
        // уже запущен другой DiskLoader (например, вторая копия) — показываем его и выходим
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.diskloader").first(where: { $0.processIdentifier != me }) {
            other.activate(); exit(0)
        }
        NSApplication.shared.setActivationPolicy(.regular); log("=== DiskLoader запущен ===")
    }
    var body: some Scene {
        WindowGroup("DiskLoader") { ContentView() }.windowResizability(.contentMinSize)
    }
}
#endif
