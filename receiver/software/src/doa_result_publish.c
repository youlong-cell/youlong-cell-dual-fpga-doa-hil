#include "doa_result_publish.h"
#include <string.h>
#include "service_profile.h"

_Static_assert(PL_FINE_PACKET_WORDS == 34U, "Only production 34-word ABI1");
_Static_assert(RESULT_IDENTITY_ABI_VERSION == 1U, "Only identity ABI1");
_Static_assert(PL_FINE_USED_BITS == FINE_RESULT_PAYLOAD_BITS, "Payload ABI mismatch");
_Static_assert(COUNTS_PER_SECOND > 0 &&
               COUNTS_PER_SECOND <= UINT64_MAX / 1000U, "XTime age conversion");

static doa_published_result_t published;
static pl_fine_packet_t private_pending;
static result_identity_t private_identity;
static pl_fine_lifecycle_t observed_context;
static unsigned int context_seen, pending_complete, granted_ack, fenced;
static uint64_t acked_epoch;
static uint32_t acked_candidate;
static unsigned int acked_candidate_known;
static int last_driver_error;
static doa_result_debug_t debug_history;
static unsigned int listener_installed;
static int lifecycle_read(pl_fine_lifecycle_t *current);

static void count_event(uint64_t *value)
{
    if (*value != UINT64_MAX)
        ++*value;
}

void doa_result_invalidate(doa_invalidation_reason_t reason)
{
    /* Establish baseline context BEFORE an externally reported invalidation.
     * Otherwise the first snapshot's listener replay could erase early FAULT.
     * lifecycle_read marks installed before callback, so there is no recursion. */
    if (!listener_installed) {
        pl_fine_lifecycle_t initial;
        (void)lifecycle_read(&initial);
    }
    uint64_t serial = published.publish_seq;
    /* Stop old pending/ACK receipts from restoring visual validity. Preserve
     * the last successful packet and cumulative counters in DEBUG ONLY. */
    pending_complete = granted_ack = 0;
    fenced = 1;
    memset(&published, 0, sizeof(published));
    published.publish_seq = serial;
    published.invalidation_reason = reason;
    published.view_state = reason == DOA_INVALIDATION_PROTOCOL_FATAL ?
                           DOA_VIEW_FAULT : DOA_VIEW_NOT_READY;
    count_event(&debug_history.invalidation_count);
    if (reason == DOA_INVALIDATION_PROTOCOL_FATAL)
        count_event(&debug_history.protocol_fatal_count);
    debug_history.last_invalidation_reason = reason;
}

static int publication_failure(int error, int driver_error)
{
    last_driver_error = driver_error;
    debug_history.last_service_error = error;
    debug_history.last_driver_error = driver_error;
    /* Step 4: fail-closed protocol errors invalidate CURRENT visual state.
     * No pending data is published; last successful DEBUG history survives. */
    doa_result_invalidate(DOA_INVALIDATION_PROTOCOL_FATAL);
    return error;
}

static int same_context(const pl_fine_lifecycle_t *a, const pl_fine_lifecycle_t *b)
{
    return a->generation == b->generation && a->ready == b->ready &&
           a->session_epoch == b->session_epoch && a->config_version == b->config_version;
}

static void reconcile_context(const pl_fine_lifecycle_t *current)
{
    if (!context_seen || !same_context(current, &observed_context)) {
        doa_invalidation_reason_t reason = DOA_INVALIDATION_SESSION_CHANGE;
        if (current->event == PL_FINE_LIFECYCLE_STOP)
            reason = DOA_INVALIDATION_STOP;
        else if (current->event == PL_FINE_LIFECYCLE_INIT)
            reason = DOA_INVALIDATION_RESET_RECOVERY;
        else if (current->event == PL_FINE_LIFECYCLE_SESSION_READY)
            reason = DOA_INVALIDATION_SESSION_INSTALL;
        /* Driver listener runs immediately on STOP/init/session events. A
         * SESSION_READY event never creates a DOA result by itself. */
        doa_result_invalidate(reason);
        observed_context = *current;
        context_seen = 1;
        pending_complete = granted_ack = fenced = 0;
        last_driver_error = 0;
        memset(&private_pending, 0, sizeof(private_pending));
        memset(&private_identity, 0, sizeof(private_identity));
    }
}

static int lifecycle_read(pl_fine_lifecycle_t *current)
{
    if (!listener_installed) {
        listener_installed = 1;
        pl_fine_lifecycle_set_listener(reconcile_context);
    }
    return pl_fine_lifecycle_snapshot(current);
}

static int packet_valid(const pl_fine_packet_t *p, result_identity_t *id)
{
    uint64_t theta_valid, numeric_valid;
    if (pl_fine_packet_identity(p, id) != 0)
        return 0;
    theta_valid = pl_fine_bits(p, PL_THETA_VALID_BIT, PL_THETA_VALID_WIDTH);
    numeric_valid = pl_fine_bits(p, PL_NUMERIC_VALID_BIT, PL_NUMERIC_VALID_WIDTH);
    /* Current production engine drives these together. A mathematically
     * invalid packet (both zero) is still legitimate and must be published. */
    if (theta_valid != numeric_valid)
        return 0;
    if (theta_valid &&
        (!pl_fine_bits(p, PL_FINE_NUMERIC_VALID_BIT, PL_FINE_NUMERIC_VALID_WIDTH) ||
         !pl_fine_bits(p, PL_CALIBRATED_VALID_BIT, PL_CALIBRATED_VALID_WIDTH) ||
         pl_fine_bits(p, PL_STATUS_STAGE_BIT, PL_STATUS_STAGE_WIDTH) ||
         pl_fine_bits(p, PL_STATUS_BIT, PL_STATUS_WIDTH)))
        return 0;
    return 1;
}

int doa_result_publish(void)
{
    pl_fine_lifecycle_t current;
    doa_published_result_t next;
    if (!pending_complete || !granted_ack || fenced)
        return DOA_RESULT_NO_GRANTED_ACK;
    if (lifecycle_read(&current) != 0)
        return publication_failure(DOA_RESULT_LIFECYCLE_ERROR, -1);
    if (!same_context(&current, &observed_context) || !current.ready) {
        reconcile_context(&current);
        pending_complete = granted_ack = 0;
        return DOA_RESULT_NOT_READY;
    }
    if (published.publish_seq == UINT64_MAX)
        return publication_failure(DOA_RESULT_SEQUENCE_EXHAUSTED, 0);
    memset(&next, 0, sizeof(next));
    next.packet = private_pending;
    next.identity = private_identity;
    XTime_GetTime(&next.received_time);
    next.publish_seq = published.publish_seq + 1U;
    next.available = 1;
    next.view_state = pl_fine_bits(&next.packet, PL_THETA_VALID_BIT, PL_THETA_VALID_WIDTH) ?
                      DOA_VIEW_VALID : DOA_VIEW_INVALID;
    memcpy(&published, &next, sizeof(published));
    debug_history.last_published = next;
    debug_history.history_available = 1;
    count_event(&debug_history.published_count);
    if (next.view_state == DOA_VIEW_VALID)
        count_event(&debug_history.valid_count);
    else
        count_event(&debug_history.invalid_count);
    acked_epoch = private_identity.session_epoch;
    acked_candidate = private_identity.candidate_seq;
    acked_candidate_known = 1;
    pending_complete = granted_ack = 0;
    last_driver_error = 0;
    return DOA_RESULT_PUBLISHED;
}

static int doa_result_service_impl(void)
{
    pl_fine_lifecycle_t current;
    uint32_t runtime;
    int rc;
    if (lifecycle_read(&current) != 0)
        return publication_failure(DOA_RESULT_LIFECYCLE_ERROR, -1);
    reconcile_context(&current);
    if (!current.ready)
        return DOA_RESULT_NONE;
    if (fenced)
        return DOA_RESULT_FENCED;
    /* Confirm physical reset/STOP state even when there is no result packet.
     * Diagnostic 0 is the EXISTING 0xf101 lifecycle response, not a new ABI.
     * bits 1=session, 2=PL_FINE, 6=hold, 7=traffic_ready. */
    rc = pl_fine_status(0, &runtime);
    if (rc != 0)
        return publication_failure(DOA_RESULT_LIFECYCLE_ERROR, rc);
    if ((runtime >> 16) != UINT32_C(0xf101))
        return publication_failure(DOA_RESULT_LIFECYCLE_ERROR, 0);
    if ((runtime & UINT32_C(0xc6)) != UINT32_C(0x86)) {
        doa_result_invalidate(DOA_INVALIDATION_MAINTENANCE_HOLD);
        debug_history.last_service_error = DOA_RESULT_NOT_READY;
        debug_history.last_driver_error = last_driver_error = 0;
        return DOA_RESULT_NOT_READY;
    }
    memset(&private_pending, 0, sizeof(private_pending));
    pending_complete = granted_ack = 0;
    rc = pl_fine_poll(&private_pending);
    if (rc < 0)
        return publication_failure(DOA_RESULT_POLL_ERROR, rc);
    if (rc == 0)
        return DOA_RESULT_NONE;
    if (rc != 1 || !packet_valid(&private_pending, &private_identity))
        return publication_failure(DOA_RESULT_PACKET_ERROR, rc);
    pending_complete = 1;
    if (private_identity.session_epoch != current.session_epoch ||
        private_identity.config_version != current.config_version)
        return publication_failure(DOA_RESULT_IDENTITY_ERROR, 0);
    /* candidate_seq is session-unique and cannot wrap within the session.
     * Calibration/geometry provenance is preserved, not invented or relabelled. */
    if (acked_candidate_known && acked_epoch == private_identity.session_epoch &&
        private_identity.candidate_seq <= acked_candidate)
        return publication_failure(DOA_RESULT_DUPLICATE, 0);
    if (published.publish_seq == UINT64_MAX)
        return publication_failure(DOA_RESULT_SEQUENCE_EXHAUSTED, 0);
    rc = pl_fine_result_ack(&private_identity);
    if (rc != 0)
        return publication_failure(DOA_RESULT_ACK_ERROR, rc);
    granted_ack = 1;
    return doa_result_publish();
}

int doa_result_service(void)
{
    SP_SCOPE(p,SP_FINE_DOA,0,0);
    int rc=doa_result_service_impl();
    sp_mark(&p,pending_complete,last_driver_error,private_identity.candidate_seq);
    SP_RETURN(p,rc);
}

int doa_result_snapshot(doa_published_result_t *out)
{
    pl_fine_lifecycle_t current;
    if (!out)
        return -1;
    /* Do not require a main-loop turn between explicit STOP/reset and UI read. */
    if (lifecycle_read(&current) == 0)
        reconcile_context(&current);
    memcpy(out, &published, sizeof(*out));
    return published.available ? 1 : 0;
}

int doa_view_snapshot(doa_published_result_t *out)
{
    return doa_result_snapshot(out);
}

int doa_result_debug_snapshot(doa_result_debug_t *out)
{
    pl_fine_lifecycle_t current;
    if (!out)
        return -1;
    if (lifecycle_read(&current) == 0)
        reconcile_context(&current);
    memcpy(out, &debug_history, sizeof(*out));
    return debug_history.history_available ? 1 : 0;
}

int doa_result_age_ms(const doa_published_result_t *view, uint64_t *age_ms)
{
    XTime now;
    uint64_t elapsed, seconds, tail;
    if (!view || !age_ms)
        return -1;
    *age_ms = 0;
    if (!view->available)
        return 0;
    XTime_GetTime(&now);
    if (now < view->received_time)
        return -1;
    elapsed = (uint64_t)(now - view->received_time);
    seconds = elapsed / COUNTS_PER_SECOND;
    tail = ((elapsed % COUNTS_PER_SECOND) * 1000U) / COUNTS_PER_SECOND;
    if (seconds > UINT64_MAX / 1000U || UINT64_MAX - seconds * 1000U < tail)
        *age_ms = UINT64_MAX;
    else
        *age_ms = seconds * 1000U + tail;
    return 1;
}

int doa_result_last_driver_error(void)
{
    return last_driver_error;
}

int doa_result_counts_snapshot(doa_result_counts_t *out)
{
    if(!out) return -1;
    out->published_count=debug_history.published_count;
    out->invalid_count=debug_history.invalid_count;
    return 0;
}
