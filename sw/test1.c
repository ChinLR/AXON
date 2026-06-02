// test1.c — MAC unit dot-product sanity: software vs. hardware.
// Trimmed for the 4K SRAM (no printf; uart_write helpers keep image + stack small).
// Uses the single-transaction MAC: one write per term carries {B,A} and triggers
// acc += A*B.

#include <stdint.h>
#include "uart.h"

static inline uint32_t read_mcycle(void) {
    uint32_t v;
    asm volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

static void print_str(const char *s) { while (*s) uart_write((uint8_t)*s++); }
static void print_int(int32_t v) {
    if (v < 0) { uart_write('-'); v = -v; }
    if (v == 0) { uart_write('0'); return; }
    char buf[12]; int n = 0;
    while (v > 0) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) uart_write((uint8_t)buf[n]);
}

// --- MAC unit register map (single-transaction) ---------------------------
//   0x00 MAC   [W] : wdata[7:0]=A(signed), wdata[15:8]=B(signed) -> acc += A*B
//   0x04 CLEAR [W] : any write clears the accumulator
//   0x08 RESULT[R] : 32-bit signed accumulator
#define MAC_BASE_ADDR (0x20000000UL)
#define MAC_DO     (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x00)))
#define MAC_CLEAR  (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x04)))
#define MAC_RESULT (*((volatile int32_t  *)(MAC_BASE_ADDR + 0x08)))

static inline void mac_clear(void) { MAC_CLEAR = 0; }
static inline void mac_accumulate(int8_t a, int8_t b) {
    MAC_DO = (uint32_t)(uint8_t)a | ((uint32_t)(uint8_t)b << 8);
}
static inline int32_t mac_read_result(void) { return (int32_t)MAC_RESULT; }

// --- Test vectors ---------------------------------------------------------
// 0: 1*4 + 2*3 + 3*2 + 4*1 = 20
// 1: 2*2 + 3*3 + 4*4       = 29
// 2: (-1)*1 + 2*(-2) + 3*3 = 4
#define NUM_TESTS 3
static const int8_t  vec_a[NUM_TESTS][4] = {{1,2,3,4},{2,3,4,0},{-1,2,3,0}};
static const int8_t  vec_b[NUM_TESTS][4] = {{4,3,2,1},{2,3,4,0},{1,-2,3,0}};
static const int8_t  vec_len[NUM_TESTS]  = {4,3,3};
static const int32_t expected[NUM_TESTS] = {20,29,4};

static int32_t dot_sw(const int8_t *a, const int8_t *b, int n) {
    int32_t acc = 0;
    for (int i = 0; i < n; i++) acc += (int32_t)a[i] * (int32_t)b[i];
    return acc;
}
static int32_t dot_hw(const int8_t *a, const int8_t *b, int n) {
    mac_clear();
    for (int i = 0; i < n; i++) mac_accumulate(a[i], b[i]);
    return mac_read_result();
}

int main(void) {
    uart_init();

    int pass = 1;
    uint32_t sw_cyc = 0, hw_cyc = 0;

    for (int t = 0; t < NUM_TESTS; t++) {
        uint32_t c0 = read_mcycle();
        int32_t  rs = dot_sw(vec_a[t], vec_b[t], vec_len[t]);
        sw_cyc += read_mcycle() - c0;

        c0 = read_mcycle();
        int32_t rh = dot_hw(vec_a[t], vec_b[t], vec_len[t]);
        hw_cyc += read_mcycle() - c0;

        print_str("t"); print_int(t);
        print_str(" sw=");  print_int(rs);
        print_str(" hw=");  print_int(rh);
        print_str(" exp="); print_int(expected[t]);
        if (rs == expected[t] && rh == expected[t]) {
            print_str(" OK\n");
        } else {
            print_str(" BAD\n");
            pass = 0;
        }
    }

    print_str("SWcyc="); print_int((int32_t)sw_cyc);
    print_str(" HWcyc="); print_int((int32_t)hw_cyc); uart_write('\n');
    print_str(pass ? "PASS\n" : "FAIL\n");

    uart_write_flush();
    return pass ? 0 : 1;
}
