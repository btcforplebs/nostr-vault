package com.nostrvault.fips

import com.nostrvault.data.local.ConfigStore
import kotlinx.coroutines.runBlocking
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The live door for the in-app browser: `FipsBridge.ingress(npub)` with the reason when there is none
 * (iOS FipsMeshService.siteIngress). Never the media router's cached door: a "no tree yet" there is remembered
 * for 30 s, and a page waits for the tree instead. Blocks: call it off the main thread.
 */
@Singleton
class MeshSiteDoor @Inject constructor(
    private val configStore: ConfigStore,
    private val mesh: FipsMeshManager,
) {
    fun ingress(npub: String): MeshSiteIngress {
        val config = configStore.config.value
        if (!config.fipsMeshEnabled) return MeshSiteIngress.MeshOff
        if (!FipsBridge.isAvailable) return MeshSiteIngress.Failed
        // On but not up yet (the app just opened, or it stopped): start it the way Settings does.
        if (!FipsBridge.status().running && !runBlocking { mesh.start(persist = false) }) return MeshSiteIngress.EngineOff
        val result = FipsBridge.ingress(npub)
        result.url?.let { return MeshSiteIngress.Ready(it) }
        return MeshSiteIngress.fromCode(result.error, config.fipsMesh.middleServer == FipsMeshSettings.MIDDLE_PUBLIC)
    }
}
