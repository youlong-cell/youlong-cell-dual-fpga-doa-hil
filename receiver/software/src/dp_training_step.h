#ifndef DP_TRAINING_STEP_H
#define DP_TRAINING_STEP_H
#include <stdint.h>
/* One A53 foreground owner. No allocation, sleeps, MMIO or IRQ work here.
 * The adapter reuses the existing AMD PHY/AUX primitives. */
enum dp_train_op { DP_OP_RESET, DP_OP_PATTERN, DP_OP_STATUS, DP_OP_CR_OK,
 DP_OP_EQ_OK, DP_OP_ADJUST, DP_OP_VS, DP_OP_RATE, DP_OP_LANES, DP_OP_FINAL };
typedef int (*dp_train_io)(void *, enum dp_train_op, unsigned);
enum dp_train_state { DP_TR_RESET, DP_TR_CR_BEGIN, DP_TR_CR_WAIT,
 DP_TR_CR_READ, DP_TR_CR_CHECK, DP_TR_CR_ADJUST, DP_TR_EQ_BEGIN,
 DP_TR_EQ_WAIT, DP_TR_EQ_READ, DP_TR_EQ_ADJUST, DP_TR_EQ_CHECK,
 DP_TR_OFF_ADJUST, DP_TR_RATE, DP_TR_LANES, DP_TR_OFF_FINAL,
 DP_TR_FINAL, DP_TR_DONE, DP_TR_FAILED };
typedef struct {
 enum dp_train_state state;
 uint64_t due_us, start_us, previous_us;
 uint32_t delay_us, recovery_left, attempts_left, eq_iterations;
 unsigned previous_vs, same_vs;
} dp_training_t;
/* step returns 0 pending, 1 success, -1 failure; never success on partial work. */
void dp_training_begin(dp_training_t *, uint64_t now_us, uint32_t delay_us);
int dp_training_step(dp_training_t *, uint64_t now_us, dp_train_io, void *);
/* Adapter implemented alongside private primitives in candidate xdppsu.c. */
int dp_training_vendor_io(void *, enum dp_train_op, unsigned);
uint32_t dp_training_vendor_delay(void *);
void dp_training_vendor_budget_begin(void);
void dp_training_vendor_budget_end(void);
#endif
