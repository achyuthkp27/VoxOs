#ifndef VoxOSNowPlaying_h
#define VoxOSNowPlaying_h

// Run inside /usr/bin/perl by now-playing.pl, never by VoxOS itself: macOS answers MediaRemote's
// queue only to processes Apple signed. Each prints one line of JSON and returns.

/// The playback queue, current track first: VOXOS_QUEUE_LENGTH items (default 10, at most 100).
void voxos_now_playing_queue(void);

/// Plays the queue item at VOXOS_QUEUE_OFFSET, named by VOXOS_CONTENT_ITEM_ID when known.
void voxos_now_playing_play_item(void);

#endif
