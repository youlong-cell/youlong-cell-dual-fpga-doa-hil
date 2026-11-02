#ifndef DOA_RESULT_PUBLISH_H
#define DOA_RESULT_PUBLISH_H

#include "fine_production_ps.h"
#include "xtime_l.h"

/* Display-only state: never written back to PL status or result words. */
typedef enum {
    DOA_VIEW_NOT_READY = 0,
    DOA_VIEW_VALID,
    DOA_VIEW_INVALID,
    DOA_VIEW_FAULT
} doa_view_state_t;

typedef enum {
    DOA_INVALIDATION_NONE = 0,
    DOA_INVALIDATION_STOP,
    DOA_INVALIDATION_SESSION_INSTALL,
    DOA_INVALIDATION_RESET_RECOVERY,
    DOA_INVALIDATION_SESSION_CHANGE,
    DOA_INVALIDATION_MAINTENANCE_HOLD,
    DOA_INVALIDATION_PROTOCOL_FATAL,
    DOA_INVALIDATION_MANUAL
} doa_invalidation_reason_t;

/* ABI1 has a raw packet type, not per-field decoded C types. Reuse it verbatim
 * and its PL_*_BIT/WIDTH accessors: no guessed Q types or float-only copies.
 * Includes all f_hat, phase, theta, timestamps, validity/status and flags. */
typedef struct {
    uint8_t available;
    uint64_t publish_seq;     /* PS-local publication generation; not PL seq. */
    XTime received_time;      /* after granted RESULT_ACK; NOT Fine latency */
    result_identity_t identity;
    pl_fine_packet_t packet;
    doa_view_state_t view_state;
    doa_invalidation_reason_t invalidation_reason;
} doa_published_result_t;

/* Debug history is explicitly NOT a source for the current DOA view. Counters
 * survive invalidation/STOP/session/recovery within this software boot only. */
typedef struct {
    uint64_t published_count, valid_count, invalid_count;
    uint64_t invalidation_count, protocol_fatal_count;
    doa_invalidation_reason_t last_invalidation_reason;
    int last_service_error, last_driver_error;
    uint8_t history_available;
    doa_published_result_t last_published;
} doa_result_debug_t;

enum {
    DOA_RESULT_NONE = 0,
    DOA_RESULT_PUBLISHED = 1,
    DOA_RESULT_POLL_ERROR = -1,
    DOA_RESULT_PACKET_ERROR = -2,
    DOA_RESULT_IDENTITY_ERROR = -3,
    DOA_RESULT_DUPLICATE = -4,
    DOA_RESULT_ACK_ERROR = -5,
    DOA_RESULT_FENCED = -6,
    DOA_RESULT_LIFECYCLE_ERROR = -7,
    DOA_RESULT_SEQUENCE_EXHAUSTED = -8,
    DOA_RESULT_NOT_READY = -9,
    DOA_RESULT_NO_GRANTED_ACK = -10
};

/* Foreground-only, same A53 as pl_fine_*; no ISR/other-core callers.
 * Service owns polling + ACK. Main must not poll/ACK the same result again. */
int doa_result_service(void);
/* No arbitrary packet input: may consume only the service's private ACK receipt. */
int doa_result_publish(void);
/* Local visibility invalidation only; not STOP, RELEASE or RESULT_ACK. */
void doa_result_invalidate(doa_invalidation_reason_t reason);
/* Always copies the complete object, even if unavailable; never exposes a pointer. */
int doa_result_snapshot(doa_published_result_t *out);
int doa_view_snapshot(doa_published_result_t *out);
/* Separate history/statistics copy. Never use last_published for rendering. */
int doa_result_debug_snapshot(doa_result_debug_t *out);
/* Return 1 with RESULT AGE/AGE in ms; 0 if unavailable, -1 if time regressed.
 * The age belongs to this COPY, even if another result has since been published. */
int doa_result_age_ms(const doa_published_result_t *view, uint64_t *age_ms);
int doa_result_last_driver_error(void);
/* Statistics only: deliberately no debug-history packet/pointer for UI. */
typedef struct { uint64_t published_count, invalid_count; } doa_result_counts_t;
int doa_result_counts_snapshot(doa_result_counts_t *);

#endif
