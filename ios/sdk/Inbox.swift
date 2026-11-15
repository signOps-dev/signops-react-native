import Foundation

/// The user's notification inbox (Starter and Pro). Your server makes the token for the signed-in user with
/// POST /v1/inbox/token; the app never names the user itself.
///
///     let page = try await signops.inbox.list(token: token)
///     try await signops.inbox.read(token: token, ids: [page.items[0].id])
public struct Inbox {
    let signops: SignOps

    public struct Item: Equatable {
        public let id: String
        public let title: String?, body: String?, link: String?, image: String?
        public let data: [String: String]
        public let pushId: String?
        public let createdAt: String
        public let read: Bool
    }
    public struct Page: Equatable { public let items: [Item]; public let unread: Int; public let next: String? }

    private func h(_ token: String) -> [String: String] { ["signops-inbox-token": token] }

    public func list(token: String, limit: Int = 20, before: String? = nil) async throws -> Page {
        var path = "/v1/inbox?limit=\(limit)"
        if let b = before, let e = b.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { path += "&before=\(e)" }
        return Inbox.parse(try await signops.get(path, headers: h(token)))
    }
    @discardableResult public func read(token: String, ids: [String]) async throws -> Int { (try await signops.post("/v1/inbox/read", ["ids": ids], headers: h(token)))["read"] as? Int ?? 0 }
    @discardableResult public func readAll(token: String) async throws -> Int { (try await signops.post("/v1/inbox/read", ["all": true], headers: h(token)))["read"] as? Int ?? 0 }
    public func remove(token: String, id: String) async throws { _ = try await signops.delete("/v1/inbox/\(id)", headers: h(token)) }

    static func parse(_ j: [String: Any]) -> Page {
        let s = { (o: [String: Any], k: String) in o[k] as? String }
        let items = (j["data"] as? [[String: Any]] ?? []).map { o in
            Item(id: s(o, "id") ?? "", title: s(o, "title"), body: s(o, "body"), link: s(o, "link"), image: s(o, "image"),
                 data: (o["data"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }, pushId: s(o, "push_id"),
                 createdAt: s(o, "created_at") ?? "", read: o["read"] as? Bool ?? false)
        }
        return Page(items: items, unread: j["unread"] as? Int ?? 0, next: j["next"] as? String)
    }
}
