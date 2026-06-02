#include <stdint.h>
#include "uart.h"
#include "print.h"

// ---------------------------------------------------------------------------
// Cycle counter
// ---------------------------------------------------------------------------
static inline uint32_t read_mcycle(void) {
    uint32_t v;
    asm volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

// ---------------------------------------------------------------------------
// Signed decimal print helper
// ---------------------------------------------------------------------------
static void print_int(int32_t v) {
    if (v < 0) { uart_write('-'); v = -v; }
    if (v == 0) { uart_write('0'); return; }
    char buf[12];
    int n = 0;
    while (v > 0) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) uart_write(buf[n]);
}

// ---------------------------------------------------------------------------
// MAC unit register map (user domain base = 0x2000_0000)
// ---------------------------------------------------------------------------
#define MAC_BASE_ADDR      (0x20000000UL)
#define MAC_OPERAND_A  (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x00)))
#define MAC_OPERAND_B  (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x04)))
#define MAC_CONTROL    (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x08)))
#define MAC_RESULT     (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x0C)))

#define MAC_CTRL_ACCUMULATE (1u << 0)
#define MAC_CTRL_CLEAR      (1u << 1)

static inline void mac_clear(void) {
    MAC_CONTROL = MAC_CTRL_CLEAR;
}

static inline void mac_accumulate(int8_t a, int8_t b) {
    MAC_OPERAND_A = (uint32_t)(int32_t)a;
    MAC_OPERAND_B = (uint32_t)(int32_t)b;
    MAC_CONTROL   = MAC_CTRL_ACCUMULATE;
}

static inline int32_t mac_read_result(void) {
    return (int32_t)MAC_RESULT;
}

// ---------------------------------------------------------------------------
// Test vectors - three separate dot products
// expected_0: 1*4 + 2*3 + 3*2 + 4*1 = 20
// expected_1: 2*2 + 3*3 + 4*4       = 29
// expected_2: (-1)*1 + 2*(-2) + 3*3 = 4
// ---------------------------------------------------------------------------
#define NUM_TESTS 3

static const int8_t vec_a[NUM_TESTS][4] = {
    { 1,  2,  3,  4},
    { 2,  3,  4,  0},
    {-1,  2,  3,  0}
};
static const int8_t vec_b[NUM_TESTS][4] = {
    { 4,  3,  2,  1},
    { 2,  3,  4,  0},
    { 1, -2,  3,  0}
};
static const int8_t vec_len[NUM_TESTS] = {4, 3, 3};
static const int32_t expected[NUM_TESTS] = {20, 29, 4};

// ---------------------------------------------------------------------------
// SW: core does the multiply-accumulate itself
// ---------------------------------------------------------------------------
static int32_t dot_product_sw(const int8_t *a, const int8_t *b, int n) {
    int32_t acc = 0;
    for (int i = 0; i < n; i++)
        acc += (int32_t)a[i] * (int32_t)b[i];
    return acc;
}

// ---------------------------------------------------------------------------
// HW: core writes operands to MAC unit, MAC unit does the computation
// ---------------------------------------------------------------------------
static int32_t dot_product_hw(const int8_t *a, const int8_t *b, int n) {
    mac_clear();
    for (int i = 0; i < n; i++)
        mac_accumulate(a[i], b[i]);
    return mac_read_result();
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void) {
    uart_init();

    printf("=== Core (SW) test ===\n");
    uint32_t total_sw = 0;
    int sw_pass = 1;
    for (int t = 0; t < NUM_TESTS; t++) {
        uint32_t t0     = read_mcycle();
        int32_t  result = dot_product_sw(vec_a[t], vec_b[t], vec_len[t]);
        uint32_t cycles = read_mcycle() - t0;
        total_sw += cycles;

        printf("  test "); print_int(t);
        printf(": result="); print_int(result);
        printf(" cycles="); print_int((int32_t)cycles);
        if (result == expected[t]) {
            printf(" PASS\n");
        } else {
            printf(" FAIL (expected "); print_int(expected[t]); printf(")\n");
            sw_pass = 0;
        }
    }
    printf("  SW total cycles: "); print_int((int32_t)total_sw); printf("\n");

    printf("=== MAC (HW) test ===\n");
    uint32_t total_hw = 0;
    int hw_pass = 1;
    for (int t = 0; t < NUM_TESTS; t++) {
        uint32_t t0     = read_mcycle();
        int32_t  result = dot_product_hw(vec_a[t], vec_b[t], vec_len[t]);
        uint32_t cycles = read_mcycle() - t0;
        total_hw += cycles;

        printf("  test "); print_int(t);
        printf(": result="); print_int(result);
        printf(" cycles="); print_int((int32_t)cycles);
        if (result == expected[t]) {
            printf(" PASS\n");
        } else {
            printf(" FAIL (expected "); print_int(expected[t]); printf(")\n");
            hw_pass = 0;
        }
    }
    printf("  HW total cycles: "); print_int((int32_t)total_hw); printf("\n");

    printf("=== Comparison ===\n");
    printf("  SW total: "); print_int((int32_t)total_sw); printf(" cycles\n");
    printf("  HW total: "); print_int((int32_t)total_hw); printf(" cycles\n");
    if (total_hw < total_sw) {
        printf("  MAC is faster by "); print_int((int32_t)(total_sw - total_hw));
        printf(" cycles\n");
    } else {
        printf("  MAC is NOT faster (check HW connection)\n");
    }

    uart_write_flush();

    if (sw_pass && hw_pass) // && total_hw < total_sw
        return 0;  // full PASS
    else
        return 1;  // FAIL
}