package com.pritesh.nucflix.phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.pritesh.nucflix.phone.data.DownloadItem
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch

/** Runs the download queue in the foreground (Android stops background network work otherwise). */
class DownloadService : Service() {
    private val scope = MainScope()
    private var job: Job? = null
    private val app get() = application as NucFlixApp

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW))
        }
        ServiceCompat.startForeground(this, NOTIFICATION, notification(null),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0)
        if (job?.isActive != true) {
            job = scope.launch {
                app.downloads.run { item -> nm.notify(NOTIFICATION, notification(item)) }
                ServiceCompat.stopForeground(this@DownloadService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_STICKY
    }

    private fun notification(item: DownloadItem?): Notification {
        val open = PendingIntent.getActivity(this, 0, packageManager.getLaunchIntentForPackage(packageName), PendingIntent.FLAG_IMMUTABLE)
        val b = NotificationCompat.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setSilent(true)
        val left = app.downloads.items.count { it.state != DownloadItem.State.DONE && it.state != DownloadItem.State.FAILED && it.state != DownloadItem.State.PAUSED }
        when (item?.state) {
            DownloadItem.State.WAITING_FOR_LINE -> b.setContentTitle("Downloads paused")
                .setContentText("${app.downloads.watching.joinToString().ifEmpty { "Someone" }} is watching on this line")
            DownloadItem.State.DOWNLOADING -> b.setContentTitle("Downloading ${item.title}").setContentText(item.subtitle ?: "$left in the queue")
                .setProgress(100, (item.fraction * 100).toInt(), item.total <= 0)
            else -> b.setContentTitle("NucFlix downloads").setContentText(if (left > 0) "$left in the queue" else "Finishing up")
        }
        return b.build()
    }

    override fun onDestroy() {
        job?.cancel()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "downloads"
        private const val NOTIFICATION = 7
    }
}
