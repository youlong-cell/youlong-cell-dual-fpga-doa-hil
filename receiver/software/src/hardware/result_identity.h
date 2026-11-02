#ifndef RESULT_IDENTITY_H
#define RESULT_IDENTITY_H
#include <stdint.h>

/* V1 identity ABI only. Not an MMIO/CDC driver and not proof of epoch safety.
 * Serialize six uint32_t words explicitly; never memcpy a padded C struct.
 * RTL result_identity[191:0] = {geometry,calibration,version,seq,epoch}.
 */
#define RESULT_IDENTITY_ABI_VERSION UINT32_C(1)
#define RESULT_IDENTITY_WORDS 6U
#define RESULT_IDENTITY_BYTES 24U
#define FINE_CONFIG_WORDS 24U
#define FINE_CONFIG_GEOMETRY_ID_WORD 23U
#define FINE_RESULT_PAYLOAD_BITS 1047U
typedef struct {
    uint64_t session_epoch;
    uint32_t candidate_seq;
    uint32_t config_version;
    uint32_t calibration_profile_id;
    uint32_t geometry_id;
} result_identity_t;

static inline void result_identity_encode_words(const result_identity_t *p,
                                                uint32_t words[RESULT_IDENTITY_WORDS])
{
    words[0]=(uint32_t)p->session_epoch;
    words[1]=(uint32_t)(p->session_epoch>>32);
    words[2]=p->candidate_seq; words[3]=p->config_version;
    words[4]=p->calibration_profile_id; words[5]=p->geometry_id;
}
static inline void result_identity_decode_words(const uint32_t words[RESULT_IDENTITY_WORDS],
                                                result_identity_t *p)
{
    p->session_epoch=((uint64_t)words[1]<<32)|(uint64_t)words[0];
    p->candidate_seq=words[2]; p->config_version=words[3];
    p->calibration_profile_id=words[4]; p->geometry_id=words[5];
}
/* Key equality for RESULT_ACK; this does NOT validate session uniqueness.
 * Calibration/geometry are immutable provenance, not extra ownership keys.
 */
static inline int result_identity_same_key(const result_identity_t *a,
                                           const result_identity_t *b)
{
    return a->session_epoch==b->session_epoch &&
           a->candidate_seq==b->candidate_seq && a->config_version==b->config_version;
}
static inline int result_identity_same_provenance(const result_identity_t *a,
                                                  const result_identity_t *b)
{
    return result_identity_same_key(a,b) &&
           a->calibration_profile_id==b->calibration_profile_id && a->geometry_id==b->geometry_id;
}
#endif
