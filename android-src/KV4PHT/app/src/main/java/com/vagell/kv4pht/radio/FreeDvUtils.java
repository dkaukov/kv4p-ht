package com.vagell.kv4pht.radio;

import java.nio.FloatBuffer;
import java.nio.ShortBuffer;
import java.util.function.IntConsumer;

import com.ustadmobile.codec2.Codec2;
import com.vagell.kv4pht.radio.OpusUtils.OpusDecoderWrapper;
import com.vagell.kv4pht.radio.OpusUtils.OpusEncoderWrapper;

public final class FreeDvUtils {

    private FreeDvUtils() {
    }

    // ---- tiny short ring ----
    static final class ShortRing {

        private final short[] buf;
        private int r = 0, w = 0, size = 0;

        ShortRing(int cap) {
            buf = new short[cap];
        }

        int available() {
            return size;
        }

        void write(short[] src, int len) {
            int cap = buf.length;
            for (int i = 0; i < len && size < cap; i++) {
                buf[w] = src[i];
                w = (w + 1) % cap;
                size++;
            }
        }

        int read(short[] dst, int len) {
            int n = Math.min(len, size);
            for (int i = 0; i < n; i++) {
                dst[i] = buf[r];
                r = (r + 1) % buf.length;
            }
            size -= n;
            return n;
        }
    }

    // ===================== TX =====================

    /**
     * FreeDV TX: speech@8k float[len==speechFrameSize] -> FreeDV -> Opus packet.
     */
    public static final class Tx implements AutoCloseable {

        private final long _freedv;
        private final short[] _modemTxBuffer;
        private final short[] pcmBuffer;
        private final ShortRing _modemTxRingBuffer;
        private final int opusFrameSamples;
        private final OpusEncoderWrapper opusEncoder;
        private final byte[] pktBuf;
        private final short[] opusFrame;

        public Tx(int freedvMode, int opusFrameSamples, OpusEncoderWrapper opusEncoder, int mtuBytes) {
            this._freedv = Codec2.freedvCreate(freedvMode, false, 0f, 1);   // unset for speech
            this._modemTxBuffer = new short[Codec2.freedvGetNomModemSamples(_freedv)];
            this.pcmBuffer = new short[opusFrameSamples];
            this._modemTxRingBuffer = new ShortRing(opusFrameSamples * 10);
            this.opusFrameSamples = opusFrameSamples;
            this.opusEncoder = opusEncoder;
            this.pktBuf = new byte[mtuBytes];
            this.opusFrame = new short[this.opusFrameSamples];
        }

        /**
         * Feed one speech frame (len must equal speechFrameSize). Returns Opus packet length (0 if none ready).
         */
        public void pushSpeechFrame(float[] speech8k, int len, IntConsumer onFrameSamples) {
            for (int i = 0; i < len; i++) {
                pcmBuffer[i] = (short) (speech8k[i] * 32768.0f);
            }
            int encoded = (int) Codec2.freedvTx(_freedv, _modemTxBuffer, pcmBuffer);
            _modemTxRingBuffer.write(_modemTxBuffer, encoded);
            while (_modemTxRingBuffer.available()  >= opusFrameSamples) {
                _modemTxRingBuffer.read(opusFrame, opusFrameSamples);
                onFrameSamples.accept(opusEncoder.encode(opusFrame, pktBuf));
            }
        }

        @Override
        public void close() {
            Codec2.freedvDestroy(_freedv);
        }

        public byte[] packetBuffer() {
            return pktBuf;
        }
    }

    // ===================== RX =====================

    /**
     * FreeDV RX: Opus(8k) packet -> FreeDV -> speech@8k FLOAT (internal buffer).
     */
    public static final class Rx implements AutoCloseable {

        private final long freeDv;
        private final short[] speechRxBuffer;
        ShortBuffer speechSamples;
        FloatBuffer pcmFloatBuffer;
        private final OpusDecoderWrapper opus;
        private final short[] modemTmp;

        public Rx(int freedvMode, float squelchSnr, int opusFrameSamples, OpusDecoderWrapper opusDecoder) {
            freeDv = Codec2.freedvCreate(freedvMode, true, squelchSnr, 0);   // unset for speech
            if (freeDv == 0) {
                throw new IllegalStateException("freedvCreate(RX) failed");
            }
            speechRxBuffer = new short[Codec2.freedvGetMaxSpeechSamples(freeDv)];
            speechSamples = ShortBuffer.allocate(1024 * 10);
            pcmFloatBuffer = FloatBuffer.allocate(1024 * 10);
            modemTmp   = new short[opusFrameSamples];
            opus = opusDecoder;
        }

        /**
         * Push one Opus packet (8k). Returns #float samples written into speechFloatBuffer(). Buffer contents are valid
         * until the next call.
         */
        public int pushOpusPacket(byte[] opusData, int len) {
            pcmFloatBuffer.clear();
            int got = opus.decode(opusData, len, modemTmp);
            if (got > 0) {
                speechSamples.put(modemTmp, 0, got);
            }
            int nin = Codec2.freedvNin(freeDv);
            while (speechSamples.position() >= nin) {
                short[] samplesSpeech = new short[nin];
                speechSamples.flip();
                speechSamples.get(samplesSpeech);
                speechSamples.compact();
                int cntRead = (int)Codec2.freedvRx(freeDv, speechRxBuffer, samplesSpeech);
                if (cntRead > 0) {
                    for (int i = 0; i < cntRead; i++) {
                        float x = speechRxBuffer[i] / 32768f;
                        pcmFloatBuffer.put(x);
                    }
                }
                nin = Codec2.freedvNin(freeDv);
            }
            return pcmFloatBuffer.position();
        }

        @Override
        public void close() {
            Codec2.freedvDestroy(freeDv);
        }

        public float[] speechFloatBuffer() {
            pcmFloatBuffer.flip();
            return pcmFloatBuffer.array();
        }
    }
}
