#ifndef EPOCH_QSPI_PROBE_H
#define EPOCH_QSPI_PROBE_H
#include "xqspipsu.h"

/* Diagnostic only; NOT called by production main. Caller must initialize
 * and exclusively own an idle controller with the correct chip/bus selected.
 * Only sends 0x9f and receives ID bytes; no WREN, erase/program/status write,
 * address-mode change or Flash reset. Does not infer safe partition addresses.
 */
int epoch_qspi_read_jedec(XQspiPsu *controller,u8 id[3]);
#endif
