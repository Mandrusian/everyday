package app.everyday.android

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** The Rust core (windows/mobile). Every command is one JSON round trip; secrets are passed in from the Keystore and saved back. */
object Core {
    init { System.loadLibrary("everyday_mobile") }
    @JvmStatic private external fun init(dir: String): String
    @JvmStatic private external fun call(cmd: String, args: String): String

    private lateinit var secrets: Secrets

    lateinit var app: Context
    fun open(ctx: Context) {
        app = ctx.applicationContext
        secrets = Secrets(ctx)
        val err = init(ctx.filesDir.absolutePath)
        if (err.isNotEmpty()) throw IllegalStateException(err)
    }

    class Failure(message: String) : Exception(message)

    /** Runs a command off the main thread. Returns the "ok" value (JSONObject, JSONArray, String, Number, Boolean or null). */
    suspend fun run(cmd: String, args: JSONObject = JSONObject()): Any? = withContext(Dispatchers.IO) {
        args.put("_secrets", secrets.all())
        val out = JSONObject(call(cmd, args.toString()))
        out.optJSONObject("secrets")?.let { s -> s.keys().forEach { k -> secrets.set(k, s.getString(k)) } }
        if (out.has("err")) throw Failure(out.getString("err"))
        out.opt("ok").takeUnless { it == JSONObject.NULL }
    }

    suspend fun list(cmd: String, args: JSONObject = JSONObject()): List<JSONObject> {
        val a = run(cmd, args) as? JSONArray ?: return emptyList()
        return (0 until a.length()).map { a.getJSONObject(it) }
    }

    fun forget(key: String) = secrets.delete(key)
}

fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { pairs.forEach { (k, v) -> put(k, v) } }
