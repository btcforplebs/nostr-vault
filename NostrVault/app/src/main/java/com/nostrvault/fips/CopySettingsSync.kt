package com.nostrvault.fips

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Settings stay synced across own devices (Logen's pick 1, contract §5): this app writes [CopySettings.FILE] in the
 * data dir whenever an allowlisted setting changes, and applies the file when the engine leaves another device's there
 * (after a copy, or a catch-up where the other device's newer change won).
 */
@Singleton
class CopySettingsSync internal constructor(
    private val dataDir: () -> File,
    private val configStore: ConfigStore,
    private val baseline: Baseline,
    private val scope: CoroutineScope,
    private val nowS: () -> Long = { System.currentTimeMillis() / 1000 },
) {
    @Inject constructor(
        @ApplicationContext context: Context,
        configStore: ConfigStore,
        @ApplicationScope scope: CoroutineScope,
    ) : this(
        dataDir = { configStore.config.value.relayDataDir?.let(::File) ?: File(context.filesDir, "relay_data") },
        configStore = configStore,
        baseline = PrefsBaseline(context),
        scope = scope,
    )

    /** The keys and `updated_at` of the last file this device wrote or applied. */
    interface Baseline {
        var keys: String?
        var at: Long
    }

    sealed interface Step {
        data object Nothing : Step
        /**
         * A listed setting changed here, or there is no file yet: write the file dated [at]. The first file is dated
         * [FIRST_FILE_AT], since nothing here changed before it and any real change on a linked device must win.
         */
        data class Write(val at: Long) : Step
        /** The engine left a file this device didn't write: apply it. */
        data class Apply(val file: CopySettings.Checked, val rewriteAt: Long? = null) : Step
    }

    private val lock = Mutex()

    /** From app start: every change of a listed setting is written; a newer file is applied first. */
    fun start() {
        scope.launch(Dispatchers.IO) {
            configStore.config.map { CopySettings.keys(it).toString() to it.hasCompletedSetup }.distinctUntilChanged().collect { sync() }
        }
    }

    /** Once more now (a `COPY stage=done` line: the engine may have left a newer file). */
    fun syncNow() {
        scope.launch(Dispatchers.IO) { sync() }
    }

    private suspend fun sync() = lock.withLock {
        val file = File(dataDir(), CopySettings.FILE)
        val raw = runCatching { file.takeIf { it.exists() }?.readText() }.getOrNull()
        val config = configStore.config.value
        val current = CopySettings.keys(config)
        when (val s = step(current, raw, baseline.keys, baseline.at, nowS(), config.hasCompletedSetup)) {
            Step.Nothing -> Unit
            is Step.Write -> {
                val at = s.at
                write(file, CopySettings.file(current, at))
                baseline.keys = current.toString()
                baseline.at = at
            }
            is Step.Apply -> {
                configStore.updateAsync { CopySettings.apply(it, s.file.keys) }
                // What this device holds now (its own mesh servers kept), so applying is not read as a change here.
                val applied = CopySettings.keys(configStore.config.value)
                s.rewriteAt?.let { write(file, CopySettings.file(applied, it)) }
                baseline.keys = applied.toString()
                baseline.at = s.rewriteAt ?: s.file.updatedAt
            }
        }
    }

    private fun write(file: File, body: String) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.partial")
        tmp.delete()
        tmp.createNewFile()
        MeshCopyStarter.ownerOnly(tmp)
        tmp.writeText(body)
        if (!tmp.renameTo(file)) tmp.delete()
    }

    companion object {
        /** The date of this device's first file: older than any real change, so a linked device's change wins. */
        const val FIRST_FILE_AT = 1L

        /**
         * What to do with this device's [current] keys and the file's [raw] content. Only this app and the engine
         * write the file, and the engine writes only a winner (newest `updated_at`, contract §5), so a file this
         * device did not write last is applied. A missing or refused file is written over with this device's own.
         * Nothing is written before [setupDone]: a fresh device's defaults must never reach a linked device (Tron,
         * #1784). As on Apple, a file the engine left is still applied during setup.
         */
        fun step(current: JsonObject, raw: String?, baselineKeys: String?, baselineAt: Long, nowS: Long, setupDone: Boolean): Step {
            val write = if (setupDone) Step.Write(if (raw == null) FIRST_FILE_AT else nowS) else Step.Nothing
            val checked = raw?.let { CopySettings.check(it, nowS).first } ?: return write
            val foreign = baselineKeys == null || checked.updatedAt != baselineAt
            // A file with the retired "condensed" layout is applied, then written over clean (dated now), so it stops
            // reaching linked devices (11/14). Not during setup: nothing is written then.
            if (foreign) return if (checked.keys == current) Step.Nothing
            else Step.Apply(checked, rewriteAt = nowS.takeIf { setupDone && CopySettings.holdsRetiredLayout(checked.keys) })
            return if (sameKeys(baselineKeys!!, current)) Step.Nothing else write
        }

        private fun sameKeys(a: String, b: JsonObject) = runCatching { Json.parseToJsonElement(a) == b }.getOrDefault(false)
    }

    private class PrefsBaseline(context: Context) : Baseline {
        private val prefs = context.getSharedPreferences("copy_settings", Context.MODE_PRIVATE)
        override var keys: String?
            get() = prefs.getString("keys", null)
            set(v) { prefs.edit().putString("keys", v).apply() }
        override var at: Long
            get() = prefs.getLong("at", 0)
            set(v) { prefs.edit().putLong("at", v).apply() }
    }
}
