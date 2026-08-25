package com.vagell.kv4pht.radio;

/** Minimal stateful JNI wrapper for the 1300 bit/s Codec2 mode used by FreeDV 2400B. */
final class Codec2 implements AutoCloseable {
    static final int PCM_SAMPLES = 320;
    static final int FRAME_BYTES = 7;

    static { System.loadLibrary("kv4p-codec2"); }

    private long handle = nativeCreate();

    Codec2() {
        if (handle == 0) throw new IllegalStateException("Codec2 1300 is unavailable");
    }

    synchronized void encode(short[] pcm, byte[] frame) {
        requireLengths(pcm, frame);
        nativeEncode(handle, pcm, frame);
    }

    synchronized void decode(byte[] frame, short[] pcm) {
        requireLengths(pcm, frame);
        nativeDecode(handle, frame, pcm);
    }

    private void requireLengths(short[] pcm, byte[] frame) {
        if (handle == 0) throw new IllegalStateException("Codec2 is closed");
        if (pcm.length < PCM_SAMPLES || frame.length < FRAME_BYTES) {
            throw new IllegalArgumentException("Codec2 requires 320 PCM samples and a 7-byte frame");
        }
    }

    @Override public synchronized void close() {
        if (handle != 0) { nativeDestroy(handle); handle = 0; }
    }

    private static native long nativeCreate();
    private static native void nativeDestroy(long handle);
    private static native void nativeEncode(long handle, short[] pcm, byte[] frame);
    private static native void nativeDecode(long handle, byte[] frame, short[] pcm);
}
