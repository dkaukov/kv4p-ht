package com.vagell.kv4pht.radio;

import com.ustadmobile.codec2.Codec2;

public final class FreeDvUtils {
  private FreeDvUtils() {}

  // ---- tiny short ring ----
  static final class ShortRing {
    private final short[] buf; private int r=0,w=0,size=0;
    ShortRing(int cap) { buf = new short[cap]; }
    int available() { return size; }
    void write(short[] src, int len) {
      int cap = buf.length;
      for (int i=0;i<len && size<cap;i++){ buf[w]=src[i]; w=(w+1)%cap; size++; }
    }
    int read(short[] dst, int len) {
      int n = Math.min(len,size);
      for (int i=0;i<n;i++){ dst[i]=buf[r]; r=(r+1)%buf.length; }
      size -= n; return n;
    }
  }

  // ===================== TX =====================
  /** FreeDV TX: speech@8k float[len==speechFrameSize] -> FreeDV -> Opus packet. */
  public static final class Tx implements AutoCloseable {
    private final long h;
    private final int speechInPerFrame;
    private final int modemOutMax;
    private final int opusFrameSamples;
    private final OpusUtils.OpusEncoderWrapper opus;

    // Internals
    private final short[] speechPcm;
    private final short[] modemPcm;
    private final ShortRing modemRb;
    private final short[] oneOpusShort;
    private final float[] opusFloat;
    private final byte[] pktBuf;
    private int lastPktLen = 0;

    public Tx(int freedvMode, int opusFrameSamples, OpusUtils.OpusEncoderWrapper opusEncoder, int mtuBytes) {
      this.h = Codec2.freedvCreate(freedvMode, false, 0f, 1);
      if (h == 0) throw new IllegalStateException("freedvCreate(TX) failed");

      this.speechInPerFrame = Codec2.freedvGetNSpeechSamples(h);
      this.modemOutMax      = Codec2.freedvGetMaxModemSamples(h);
      this.opusFrameSamples = opusFrameSamples;
      this.opus             = opusEncoder;

      this.speechPcm   = new short[speechInPerFrame];
      this.modemPcm    = new short[modemOutMax];
      this.modemRb     = new ShortRing(opusFrameSamples * 8);
      this.oneOpusShort= new short[opusFrameSamples];
      this.opusFloat   = new float[opusFrameSamples];
      this.pktBuf      = new byte[mtuBytes];
    }

    /** Feed one speech frame (len must equal speechFrameSize). Returns Opus packet length (0 if none ready). */
    public int pushSpeechFrame(float[] speech8k, int len) {
      if (len != speechInPerFrame) {
        throw new IllegalArgumentException("len="+len+" != speechFrameSize="+speechInPerFrame);
      }

      // float -> pcm16
      for (int i=0;i<speechInPerFrame;i++){
        float x = speech8k[i];
        if (x > 1f) x = 1f; else if (x < -1f) x = -1f;
        speechPcm[i] = (short)Math.round(x * 32767f);
      }

      int nModem = (int)Codec2.freedvTx(h, modemPcm, speechPcm);
      if (nModem > 0) modemRb.write(modemPcm, nModem);

      if (modemRb.available() >= opusFrameSamples) {
        modemRb.read(oneOpusShort, opusFrameSamples);
        for (int i=0;i<opusFrameSamples;i++) opusFloat[i] = oneOpusShort[i] / 32768f;
        lastPktLen = opus.encode(opusFloat, pktBuf);
        return Math.max(0, lastPktLen);
      }
      lastPktLen = 0;
      return 0;
    }

    public byte[] packetBuffer() { return pktBuf; }
    public int lastPacketLength() { return lastPktLen; }
    public int speechFrameSize() { return speechInPerFrame; }
    public int opusFrameSize()   { return opusFrameSamples; }

    @Override public void close() { Codec2.freedvDestroy(h); }
  }

  // ===================== RX =====================
  /** FreeDV RX: Opus(8k) packet -> FreeDV -> speech@8k FLOAT (internal buffer). */
  public static final class Rx implements AutoCloseable {
    private final long h;
    private final int nin;
    private final int speechMaxPcm16;
    private final int opusFrameSamples;
    private final OpusUtils.OpusDecoderWrapper opus;

    // Internals
    private final float[] opusFloat;   // Opus-decoded modem@8k (float)
    private final short[] modemTmp;    // float->pcm16 modem staging
    private final ShortRing modemRb;   // accumulates modem to 'nin'
    private final short[] modemIn;     // size = nin
    private final short[] speechPcm16; // FreeDV output
    private final float[] speechFloat; // converted to float for AudioTrack
    private int lastSpeechLen = 0;

    public Rx(int freedvMode, float squelchSnr,
      int opusFrameSamples, OpusUtils.OpusDecoderWrapper opusDecoder) {
      this.h = Codec2.freedvCreate(freedvMode, true, squelchSnr, 1);
      if (h == 0) throw new IllegalStateException("freedvCreate(RX) failed");

      this.nin               = Codec2.freedvNin(h);
      this.speechMaxPcm16    = Codec2.freedvGetMaxSpeechSamples(h);
      this.opusFrameSamples  = opusFrameSamples;
      this.opus              = opusDecoder;

      this.opusFloat  = new float[opusFrameSamples];
      this.modemTmp   = new short[opusFrameSamples];
      this.modemRb    = new ShortRing(nin * 8);
      this.modemIn    = new short[nin];
      this.speechPcm16= new short[speechMaxPcm16];
      this.speechFloat= new float[speechMaxPcm16];
    }

    /**
     * Push one Opus packet (8k). Returns #float samples written into speechFloatBuffer().
     * Buffer contents are valid until the next call.
     */
    public int pushOpusPacket(byte[] opusData, int len) {
      int got = opus.decode(opusData, len, opusFloat);
      if (got > 0) {
        // float modem -> pcm16 modem
        for (int i=0;i<got;i++){
          float x = opusFloat[i];
          if (x > 1f) x = 1f; else if (x < -1f) x = -1f;
          modemTmp[i] = (short)Math.round(x * 32767f);
        }
        modemRb.write(modemTmp, got);
      }

      lastSpeechLen = 0;
      while (modemRb.available() >= nin) {
        modemRb.read(modemIn, nin);
        int nSpeech = (int)Codec2.freedvRx(h, speechPcm16, modemIn);
        if (nSpeech > 0) {
          // convert PCM16 -> float for AudioTrack(ENCODING_PCM_FLOAT)
          for (int i=0;i<nSpeech;i++) {
            speechFloat[i] = speechPcm16[i] / 32768f;
          }
          lastSpeechLen = nSpeech; // keep only last chunk; typical callers write per call
        }
      }
      return lastSpeechLen;
    }
    /** Float buffer (8k, mono) containing the last decoded speech chunk. */
    public float[] speechFloatBuffer() { return speechFloat; }
    /** If you ever need short PCM16 instead of float. */
    public short[] speechPcm16Buffer() { return speechPcm16; }
    public int lastSpeechLength() { return lastSpeechLen; }
    public int requiredModemIn()  { return nin; }
    public int maxSpeechOut()     { return speechMaxPcm16; }
    @Override public void close() { Codec2.freedvDestroy(h); }
  }
}
