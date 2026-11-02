#ifndef AUTO_PROFILE_H
#define AUTO_PROFILE_H
#include <stdint.h>
#include "engineering_session.h"
#include "spectrum.h"
enum auto_profile_state { AP_OFF, AP_SCAN, AP_CONFIRM, AP_SWITCHING, AP_RUNNING, AP_FAULT };
typedef struct {
    uint32_t confirm_frames, confirm_ms, max_gap_ms, loss_ms, enter_hz, hold_hz;
    float competing_margin_db;
} auto_profile_config_t;
extern const auto_profile_config_t auto_profile_defaults;
/* All inputs are from RELEASE-GRANTED raw FFT frames; never UI-smoothed bins. */
typedef struct {
    enum auto_profile_state state;
    auto_profile_config_t config;
    const hil_profile_t *active,*target;
    pl_fine_lifecycle_t context;
    uint32_t enabled, active_ready, visible, desired_hz, count, sequence, have_sequence;
    uint64_t since_ms,last_frame_ms,last_good_ms,clock_ms;
    int error, stop_pending;
    uint64_t switches, rejected_frames, duplicate_frames;
} auto_profile_t;
void auto_profile_init(auto_profile_t *,const pl_fine_lifecycle_t *,int enabled);
/* Re-arm is explicit (UART f), never implicit after a user STOP/fatal. */
int auto_profile_enable(auto_profile_t *);
int auto_profile_disable(auto_profile_t *);
void auto_profile_observe(auto_profile_t *,const spectrum_t *,const spectrum_t *,
                          uint32_t frame_seq,uint64_t now_ms,int quality);
void auto_profile_service(auto_profile_t *,uint64_t now_ms,int bus_ok);
const char *auto_profile_state_name(enum auto_profile_state);
#endif
