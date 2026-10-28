package com.pritesh.nucflix;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;

/**
 * Synthesizes the iconic two-hit cinematic "ta-dum" intro sound in memory (ported 1:1 from
 * iOS RootView.swift TudumSoundPlayer). No bundled audio file required.
 */
final class TudumSound {
    private TudumSound() {}

    static void play() {
        new Thread(() -> {
            try {
                final int sampleRate = 44100;
                final double duration = 2.2;
                final int count = (int) (sampleRate * duration);
                float[] samples = new float[count];

                addHit(samples, sampleRate, count, 0.45, 72.0, 0.16, 0.75f); // "ta"
                addHit(samples, sampleRate, count, 0.71, 52.0, 0.55, 1.00f); // "dum"

                // Soft shimmering pad swell under the spectrum zoom
                for (int i = 0; i < count; i++) {
                    double t = (double) i / sampleRate;
                    if (t <= 0.75) continue;
                    double env = Math.sin(Math.min((t - 0.75) / 1.2, 1.0) * Math.PI) * 0.08;
                    double pad = Math.sin(2 * Math.PI * 220.0 * t)
                            + Math.sin(2 * Math.PI * 277.18 * t)
                            + Math.sin(2 * Math.PI * 329.63 * t);
                    samples[i] += (float) (env * pad / 3.0);
                }

                float peak = 0f;
                for (float s : samples) {
                    float a = Math.abs(s);
                    if (a > peak) peak = a;
                }
                float scale = peak > 0 ? 0.90f / peak : 1f;
                short[] pcm = new short[count];
                for (int i = 0; i < count; i++) {
                    float clamped = Math.max(-1f, Math.min(1f, samples[i] * scale));
                    pcm[i] = (short) (clamped * Short.MAX_VALUE);
                }

                AudioTrack track = new AudioTrack.Builder()
                        .setAudioAttributes(new AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build())
                        .setAudioFormat(new AudioFormat.Builder()
                                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .setSampleRate(sampleRate)
                                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                                .build())
                        .setBufferSizeInBytes(pcm.length * 2)
                        .setTransferMode(AudioTrack.MODE_STATIC)
                        .build();

                track.write(pcm, 0, pcm.length);
                track.play();
                Thread.sleep((long) (duration * 1000) + 250);
                track.stop();
                track.release();
            } catch (Throwable ignored) {
            }
        }, "NucFlix-Tudum").start();
    }

    private static void addHit(float[] samples, int sampleRate, int count,
                               double start, double baseFreq, double decay, float gain) {
        int startIndex = (int) (start * sampleRate);
        double phase = 0.0;
        int noiseSeed = 12345;
        int len = (int) (decay * 6 * sampleRate);
        for (int i = 0; i < len; i++) {
            int idx = startIndex + i;
            if (idx >= count) break;
            double t = (double) i / sampleRate;
            double freq = baseFreq * (1.0 + 1.6 * Math.exp(-t * 28.0));
            phase += 2.0 * Math.PI * freq / sampleRate;
            double env = Math.exp(-t / decay) * Math.min(1.0, t * 400.0);
            noiseSeed = noiseSeed * 1664525 + 1013904223;
            double u = ((noiseSeed & 0xFFFFFFFFL) / (double) 0xFFFFFFFFL) * 2.0 - 1.0;
            double noise = u * Math.exp(-t * 90.0);
            double body = Math.sin(phase) + 0.35 * Math.sin(phase * 2.01) + 0.15 * Math.sin(phase * 3.03);
            samples[idx] += gain * (float) (env * body * 0.6 + noise * 0.12);
        }
    }
}
