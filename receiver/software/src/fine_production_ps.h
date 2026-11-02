#ifndef FINE_PRODUCTION_PS_H
#define FINE_PRODUCTION_PS_H
#include <stdint.h>
#include "hardware/result_identity.h"
#include "epoch_journal.h"
#define PL_FINE_PACKET_WORDS 34U
#define PL_FINE_CONFIG_WORDS 24U
/* Transport ABI1: low six words identity; all numbers below are immutable.
 * Numeric status is (stage,status), NOT the older PS enum alone. */
enum {
    PL_EPOCH_BIT=0, PL_EPOCH_WIDTH=64,
    PL_SEQ_BIT=64, PL_SEQ_WIDTH=32,
    PL_CONFIG_VERSION_BIT=96, PL_CONFIG_VERSION_WIDTH=32,
    PL_FRAME_SEQ_BIT=1015, PL_FRAME_SEQ_WIDTH=32,
    PL_WINDOW_START_ID_BIT=967, PL_WINDOW_START_ID_WIDTH=48,
    PL_FRAME_START_ID_BIT=919, PL_FRAME_START_ID_WIDTH=48,
    PL_EVENT_ID_BIT=871, PL_EVENT_ID_WIDTH=48,
    PL_BIN_BIT=861, PL_BIN_WIDTH=10,
    PL_F_HAT_HZ_BIT=812, PL_F_HAT_HZ_WIDTH=49,
    PL_PHASE_INCREMENT_BIT=764, PL_PHASE_INCREMENT_WIDTH=48,
    PL_DELTA_BIT=730, PL_DELTA_WIDTH=34,
    PL_PROMINENCE_BIT=693, PL_PROMINENCE_WIDTH=37,
    PL_CURVATURE_BIT=655, PL_CURVATURE_WIDTH=38,
    PL_INTERPOLATION_STATUS_BIT=647, PL_INTERPOLATION_STATUS_WIDTH=8,
    PL_WINDOW_PRESENT_BIT=646, PL_WINDOW_PRESENT_WIDTH=1,
    PL_I0_BIT=605, PL_I0_WIDTH=41,
    PL_Q0_BIT=564, PL_Q0_WIDTH=41,
    PL_I1_BIT=523, PL_I1_WIDTH=41,
    PL_Q1_BIT=482, PL_Q1_WIDTH=41,
    PL_NUMERIC_VALID_BIT=481, PL_NUMERIC_VALID_WIDTH=1,
    PL_STATUS_BIT=473, PL_STATUS_WIDTH=8,
    PL_CALIBRATED_VALID_BIT=472, PL_CALIBRATED_VALID_WIDTH=1,
    PL_CALIBRATION_STATUS_BIT=464, PL_CALIBRATION_STATUS_WIDTH=8,
    PL_PHASE_RAW_BIT=428, PL_PHASE_RAW_WIDTH=36,
    PL_PHASE_CAL_BIT=392, PL_PHASE_CAL_WIDTH=36,
    PL_PROFILE_ID_BIT=128, PL_PROFILE_ID_WIDTH=32,
    PL_GEOMETRY_ID_BIT=160, PL_GEOMETRY_ID_WIDTH=32,
    PL_FINE_NUMERIC_VALID_BIT=391, PL_FINE_NUMERIC_VALID_WIDTH=1,
    PL_STATUS_STAGE_BIT=387, PL_STATUS_STAGE_WIDTH=4,
    PL_THETA_VALID_BIT=386, PL_THETA_VALID_WIDTH=1,
    PL_THETA_BIT=350, PL_THETA_WIDTH=36,
    PL_U_BIT=312, PL_U_WIDTH=38,
    PL_U_UNCHECKED_BIT=258, PL_U_UNCHECKED_WIDTH=54,
    PL_GAIN_PI_BIT=206, PL_GAIN_PI_WIDTH=52,
    PL_U_TOLERANCE_BIT=195, PL_U_TOLERANCE_WIDTH=11,
    PL_DOMAIN_CLAMPED_BIT=194, PL_DOMAIN_CLAMPED_WIDTH=1,
    PL_NEAR_ENDFIRE_BIT=193, PL_NEAR_ENDFIRE_WIDTH=1,
    PL_THETA_ENDPOINT_SNAPPED_BIT=192, PL_THETA_ENDPOINT_SNAPPED_WIDTH=1,
    PL_FINE_USED_BITS=1047
};
typedef struct { uint32_t word[PL_FINE_PACKET_WORDS]; } pl_fine_packet_t;
typedef struct {
    uint32_t fine[PL_FINE_CONFIG_WORDS];
    uint32_t detector[4];
    unsigned int reviewed; /* P_min/D_min/calibration/geometry approval */
} pl_fine_configuration_t;
uint64_t pl_fine_bits(const pl_fine_packet_t *,unsigned int bit,unsigned int width);
int64_t pl_fine_signed(const pl_fine_packet_t *,unsigned int bit,unsigned int width);
int pl_fine_packet_identity(const pl_fine_packet_t *,result_identity_t *);
/* PS-only observation, NOT new words/fields in the production Result ABI.
 * A received packet may never establish the expected epoch/config itself. */
typedef enum {
    PL_FINE_LIFECYCLE_INIT = 0,
    PL_FINE_LIFECYCLE_STOP,
    PL_FINE_LIFECYCLE_SESSION_READY
} pl_fine_lifecycle_event_t;
typedef struct {
    uint64_t generation;
    uint64_t session_epoch;
    uint32_t config_version;
    unsigned int ready;
    pl_fine_lifecycle_event_t event;
} pl_fine_lifecycle_t;
int pl_fine_lifecycle_snapshot(pl_fine_lifecycle_t *);
/* One optional PS-only foreground listener; replay current context on install.
 * Must not issue MMIO, call pl_fine_* or change the subscription in callback. */
typedef void (*pl_fine_lifecycle_listener_t)(const pl_fine_lifecycle_t *);
void pl_fine_lifecycle_set_listener(pl_fine_lifecycle_listener_t);
int pl_fine_init(void);
/* Explicit abort/invalidation; caller logs/disposes old unACKed results first. */
int pl_fine_stop(void);
/* NO fallback epoch. Requires mounted verified persistent journal and fully
 * reviewed config. reserve commits durable storage before SESSION_INSTALL.
 * Does not provision/erase a blank journal or initialize the QSPI backend. */
int pl_fine_start_new_session(epoch_journal_t *,const pl_fine_configuration_t *);
#if defined(ENGINEERING_SESSION) && ENGINEERING_SESSION
/* Explicit isolated engineering policy: volatile identity, cold PL load only.
 * Engineering config may use explicitly selected HIL profiles. No journal IO.
 * Not a claim of uniqueness across FPGA reloads or arbitrary PS-only restarts. */
int pl_fine_start_engineering_session(uint64_t,const pl_fine_configuration_t *);
/* Foreground-only bounded mailbox owner, same wire protocol/ACK semantics.
 * NULL cfg requests STOP only. Never automatically replays an uncertain command.
 * begin invalidates the view; step performs at most one bounded mailbox action.
 * Existing synchronous poll/ACK/status calls must not interleave while busy.
 * step: 0 pending, 1 completed, negative error; cancel waits the current ACK then STOP.
 */
int pl_fine_control_begin(const pl_fine_configuration_t *,uint64_t epoch_floor);
int pl_fine_control_step(void);
int pl_fine_control_busy(void);
int pl_fine_control_cancel(void);
/* Last actually acknowledged F101, cached only; no MMIO and no ready inference. */
int pl_fine_control_runtime(uint32_t *);
#endif
int pl_fine_poll(pl_fine_packet_t *);
int pl_fine_result_ack(const result_identity_t *);
int pl_fine_clear_fault(uint64_t epoch,uint32_t seq);
int pl_fine_set_consumer(unsigned int mode);
int pl_fine_release_window(uint64_t epoch,uint32_t seq);
int pl_fine_status(unsigned int index,uint32_t *);
#endif
