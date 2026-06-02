// test4.c — directed isolation test for the single-transaction MAC unit.
// Tiny on purpose (fits 4K easily). Each line prints an actual value.
//
// Register map (user domain base = 0x2000_0000):
//   0x00 MAC   [W] : wdata[7:0]=A(signed), wdata[15:8]=B(signed) -> acc += A*B
//   0x04 CLEAR [W] : any write clears the accumulator
//   0x08 RESULT[R] : 32-bit signed accumulator
//
// Interpretation:
//   clr  != 0    -> CLEAR doesn't reset
//   mac1 != 15   -> single multiply-accumulate broken
//   mac2 != 30   -> accumulation (acc += A*B) broken
//   clr2 != 0    -> CLEAR after accumulate broken
//   neg  != -20  -> signed operand handling broken
//   dot  != 20   -> BACK-TO-BACK accumulate broken (this is the case that
//                   used to race with the 3-write protocol; no barriers here)
//   ndot != -6   -> back-to-back with negative operands broken

#include <stdint.h>
#include "uart.h"

static void print_str(const char *s) { while (*s) uart_write((uint8_t)*s++); }
static void print_int(int32_t v) {
    if (v < 0) { uart_write('-'); v = -v; }
    if (v == 0) { uart_write('0'); return; }
    char b[12]; int n = 0;
    while (v > 0) { b[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) uart_write((uint8_t)b[n]);
}
static void line(const char *l, int32_t v) { print_str(l); print_int(v); uart_write('\n'); }

#define MAC_BASE_ADDR (0x20000000UL)
#define MAC_DO     (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x00)))
#define MAC_CLEAR  (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x04)))
#define MAC_RESULT (*((volatile int32_t  *)(MAC_BASE_ADDR + 0x08)))

static inline void mac_clear(void) { MAC_CLEAR = 0; }
static inline void mac_acc(int8_t a, int8_t b) {
    MAC_DO = (uint32_t)(uint8_t)a | ((uint32_t)(uint8_t)b << 8);
}

int main(void) {
    uart_init();
    int fail = 0;

    // 1. clear resets accumulator
    mac_clear();
    line("clr=", MAC_RESULT);          // expect 0
    if (MAC_RESULT != 0) fail = 1;

    // 2. single MAC: 3*5
    mac_acc(3, 5);
    line("mac1=", MAC_RESULT);         // expect 15
    if (MAC_RESULT != 15) fail = 1;

    // 3. accumulate again: +3*5 -> 30
    mac_acc(3, 5);
    line("mac2=", MAC_RESULT);         // expect 30
    if (MAC_RESULT != 30) fail = 1;

    // 4. clear after accumulate
    mac_clear();
    line("clr2=", MAC_RESULT);         // expect 0
    if (MAC_RESULT != 0) fail = 1;

    // 5. signed operand: -4 * 5 = -20
    mac_clear();
    mac_acc(-4, 5);
    line("neg=", MAC_RESULT);          // expect -20
    if (MAC_RESULT != -20) fail = 1;

    // 6. BACK-TO-BACK dot product, no barriers: [1,2,3,4].[4,3,2,1] = 20
    mac_clear();
    mac_acc(1, 4);
    mac_acc(2, 3);
    mac_acc(3, 2);
    mac_acc(4, 1);
    line("dot=", MAC_RESULT);          // expect 20
    if (MAC_RESULT != 20) fail = 1;

    // 7. back-to-back with negatives: (-1)*3 + (-1)*3 = -6
    mac_clear();
    mac_acc(-1, 3);
    mac_acc(-1, 3);
    line("ndot=", MAC_RESULT);         // expect -6
    if (MAC_RESULT != -6) fail = 1;

    print_str(fail ? "FAIL\n" : "PASS\n");
    uart_write_flush();
    return fail;
}
