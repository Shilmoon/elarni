#include <jni.h>
#include <stdint.h>
#include "elarni_ffi.h"

static void fail(JNIEnv *env, const char *message) {
    jclass kind = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
    if (kind) (*env)->ThrowNew(env, kind, message);
}

JNIEXPORT jbyteArray JNICALL
Java_com_elarni_NativeBindings_domain(JNIEnv *env, jobject self, jbyteArray input) {
    (void)self;
    if (!input || elarni_abi_version() != 1 || elarni_schema_min() > 1 || elarni_schema_max() < 1) {
        fail(env, "native_unavailable"); return NULL;
    }
    jsize size = (*env)->GetArrayLength(env, input);
    // Matches the domain library's own request cap (MAX_REQUEST_BYTES).
    if (size <= 0 || size > 64 * 1024 * 1024) { fail(env, "input_too_large"); return NULL; }
    ElarniHandle *handle = elarni_handle_new();
    if (!handle) { fail(env, "native_unavailable"); return NULL; }
    jbyte *bytes = (*env)->GetByteArrayElements(env, input, NULL);
    if (!bytes) { elarni_handle_free(handle); return NULL; }
    ElarniBuffer output = {0};
    ElarniStatus status = elarni_request(handle, (const uint8_t *)bytes, (size_t)size, &output);
    (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT);
    jbyteArray result = NULL;
    if (status == ELARNI_STATUS_OK && output.len <= 12 * 1024 * 1024) {
        result = (*env)->NewByteArray(env, (jsize)output.len);
        if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)output.len, (const jbyte *)output.data);
    } else {
        fail(env, status == ELARNI_STATUS_COMPILE_ERROR ? "unsupported_profile" : "invalid_input");
    }
    elarni_buffer_free(output);
    elarni_handle_free(handle);
    return result;
}
