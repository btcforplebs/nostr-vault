package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.service.shareportal.RecipeLdParser
import com.nostrvault.service.shareportal.handlers.RecipeShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText

/**
 * Recipe: what the page's recipe data filled in, saved as a recipe draft.
 * Saving publishes nothing. Twin: RecipeReviewView.swift.
 */
@Composable
internal fun RecipeReviewContent(
    intent: ShareIntent,
    handler: RecipeShareHandler,
    busy: Boolean,
    onDismiss: () -> Unit,
    onSave: (RecipeLdParser.Recipe) -> Unit,
) {
    var recipe by remember(intent.id) { mutableStateOf<RecipeLdParser.Recipe?>(null) }
    LaunchedEffect(intent.id) { recipe = handler.load(intent) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Save as a recipe", style = MaterialTheme.typography.titleMedium)
        val r = recipe
        if (r == null) {
            CircularProgressIndicator()
            Text("Reading the recipe from the page…", color = SecondaryText)
            return@Column
        }
        Text(r.title.ifBlank { "Untitled recipe" }, style = MaterialTheme.typography.titleSmall)
        if (r.ingredients.isEmpty() && r.directions.isEmpty()) {
            Text("No recipe data on that page. The draft gets the title and a link; fill in the rest in the editor.", color = SecondaryText)
        } else {
            val counts = "${r.ingredients.lines().count { it.isNotBlank() }} ingredients · ${r.directions.lines().count { it.isNotBlank() }} steps"
            Text(counts, color = SecondaryText)
            listOf(r.prepTime.takeIf { it.isNotEmpty() }?.let { "Prep $it" }, r.cookTime.takeIf { it.isNotEmpty() }?.let { "Cook $it" },
                r.servings.takeIf { it.isNotEmpty() }?.let { "Serves $it" }).filterNotNull().takeIf { it.isNotEmpty() }
                ?.let { Text(it.joinToString(" · "), color = SecondaryText) }
        }
        Text("Saved as a draft on this device. Nothing is posted. Find it under New recipe → Drafts.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { onSave(r) }, enabled = !busy) { Text("Save draft") }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}
