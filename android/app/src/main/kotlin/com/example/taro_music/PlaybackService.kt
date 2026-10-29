package com.example.taro_music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo

/** Only keeps the process alive so the WebView keeps playing with the screen off. */
class PlaybackService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("playback", "Playback", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = Notification.Builder(this, "playback")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Taro Music")
            .build()
        startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        return START_STICKY
    }

    override fun onBind(intent: Intent?) = null
}
