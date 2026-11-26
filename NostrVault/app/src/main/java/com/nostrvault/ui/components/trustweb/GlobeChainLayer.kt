package com.nostrvault.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import com.nostrvault.data.model.GlobeChain

/**
 * The trust card's hop-sphere person's path to you ([GlobeChainPainter]),
 * over the spheres: its glow in a blurred layer (API 31+, as the inner
 * globe's threads), the line on top. Drawn again every frame so it follows
 * the spin. iOS `TrustGlobeCanvas.drawChain`.
 */
@Composable
internal fun GlobeChainLayer(scene: GlobeScene, links: List<GlobeChain.Link>, born: Double, focus: String?, blurred: Boolean) {
    if (links.isEmpty() || focus != links.first().key) return
    fun DrawScope.frame(): GlobeChainPainter.Frame? {
        // Read as state, so the path redraws as the globe turns.
        scene.frame
        return GlobeChainPainter.frame(links, born, nowSeconds(), scene, size.width, size.height)
    }
    Canvas(
        Modifier
            .fillMaxSize()
            .then(if (blurred) Modifier.graphicsLayer { renderEffect = GlobeThreads.glowBlur(density) } else Modifier),
    ) { frame()?.let { GlobeChainPainter.drawGlow(this, it, blurred) } }
    Canvas(Modifier.fillMaxSize()) { frame()?.let { GlobeChainPainter.drawLine(this, it) } }
}
