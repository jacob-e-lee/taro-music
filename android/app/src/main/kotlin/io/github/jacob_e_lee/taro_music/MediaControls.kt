package io.github.jacob_e_lee.taro_music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject
import java.net.URL

/**
 * Android's side of playback: a [MediaSession] (lock screen, quick settings, headset and
 * Bluetooth buttons) and the media notification [KeepAliveService] runs in the foreground with.
 *
 * The WebView has no Media Session API, so the page reports what's playing itself
 * (`TaroMedia` in inject.js → [update]), and commands go back through [runInPage].
 */
object MediaControls {
    const val NOTIFICATION_ID = 1
    private const val CHANNEL = "playback"
    const val ACTION = "io.github.jacob_e_lee.taro_music.MEDIA"

    /** Runs a command in the page (`__taroMedia(command, arg)`); set by [YtmWebView]. */
    var runInPage: ((command: String, arg: Long) -> Unit)? = null

    private var session: MediaSession? = null
    private var playing = false
    private var title = "Taro Music"
    private var artist = ""
    private var artUrl = ""
    private var art: Bitmap? = null
    private val main = Handler(Looper.getMainLooper())

    private fun session(context: Context): MediaSession = session ?: MediaSession(context.applicationContext, "TaroMusic").apply {
        setCallback(object : MediaSession.Callback() {
            override fun onPlay() = command("play")
            override fun onPause() = command("pause")
            override fun onSkipToNext() = command("next")
            override fun onSkipToPrevious() = command("prev")
            override fun onSeekTo(pos: Long) = command("seek", pos)
        })
        isActive = true
        session = this
    }

    /** From the notification's buttons (via [KeepAliveService]) and the session callback. */
    fun command(name: String, arg: Long = 0) {
        runInPage?.invoke(name, arg)
    }

    /** The page's state, as JSON: title, artist, art, playing, position and duration (ms). */
    fun update(context: Context, json: String) {
        val s = runCatching { JSONObject(json) }.getOrNull() ?: return
        playing = s.optBoolean("playing")
        title = s.optString("title").ifEmpty { "Taro Music" }
        artist = s.optString("artist")
        val session = session(context)
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackState.ACTION_SEEK_TO,
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    s.optLong("position"), if (playing) 1f else 0f, SystemClock.elapsedRealtime(),
                )
                .build(),
        )
        val url = s.optString("art")
        if (url != artUrl) {
            artUrl = url
            art = null
            if (url.isNotEmpty()) loadArt(context, url)
        }
        setMetadata(session, s.optLong("duration"))
        show(context)
    }

    private fun setMetadata(session: MediaSession, duration: Long) {
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, duration)
                .putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art)
                .build(),
        )
    }

    // Off the main thread; a late result for an earlier track is dropped.
    private fun loadArt(context: Context, url: String) = Thread {
        val bitmap = runCatching { URL(url).openStream().use { BitmapFactory.decodeStream(it) } }.getOrNull()
        main.post {
            if (url != artUrl || bitmap == null) return@post
            art = bitmap
            val session = session(context)
            setMetadata(session, session.controller.metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0)
            show(context)
        }
    }.start()

    private fun show(context: Context) =
        context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(context))

    fun notification(context: Context): Notification {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW))
        fun button(icon: Int, label: String, command: String, code: Int) = Notification.Action.Builder(
            icon, label,
            PendingIntent.getService(
                context, code,
                Intent(context, KeepAliveService::class.java).setAction(ACTION).putExtra("command", command),
                PendingIntent.FLAG_IMMUTABLE,
            ),
        ).build()
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(artist)
            .setLargeIcon(art)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(button(android.R.drawable.ic_media_previous, "Previous", "prev", 1))
            .addAction(
                if (playing) button(android.R.drawable.ic_media_pause, "Pause", "pause", 2)
                else button(android.R.drawable.ic_media_play, "Play", "play", 3),
            )
            .addAction(button(android.R.drawable.ic_media_next, "Next", "next", 4))
            .setStyle(Notification.MediaStyle().setMediaSession(session(context).sessionToken).setShowActionsInCompactView(0, 1, 2))
            .build()
    }
}
