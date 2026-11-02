#ifndef HIL_PROFILES_H
#define HIL_PROFILES_H
#include "fine_production_ps.h"
typedef struct {
    uint32_t geometry_id,profile_id,d_mm,c_mps;
    unsigned geometry_valid,calibration_valid,measured;
    const char *name,*model,*bias_display,*geometry_sha256,*calibration_sha256;
    int64_t bias_pi_f35;
    uint64_t geometry_a_f24;
    uint32_t calibration_words[10],geometry_words[5];
    uint32_t reference_hz, minimum_hz, maximum_hz;
    const char *cal_name, *evidence_state;
} hil_profile_t;
const hil_profile_t *hil_profile_current(void);
/* PS pointer changes only AFTER complete PL installation and ready ACK. */
int hil_profile_select_installed(const hil_profile_t *);
/* Read-only registry. This does NOT switch an installed session. */
const hil_profile_t *hil_profile_for_frequency(uint32_t hz);
/* Startup loads the build-validated embedded JSON snapshot, not live SD files. */
int hil_profile_apply(const hil_profile_t *,pl_fine_configuration_t *);
#endif
