package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale

/**
 * How a grid tile draws its picture. A photo fills the tile. A video's frame is
 * drawn whole on a dark tile, since a phone's portrait video cropped to a
 * square showed only its middle and looked zoomed in (Logen 11-11). iOS:
 * VideoThumbnailView.
 */
internal fun mediaTileContentScale(isVideo: Boolean): ContentScale =
    if (isVideo) ContentScale.Fit else ContentScale.Crop

/** The dark tile a video's frame sits on, so the bars around it read as part of the tile. */
internal fun Modifier.videoTileBackground(isVideo: Boolean): Modifier =
    if (isVideo) background(Color.Black) else this
