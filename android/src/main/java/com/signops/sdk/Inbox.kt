package com.signops

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder

/**
 * The user's notification inbox (Starter and Pro). Your server makes the token for the signed-in user with
 * POST /v1/inbox/token; the app never names the user itself.
 *
 *     val page = signops.inbox.list(token)
 *     signops.inbox.read(token, listOf(page.items[0].id))
 */
class Inbox internal constructor(private val signops: SignOps) {
    data class Item(val id: String, val title: String?, val body: String?, val link: String?, val image: String?, val data: Map<String, String>, val pushId: String?, val createdAt: String, val read: Boolean)
    data class Page(val items: List<Item>, val unread: Int, val next: String?)

    private fun h(token: String) = mapOf("signops-inbox-token" to token)

    suspend fun list(token: String, limit: Int = 20, before: String? = null): Page {
        val qs = "limit=$limit" + (before?.let { "&before=" + URLEncoder.encode(it, "UTF-8") } ?: "")
        return parse(signops.get("/v1/inbox?$qs", h(token)))
    }
    suspend fun read(token: String, ids: List<String>): Int = signops.post("/v1/inbox/read", JSONObject().put("ids", JSONArray(ids)), h(token)).optInt("read")
    suspend fun readAll(token: String): Int = signops.post("/v1/inbox/read", JSONObject().put("all", true), h(token)).optInt("read")
    suspend fun remove(token: String, id: String) { signops.delete("/v1/inbox/" + URLEncoder.encode(id, "UTF-8"), h(token)) }

    companion object {
        internal fun parse(j: JSONObject): Page {
            val a = j.optJSONArray("data") ?: JSONArray()
            val items = (0 until a.length()).map { i ->
                val o = a.getJSONObject(i)
                val d = o.optJSONObject("data")
                Item(o.getString("id"), o.str("title"), o.str("body"), o.str("link"), o.str("image"),
                    d?.keys()?.asSequence()?.associateWith { d.optString(it) } ?: emptyMap(), o.str("push_id"), o.getString("created_at"), o.optBoolean("read"))
            }
            return Page(items, j.optInt("unread"), j.str("next"))
        }
        private fun JSONObject.str(k: String): String? = if (isNull(k)) null else optString(k).ifEmpty { null }
    }
}
