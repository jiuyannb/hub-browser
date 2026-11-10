import SwiftUI
import WebKit

final class AppStore: ObservableObject {
    @Published var sites: [Site]
    @Published var bookmarks: [Bookmark]
    @Published var history: [Bookmark]
    @Published var incognito: Bool
    @Published var blockAds: Bool
    @Published var desktopUA: Bool

    init() {
        sites = Prefs.load([Site].self, "sites") ?? Site.defaults
        bookmarks = Prefs.load([Bookmark].self, "bookmarks") ?? []
        history = Prefs.load([Bookmark].self, "history") ?? []
        incognito = Prefs.bool("incognito", false)
        blockAds = Prefs.bool("blockAds", true)
        desktopUA = Prefs.bool("desktopUA", false)
    }

    func addBookmark(_ b: Bookmark) {
        guard !b.url.isEmpty else { return }
        guard !bookmarks.contains(where: { $0.url == b.url }) else { return }
        bookmarks.insert(b, at: 0)
        Prefs.save(bookmarks, "bookmarks")
    }

    func removeBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0.id == b.id }
        Prefs.save(bookmarks, "bookmarks")
    }

    func record(_ b: Bookmark) {
        guard !incognito, !b.url.isEmpty else { return }
        history.insert(b, at: 0)
        if history.count > 300 {
            history.removeLast(history.count - 300)
        }
        Prefs.save(history, "history")
    }

    func clearHistory() {
        history.removeAll()
        Prefs.save(history, "history")
    }

    func clearWebData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date.distantPast
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: date) {}
        HTTPCookieStorage.shared.removeCookies(since: date)
    }

    func update(_ site: Site) {
        if let idx = sites.firstIndex(where: { $0.id == site.id }) {
            sites[idx] = site
            Prefs.save(sites, "sites")
        }
    }
}
