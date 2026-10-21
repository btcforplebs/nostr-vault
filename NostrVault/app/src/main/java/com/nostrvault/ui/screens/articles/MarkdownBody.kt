package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BorderColor
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.ArticleEngagement
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.MarkdownBlock
import com.nostrvault.ui.components.appendInlineMarkdown
import com.nostrvault.ui.theme.*

private val inlineLinkPattern = Regex("""(!?)\[([^\]]*)]\(([^)\s]+)(?:\s+"[^"]*")?\)""")

/**
 * A block's inline markdown as styled text: bold, italic, strikethrough and
 * code, plus `[text](url)` links, which iOS's AttributedString(markdown:)
 * makes tappable in an article. An inline image shows as its alt text.
 */
internal fun articleInlineText(text: String, linkColor: Color): AnnotatedString = buildAnnotatedString {
    var last = 0
    for (m in inlineLinkPattern.findAll(text)) {
        appendInlineMarkdown(text.substring(last, m.range.first))
        val (bang, label, url) = m.destructured
        if (bang.isEmpty() && (url.startsWith("http://") || url.startsWith("https://"))) {
            withLink(LinkAnnotation.Url(url, TextLinkStyles(SpanStyle(color = linkColor)))) { appendInlineMarkdown(label) }
        } else {
            appendInlineMarkdown(label)
        }
        last = m.range.last + 1
    }
    appendInlineMarkdown(text.substring(last))
}

/**
 * The article body, block by block (iOS MarkdownBodyView): headings 24/20/18/16,
 * purple bullets, numbers and quote bar, code in a scrolling box, tappable
 * 200dp images, and selectable text.
 *
 * In highlight mode ([onHighlight] set) every text block keeps its formatting,
 * is tinted, and a tap hands back its plain text. Otherwise a block other
 * people highlighted ([highlights], by index into [blocks]) gets a soft yellow
 * tint and a count that opens who highlighted it.
 */
@Composable
internal fun MarkdownBody(
    blocks: List<MarkdownBlock>,
    onImageTap: (String) -> Unit,
    onHighlight: ((String) -> Unit)?,
    highlights: Map<Int, List<ArticleHighlight>>,
    onShowHighlights: (List<ArticleHighlight>) -> Unit,
    modifier: Modifier = Modifier,
) {
    val content: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = modifier.fillMaxWidth()) {
            blocks.forEachIndexed { index, block ->
                MarkdownBlockView(block, onImageTap, onHighlight, highlights[index].orEmpty(), onShowHighlights)
            }
        }
    }
    // Selection would swallow the taps that pick a paragraph to highlight.
    if (onHighlight == null) SelectionContainer { content() } else content()
}

@Composable
private fun MarkdownBlockView(
    block: MarkdownBlock,
    onImageTap: (String) -> Unit,
    onHighlight: ((String) -> Unit)?,
    shown: List<ArticleHighlight>,
    onShowHighlights: (List<ArticleHighlight>) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    when (block) {
        is MarkdownBlock.Heading -> Highlightable(block.text, onHighlight, shown, onShowHighlights,
            Modifier.padding(top = if (block.level <= 2) 8.dp else 2.dp)) {
            val size = when (block.level) { 1 -> 24; 2 -> 20; 3 -> 18; else -> 16 }
            InlineText(block.text, fontSize = size, bold = true)
        }
        is MarkdownBlock.Paragraph -> Highlightable(block.text, onHighlight, shown, onShowHighlights) {
            InlineText(block.text)
        }
        is MarkdownBlock.Bullet -> Highlightable(block.text, onHighlight, shown, onShowHighlights) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("•", color = colors.primary, fontSize = 16.sp, fontWeight = FontWeight.Bold, lineHeight = 24.sp)
                InlineText(block.text)
            }
        }
        is MarkdownBlock.Ordered -> Highlightable(block.text, onHighlight, shown, onShowHighlights) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${block.index}.", color = colors.primary, fontSize = 16.sp, fontWeight = FontWeight.Bold, lineHeight = 24.sp)
                InlineText(block.text)
            }
        }
        is MarkdownBlock.Quote -> Highlightable(block.text, onHighlight, shown, onShowHighlights) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.height(IntrinsicSize.Min)) {
                Box(Modifier.width(3.dp).fillMaxHeight().background(colors.primary))
                InlineText(block.text, color = SecondaryText)
            }
        }
        is MarkdownBlock.Code -> Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(SecondaryText.copy(alpha = 0.12f))
                .horizontalScroll(rememberScrollState()),
        ) {
            Text(block.text, color = PrimaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace,
                softWrap = false, modifier = Modifier.padding(10.dp))
        }
        is MarkdownBlock.Image -> AsyncImage(
            model = block.url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxWidth()
                .height(200.dp)
                .clip(RoundedCornerShape(10.dp))
                .clickable { onImageTap(block.url) },
        )
        MarkdownBlock.Rule -> HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
    }
}

@Composable
private fun InlineText(text: String, fontSize: Int = 16, bold: Boolean = false, color: Color = PrimaryText) {
    val colors = LocalNostrVaultColors.current
    val annotated = remember(text, colors.primary) { articleInlineText(text, colors.primary) }
    Text(
        annotated,
        color = color,
        fontSize = fontSize.sp,
        lineHeight = (fontSize + 8).sp,
        fontWeight = if (bold) FontWeight.Bold else null,
    )
}

/**
 * In highlight mode, tint the block and make all of it a tap target that
 * reports its text without markdown. Otherwise a block other people
 * highlighted gets a soft yellow tint and a count under it.
 */
@Composable
private fun Highlightable(
    markdown: String,
    onHighlight: ((String) -> Unit)?,
    shown: List<ArticleHighlight>,
    onShowHighlights: (List<ArticleHighlight>) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    when {
        onHighlight != null -> Box(
            modifier = modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(colors.primary.copy(alpha = 0.08f))
                .clickable { onHighlight(ArticleEngagement.plainText(markdown)) }
                .padding(horizontal = 6.dp, vertical = 4.dp),
        ) { content() }
        shown.isNotEmpty() -> Column(
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(4.dp),
            modifier = modifier,
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(HighlightYellow.copy(alpha = 0.16f))
                    .padding(horizontal = 6.dp, vertical = 4.dp),
            ) { content() }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(HighlightYellow.copy(alpha = 0.16f))
                    .clickable(onClickLabel = if (shown.size == 1) "1 highlight" else "${shown.size} highlights") {
                        onShowHighlights(shown)
                    }
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            ) {
                Icon(Icons.Outlined.BorderColor, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(13.dp))
                Text("${shown.size}", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        else -> Box(modifier = modifier) { content() }
    }
}
