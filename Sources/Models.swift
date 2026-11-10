import Foundation

// MARK: - 站点

struct Site: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var url: String
    var category: String
    var searchTemplate: String?
    var icon: String

    init(id: String? = nil,
         name: String,
         url: String,
         category: String,
         searchTemplate: String? = nil,
         icon: String = "globe") {
        self.id = id ?? name
        self.name = name
        self.url = url
        self.category = category
        self.searchTemplate = searchTemplate
        self.icon = icon
    }
}

// MARK: - 磁力引擎

struct MagnetEngine: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var home: String
    var search: String

    static let all: [MagnetEngine] = [
        MagnetEngine(name: "Sukebei", home: "https://sukebei.nyaa.si",
                     search: "https://sukebei.nyaa.si/?f=0&c=0_0&q={q}"),
        MagnetEngine(name: "Btdig", home: "https://btdig.com",
                     search: "https://btdig.com/search?q={q}"),
        MagnetEngine(name: "JavDB", home: "https://javdb.com",
                     search: "https://javdb.com/search?q={q}&f=all"),
        MagnetEngine(name: "1337x", home: "https://1337x.to",
                     search: "https://1337x.to/search/{q}/1/"),
        MagnetEngine(name: "PirateBay", home: "https://thepiratebay.org",
                     search: "https://thepiratebay.org/search.php?q={q}"),
        MagnetEngine(name: "TorrentGalaxy", home: "https://torrentgalaxy.to",
                     search: "https://torrentgalaxy.to/torrents.php?search={q}"),
        MagnetEngine(name: "BTSOW", home: "https://btsow.com",
                     search: "https://btsow.com/search/{q}"),
        MagnetEngine(name: "BT4G", home: "https://bt4gprx.com",
                     search: "https://bt4gprx.com/search?q={q}")
    ]
}

// MARK: - 书签 / 历史

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var site: String
    var date: Date = Date()
}

// MARK: - 本地存储

enum Prefs {
    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    static func set(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func load<T: Codable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Codable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 内置站点清单（要增删改，只动这里）

extension Site {
    static let defaults: [Site] = [

        // ── 视频 ──
        Site(name: "Pornhub", url: "https://www.pornhub.com", category: "视频",
             searchTemplate: "https://www.pornhub.com/video/search?search={q}", icon: "play.rectangle.fill"),
        Site(name: "XVideos", url: "https://www.xvideos.com", category: "视频",
             searchTemplate: "https://www.xvideos.com/?k={q}", icon: "play.rectangle.fill"),
        Site(name: "XNXX", url: "https://www.xnxx.com", category: "视频",
             searchTemplate: "https://www.xnxx.com/search/{q}", icon: "play.rectangle.fill"),
        Site(name: "Hanime", url: "https://hanime.tv", category: "视频",
             searchTemplate: "https://hanime.tv/search?q={q}", icon: "sparkles.tv.fill"),
        Site(name: "MissAV", url: "https://missav.com", category: "视频",
             searchTemplate: "https://missav.com/search/{q}", icon: "film.fill"),
        Site(name: "Jable", url: "https://jable.tv", category: "视频",
             searchTemplate: "https://jable.tv/search/{q}/", icon: "film.fill"),
        Site(name: "Supjav", url: "https://supjav.com", category: "视频",
             searchTemplate: "https://supjav.com/?s={q}", icon: "film.fill"),
        Site(name: "Netflav", url: "https://netflav.com", category: "视频",
             searchTemplate: "https://netflav.com/search?type=title&keyword={q}", icon: "film.fill"),
        Site(name: "AVGLE", url: "https://avgle.com", category: "视频",
             searchTemplate: "https://avgle.com/search/{q}", icon: "film.fill"),
        Site(name: "SpankBang", url: "https://spankbang.com", category: "视频",
             searchTemplate: "https://spankbang.com/s/{q}/", icon: "play.rectangle.fill"),
        Site(name: "Eporner", url: "https://www.eporner.com", category: "视频",
             searchTemplate: "https://www.eporner.com/search/{q}/", icon: "play.rectangle.fill"),
        Site(name: "91Porn", url: "https://91porn.com", category: "视频",
             searchTemplate: nil, icon: "video.fill"),

        // ── 漫画 ──
        Site(name: "禁漫天堂", url: "https://18comic.vip", category: "漫画",
             searchTemplate: "https://18comic.vip/search/photos?search_query={q}", icon: "book.fill"),
        Site(name: "禁漫备用", url: "https://jmcomic.me", category: "漫画",
             searchTemplate: "https://jmcomic.me/search/photos?search_query={q}", icon: "book.fill"),
        Site(name: "Hitomi", url: "https://hitomi.la", category: "漫画",
             searchTemplate: "https://hitomi.la/search.html?{q}", icon: "book.fill"),
        Site(name: "nhentai", url: "https://nhentai.net", category: "漫画",
             searchTemplate: "https://nhentai.net/search/?q={q}", icon: "book.fill"),
        Site(name: "E-Hentai", url: "https://e-hentai.org", category: "漫画",
             searchTemplate: "https://e-hentai.org/?f_search={q}", icon: "book.fill"),

        // ── 磁力（站内搜索用） ──
        Site(name: "Sukebei", url: "https://sukebei.nyaa.si", category: "磁力",
             searchTemplate: "https://sukebei.nyaa.si/?f=0&c=0_0&q={q}", icon: "link"),
        Site(name: "JavDB", url: "https://javdb.com", category: "磁力",
             searchTemplate: "https://javdb.com/search?q={q}&f=all", icon: "link"),
        Site(name: "Btdig", url: "https://btdig.com", category: "磁力",
             searchTemplate: "https://btdig.com/search?q={q}", icon: "link"),
        Site(name: "BTSOW", url: "https://btsow.com", category: "磁力",
             searchTemplate: "https://btsow.com/search/{q}", icon: "link"),

        // ── 图集 / 综合 ──
        Site(name: "NudeCelebs", url: "https://nudecelebs.pro", category: "综合",
             searchTemplate: nil, icon: "photo.on.rectangle.fill"),
        Site(name: "Rule34", url: "https://rule34.xxx", category: "综合",
             searchTemplate: "https://rule34.xxx/index.php?page=post&s=list&tags={q}", icon: "photo.on.rectangle.fill")
    ]
}
