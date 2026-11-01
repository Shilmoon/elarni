#ifndef ELARNI_FFI_H
#define ELARNI_FFI_H

#pragma once

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define ELARNI_ABI_VERSION 1

#define ELARNI_SCHEMA_MIN 1

#define ELARNI_SCHEMA_MAX 1

#define MAX_ROUTING_INPUT_BYTES ((4 * 1024) * 1024)

#define MAX_ROUTING_TARGETS 100000

#define MAX_DNS_HOSTS 4096

typedef struct ElarniHandle ElarniHandle;

typedef uint32_t ElarniStatus;

typedef struct ElarniBuffer {
  uint8_t *data;
  size_t len;
  size_t capacity;
} ElarniBuffer;

#define ELARNI_STATUS_OK 0

#define ELARNI_STATUS_INVALID_ARGUMENT 1

#define ELARNI_STATUS_UNSUPPORTED_VERSION 2

#define ELARNI_STATUS_REQUEST_TOO_LARGE 3

#define ELARNI_STATUS_RESPONSE_TOO_LARGE 4

#define ELARNI_STATUS_CANCELLED 5

#define ELARNI_STATUS_PARSE_ERROR 6

#define ELARNI_STATUS_COMPILE_ERROR 7

#define ELARNI_STATUS_PANIC 255

uint32_t elarni_abi_version(void);

uint32_t elarni_schema_min(void);

uint32_t elarni_schema_max(void);

struct ElarniHandle *elarni_handle_new(void);

/**
 * # Safety
 * `handle` must be null or a pointer returned by `elarni_handle_new` that has not been freed.
 */
void elarni_handle_free(struct ElarniHandle *handle);

/**
 * # Safety
 * `handle` must point to a live Elarni handle.
 */
ElarniStatus elarni_cancel(struct ElarniHandle *handle);

/**
 * # Safety
 * `buffer` must be null or point to a buffer returned by this library and not yet freed.
 */
void elarni_buffer_free(struct ElarniBuffer buffer);

/**
 * # Safety
 * `handle` and `output` must be live writable pointers. `request` must point to `request_len`
 * readable bytes for this call. Input and output memory must not overlap.
 */
ElarniStatus elarni_request(struct ElarniHandle *handle,
                            const uint8_t *request,
                            size_t request_len,
                            struct ElarniBuffer *output);

#endif  /* ELARNI_FFI_H */
