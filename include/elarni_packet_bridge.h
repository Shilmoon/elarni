#ifndef ELARNI_PACKET_BRIDGE_H
#define ELARNI_PACKET_BRIDGE_H

#pragma once

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define ELARNI_PACKET_ABI_VERSION 7

typedef enum ElarniPacketStatus {
  ELARNI_PACKET_STATUS_OK = 0,
  ELARNI_PACKET_STATUS_INVALID_ARGUMENT = 1,
  ELARNI_PACKET_STATUS_MALFORMED_PACKET = 2,
  ELARNI_PACKET_STATUS_QUEUE_OVERFLOW = 3,
  ELARNI_PACKET_STATUS_BUFFER_TOO_SMALL = 4,
  ELARNI_PACKET_STATUS_EMPTY = 5,
  ELARNI_PACKET_STATUS_STOPPED = 6,
  ELARNI_PACKET_STATUS_STOP_TIMEOUT = 7,
  ELARNI_PACKET_STATUS_INTERNAL_ERROR = 255,
} ElarniPacketStatus;

typedef enum ElarniPacketState {
  ELARNI_PACKET_STATE_STARTING = 0,
  ELARNI_PACKET_STATE_RUNNING = 1,
  ELARNI_PACKET_STATE_STOPPING = 2,
  ELARNI_PACKET_STATE_STOPPED = 3,
  ELARNI_PACKET_STATE_FAILED = 4,
} ElarniPacketState;

typedef struct ElarniPacketBridge ElarniPacketBridge;

typedef struct ElarniPacketCounters {
  uint64_t packets_in;
  uint64_t bytes_in;
  uint64_t packets_out;
  uint64_t bytes_out;
  uint64_t malformed;
  uint64_t overflows;
  uint64_t active_tcp_sessions;
  uint64_t active_udp_sessions;
  uint64_t dropped_tcp_sessions;
  uint64_t dropped_udp_sessions;
} ElarniPacketCounters;

uint32_t elarni_packet_abi_version(void);

struct ElarniPacketBridge *elarni_packet_bridge_new(uint16_t socks_port,
                                                    uint16_t mtu,
                                                    size_t tcp_max_sessions,
                                                    size_t udp_max_sessions,
                                                    size_t queue_packets,
                                                    size_t max_packet_bytes);

/**
 * `elarni_packet_bridge_new` whose UDP sessions end after `udp_timeout_seconds` (1-600) without
 * traffic instead of 60 s, so checks need not wait out the production timeout.
 */
struct ElarniPacketBridge *elarni_packet_bridge_new_with_udp_timeout(uint16_t socks_port,
                                                                     uint16_t mtu,
                                                                     size_t tcp_max_sessions,
                                                                     size_t udp_max_sessions,
                                                                     size_t queue_packets,
                                                                     size_t max_packet_bytes,
                                                                     uint64_t udp_timeout_seconds);

/**
 * # Safety
 * Credential pointers must reference their stated readable lengths for this call.
 */
struct ElarniPacketBridge *elarni_packet_bridge_new_authenticated(uint16_t socks_port,
                                                                  uint16_t mtu,
                                                                  size_t tcp_max_sessions,
                                                                  size_t udp_max_sessions,
                                                                  size_t queue_packets,
                                                                  size_t max_packet_bytes,
                                                                  const uint8_t *username,
                                                                  size_t username_len,
                                                                  const uint8_t *password,
                                                                  size_t password_len);

/**
 * # Safety
 * `bridge` must be null or a live pointer returned by `elarni_packet_bridge_new`.
 */
void elarni_packet_bridge_free(struct ElarniPacketBridge *bridge);

/**
 * # Safety
 * `bridge` must be live. `packet` must point to `packet_len` readable bytes.
 */
enum ElarniPacketStatus elarni_packet_bridge_submit(struct ElarniPacketBridge *bridge,
                                                    const uint8_t *packet,
                                                    size_t packet_len);

/**
 * # Safety
 * All pointers must be live and writable for their declared size. `output_capacity` describes
 * the writable bytes at `output`. On `BufferTooSmall`, `written` receives required size.
 */
enum ElarniPacketStatus elarni_packet_bridge_receive(struct ElarniPacketBridge *bridge,
                                                     uint8_t *output,
                                                     size_t output_capacity,
                                                     size_t *written);

/**
 * Sleeps until `receive` has a packet (`Ok`), the bridge stops running (`Stopped`) or
 * `timeout_ms` passes (`Empty`), so an idle caller needs no polling loop.
 *
 * # Safety
 * `bridge` must stay live until this call returns: free it only after waiting threads return.
 */
enum ElarniPacketStatus elarni_packet_bridge_wait(const struct ElarniPacketBridge *bridge,
                                                  uint32_t timeout_ms);

/**
 * # Safety
 * `bridge` and `counters` must be live pointers.
 */
enum ElarniPacketStatus elarni_packet_bridge_counters(const struct ElarniPacketBridge *bridge,
                                                      struct ElarniPacketCounters *counters);

/**
 * # Safety
 * `bridge` must be a live pointer.
 */
enum ElarniPacketState elarni_packet_bridge_state(const struct ElarniPacketBridge *bridge);

/**
 * # Safety
 * `bridge` must be a live pointer. This call is idempotent.
 */
enum ElarniPacketStatus elarni_packet_bridge_stop(struct ElarniPacketBridge *bridge);

#endif  /* ELARNI_PACKET_BRIDGE_H */
