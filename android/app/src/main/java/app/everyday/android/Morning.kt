package app.everyday.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import java.util.concurrent.TimeUnit

/** Every 30 minutes WorkManager asks the core whether the morning briefing is due; when it is, syncs, writes it and posts one quiet notification. */
class MorningWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        Core.open(applicationContext)
        if (Core.run("morningDue") != true) return Result.success()
        runCatching { Core.run("syncMail") }; runCatching { Core.run("newsRefresh") }
        val text = runCatching { Core.run("briefing") as String }.getOrNull() ?: return Result.retry()
        notify(applicationContext, Core.run("preview", json("text" to Format.plain(text))) as String)
        return Result.success()
    }

    private fun notify(ctx: Context, body: String) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel("briefing", "Morning briefing", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(ctx, 0, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(ctx, "briefing").setSmallIcon(R.drawable.ic_launcher).setContentTitle("Your briefing is ready").setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body)).setColor(0xFFD97856.toInt()).setContentIntent(open).setAutoCancel(true).build()
        runCatching { nm.notify(1, n) }
    }
}

object Morning {
    fun schedule(ctx: Context) {
        val req = PeriodicWorkRequestBuilder<MorningWorker>(30, TimeUnit.MINUTES).setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED)).build()
        WorkManager.getInstance(ctx).enqueueUniquePeriodicWork("morning", ExistingPeriodicWorkPolicy.KEEP, req)
    }
}
