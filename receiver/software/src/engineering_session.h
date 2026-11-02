#ifndef ENGINEERING_SESSION_H
#define ENGINEERING_SESSION_H
#include "fine_production_ps.h"
#include "hil_profiles.h"
enum engineering_state { ENG_CLOSED, ENG_STARTING, ENG_MEASURING, ENG_ERROR };
/* Not persistent: new FPGA configuration starts a new engineering lifetime. */
#define ENGINEERING_EPOCH_BASE UINT64_C(0x454e470000000001)
void engineering_configuration(pl_fine_configuration_t *);
int engineering_configuration_for_profile(const hil_profile_t *,pl_fine_configuration_t *);
int engineering_session_start(pl_fine_lifecycle_t *);
#endif
