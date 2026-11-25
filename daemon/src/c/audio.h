#pragma once

int wr_audio_opens(int enabled, float volume);
int au_start(const char *path, double from, float volume, double fade);
void au_fade(float target, double seconds);
void au_pause(int paused);
int au_running(void);
void au_stop(void);
long au_delivered(void);
