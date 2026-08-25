#include <jni.h>
#include <cstdint>
#include "codec2.h"

extern "C" JNIEXPORT jlong JNICALL
Java_com_vagell_kv4pht_radio_Codec2_nativeCreate(JNIEnv *, jclass) {
    return reinterpret_cast<jlong>(codec2_create(CODEC2_MODE_1300));
}

extern "C" JNIEXPORT void JNICALL
Java_com_vagell_kv4pht_radio_Codec2_nativeDestroy(JNIEnv *, jclass, jlong handle) {
    codec2_destroy(reinterpret_cast<CODEC2 *>(handle));
}

extern "C" JNIEXPORT void JNICALL
Java_com_vagell_kv4pht_radio_Codec2_nativeEncode(JNIEnv *env, jclass, jlong handle,
                                                  jshortArray pcm, jbyteArray bits) {
    auto *codec = reinterpret_cast<CODEC2 *>(handle);
    jshort *pcmData = env->GetShortArrayElements(pcm, nullptr);
    jbyte *bitData = env->GetByteArrayElements(bits, nullptr);
    codec2_encode(codec, reinterpret_cast<unsigned char *>(bitData), pcmData);
    env->ReleaseByteArrayElements(bits, bitData, 0);
    env->ReleaseShortArrayElements(pcm, pcmData, JNI_ABORT);
}

extern "C" JNIEXPORT void JNICALL
Java_com_vagell_kv4pht_radio_Codec2_nativeDecode(JNIEnv *env, jclass, jlong handle,
                                                  jbyteArray bits, jshortArray pcm) {
    auto *codec = reinterpret_cast<CODEC2 *>(handle);
    jbyte *bitData = env->GetByteArrayElements(bits, nullptr);
    jshort *pcmData = env->GetShortArrayElements(pcm, nullptr);
    codec2_decode(codec, pcmData, reinterpret_cast<unsigned char *>(bitData));
    env->ReleaseShortArrayElements(pcm, pcmData, 0);
    env->ReleaseByteArrayElements(bits, bitData, JNI_ABORT);
}
