package io.github.jacob_e_lee.taro_music

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo

/**
 * Keeps the process alive so the WebView keeps playing with the screen off. Its foreground
 * notification is the media notification; that notification's buttons come back here.
 */
class KeepAliveService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == MediaControls.ACTION) {
            MediaControls.command(intent.getStringExtra("command") ?: return START_STICKY)
            return START_STICKY
        }
        startForeground(
            MediaControls.NOTIFICATION_ID, MediaControls.notification(this),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
        )
        return START_STICKY
    }

    override fun onBind(intent: Intent?) = null
}
