package at.antcolony.manager

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home screen widget „Ameisen – fällig“: counts and the most urgent care.
 * The texts are prepared (and translated) by the app in
 * lib/features/widget/home_widget_native.dart; a tap opens the care round.
 */
class DueWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(Intent.ACTION_VIEW, Uri.parse("acm://app/round"), context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_due).apply {
                setTextViewText(R.id.widget_title, widgetData.getString("title", null) ?: "Ant Colony")
                setTextViewText(
                    R.id.widget_headline,
                    widgetData.getString("headline", null) ?: context.getString(R.string.widget_open_app),
                )
                setTextColor(
                    R.id.widget_headline,
                    context.getColor(if (widgetData.getBoolean("urgent", false)) R.color.widget_urgent else R.color.widget_ok),
                )
                val lines = widgetData.getString("lines", null).orEmpty()
                setTextViewText(R.id.widget_lines, lines)
                setViewVisibility(R.id.widget_lines, if (lines.isEmpty()) View.GONE else View.VISIBLE)
                setTextViewText(R.id.widget_footer, widgetData.getString("footer", null).orEmpty())
                setOnClickPendingIntent(R.id.widget_root, open)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
