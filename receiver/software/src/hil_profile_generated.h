/* 10.23已确认零点的独立候选；工程补偿、未独立绝对标定；勿手改。 */
#ifndef HIL_PROFILE_GENERATED_H
#define HIL_PROFILE_GENERATED_H
#ifndef HIL_PROFILE_HZ
#define HIL_PROFILE_HZ 5000000
#endif
#if HIL_PROFILE_HZ != 1000000 && HIL_PROFILE_HZ != 2000000 && HIL_PROFILE_HZ != 5000000 && HIL_PROFILE_HZ != 10000000
#error Unsupported HIL_PROFILE_HZ
#endif
static const hil_profile_t embedded_hil_profiles[] = {
 { .geometry_id=1u, .profile_id=15u, .geometry_valid=1u, .calibration_valid=1u, .measured=0u,
 .name="HIL_FIXED_ARRAY_5M", .model="FIXED BASELINE", .bias_display="-0.021 deg", .d_mm=5000u, .c_mps=300000000u,
 .bias_pi_f35=-INT64_C(3998054), .geometry_a_f24=UINT64_C(503316480000000),
 .calibration_words={UINT32_C(1),UINT32_C(1),UINT32_C(4290969242),UINT32_C(4294967295),UINT32_C(2684354560),UINT32_C(3515),UINT32_C(3758096384),UINT32_C(4296),UINT32_C(15),UINT32_C(0)}, .geometry_words={UINT32_C(1),UINT32_C(2147483648),UINT32_C(117187),UINT32_C(0),UINT32_C(1)},
 .geometry_sha256="24919919d55511979a796eea8797d958e7a93bd84a6aec94a8ad98217cd1dbb4", .calibration_sha256="d7bef884c59ed4443dc7179fe31d83f15a55891418da472bb1d344fb3d414ea2",
 .reference_hz=1000000u, .minimum_hz=900000u, .maximum_hz=1100000u, .cal_name="CAL_1M", .evidence_state="HIL_COMMAND_ZERO_TRAINED_PENDING_INDEPENDENT_RETEST" },
 { .geometry_id=1u, .profile_id=16u, .geometry_valid=1u, .calibration_valid=1u, .measured=0u,
 .name="HIL_FIXED_ARRAY_5M", .model="FIXED BASELINE", .bias_display="-0.052 deg", .d_mm=5000u, .c_mps=300000000u,
 .bias_pi_f35=-INT64_C(9989205), .geometry_a_f24=UINT64_C(503316480000000),
 .calibration_words={UINT32_C(1),UINT32_C(1),UINT32_C(4284978091),UINT32_C(4294967295),UINT32_C(3758096384),UINT32_C(7421),UINT32_C(536870912),UINT32_C(8203),UINT32_C(16),UINT32_C(0)}, .geometry_words={UINT32_C(1),UINT32_C(2147483648),UINT32_C(117187),UINT32_C(0),UINT32_C(1)},
 .geometry_sha256="24919919d55511979a796eea8797d958e7a93bd84a6aec94a8ad98217cd1dbb4", .calibration_sha256="d7bef884c59ed4443dc7179fe31d83f15a55891418da472bb1d344fb3d414ea2",
 .reference_hz=2000000u, .minimum_hz=1900000u, .maximum_hz=2100000u, .cal_name="CAL_2M", .evidence_state="HIL_COMMAND_ZERO_PROVISIONAL_LT30_PENDING_RETEST" },
 { .geometry_id=1u, .profile_id=17u, .geometry_valid=1u, .calibration_valid=1u, .measured=0u,
 .name="HIL_FIXED_ARRAY_5M", .model="FIXED BASELINE", .bias_display="-0.157 deg", .d_mm=5000u, .c_mps=300000000u,
 .bias_pi_f35=-INT64_C(29928453), .geometry_a_f24=UINT64_C(503316480000000),
 .calibration_words={UINT32_C(1),UINT32_C(1),UINT32_C(4265038843),UINT32_C(4294967295),UINT32_C(2684354560),UINT32_C(19140),UINT32_C(3758096384),UINT32_C(19921),UINT32_C(17),UINT32_C(0)}, .geometry_words={UINT32_C(1),UINT32_C(2147483648),UINT32_C(117187),UINT32_C(0),UINT32_C(1)},
 .geometry_sha256="24919919d55511979a796eea8797d958e7a93bd84a6aec94a8ad98217cd1dbb4", .calibration_sha256="d7bef884c59ed4443dc7179fe31d83f15a55891418da472bb1d344fb3d414ea2",
 .reference_hz=5000000u, .minimum_hz=4900000u, .maximum_hz=5100000u, .cal_name="CAL_5M", .evidence_state="HIL_COMMAND_ZERO_TRAINED_PENDING_INDEPENDENT_RETEST" },
 { .geometry_id=1u, .profile_id=18u, .geometry_valid=1u, .calibration_valid=1u, .measured=0u,
 .name="HIL_FIXED_ARRAY_5M", .model="FIXED BASELINE", .bias_display="-0.564 deg", .d_mm=5000u, .c_mps=300000000u,
 .bias_pi_f35=-INT64_C(107611127), .geometry_a_f24=UINT64_C(503316480000000),
 .calibration_words={UINT32_C(1),UINT32_C(1),UINT32_C(4187356169),UINT32_C(4294967295),UINT32_C(3758096384),UINT32_C(38671),UINT32_C(536870912),UINT32_C(39453),UINT32_C(18),UINT32_C(0)}, .geometry_words={UINT32_C(1),UINT32_C(2147483648),UINT32_C(117187),UINT32_C(0),UINT32_C(1)},
 .geometry_sha256="24919919d55511979a796eea8797d958e7a93bd84a6aec94a8ad98217cd1dbb4", .calibration_sha256="d7bef884c59ed4443dc7179fe31d83f15a55891418da472bb1d344fb3d414ea2",
 .reference_hz=10000000u, .minimum_hz=9900000u, .maximum_hz=10100000u, .cal_name="CAL_10M", .evidence_state="HIL_COMMAND_ZERO_PROVISIONAL_LT30_PENDING_RETEST" },
};
#endif
