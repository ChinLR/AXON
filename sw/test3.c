// Copyright (c) 2026 ETH Zurich.
// Licensed under Solderpad Hardware License 0.51.
//
// test3.c — 8 -> 4 -> 2 INT8 MLP, software vs. MAC-hardware, side by side.
//
// Trimmed for the 4K on-chip SRAM (2 banks x 512 x 32b = 4096 B): no printf
// (keeps the stack shallow + cuts format-string rodata), one print_vec helper.
//
// Uses the single-transaction MAC unit: one OBI write per term carries both
// operands and triggers acc += A*B. No multi-write operand/trigger skew, so
// the back-to-back inner loop is correct without any SW barriers.
//
// Expected: h=[0,3,0,3], out=[6,-6] for BOTH paths.

#include <stdint.h>
#include "uart.h"

// --- cycle counter --------------------------------------------------------
static inline uint32_t read_mcycle(void) {
    uint32_t v;
    asm volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

// --- tiny output helpers (uart_write only, no printf) ---------------------
static void print_str(const char *s) {
    while (*s) uart_write((uint8_t)*s++);
}

static void print_int(int32_t v) {
    if (v < 0) { uart_write('-'); v = -v; }
    if (v == 0) { uart_write('0'); return; }
    char buf[12];
    int n = 0;
    while (v > 0) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) uart_write((uint8_t)buf[n]);
}

static void print_vec(const char *label, const int8_t *v, int n) {
    print_str(label);
    uart_write('[');
    for (int i = 0; i < n; i++) {
        if (i) uart_write(',');
        print_int(v[i]);
    }
    uart_write(']');
    uart_write('\n');
}

// --- MAC unit register map (user domain base = 0x2000_0000) ---------------
//   0x00 MAC   [W] : wdata[7:0]=A(signed), wdata[15:8]=B(signed) -> acc += A*B
//   0x04 CLEAR [W] : any write clears the accumulator
//   0x08 RESULT[R] : 32-bit signed accumulator
#define MAC_BASE_ADDR (0x20000000UL)
#define MAC_DO     (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x00)))
#define MAC_CLEAR  (*((volatile uint32_t *)(MAC_BASE_ADDR + 0x04)))
#define MAC_RESULT (*((volatile int32_t  *)(MAC_BASE_ADDR + 0x08)))

static inline void mac_clear(void) {
    MAC_CLEAR = 0;
}
static inline void mac_accumulate(int8_t a, int8_t b) {
    // pack {B, A} into one word: low byte = A, next byte = B
    MAC_DO = (uint32_t)(uint8_t)a | ((uint32_t)(uint8_t)b << 8);
}
static inline int32_t mac_read_result(void) {
    return (int32_t)MAC_RESULT;
}

// --- network --------------------------------------------------------------
#define DIM_IN   8
#define DIM_H    4
#define DIM_OUT  2
#define SHIFT_L1 2
#define SHIFT_L2 0

static const int8_t w1[DIM_H * DIM_IN] = {
     1,  0,  1,  0,  1,  0,  1,  0,
     0,  1,  0,  1,  0,  1,  0,  1,
     1, -1,  1, -1,  1, -1,  1, -1,
    -1,  1, -1,  1, -1,  1, -1,  1,
};
static const int8_t w2[DIM_OUT * DIM_H] = {
     1,  1,  1,  1,
     1, -1,  1, -1,
};
static const int8_t x_test[DIM_IN] = {
    10, -5, 20, 0, -10, 15, -20, 5,
};

static int8_t relu_requantize(int32_t acc, int shift) {
    if (acc < 0) acc = 0;
    acc >>= shift;
    if (acc > 127) acc = 127;
    return (int8_t)acc;
}

static int8_t saturate_requantize(int32_t acc, int shift) {
    acc >>= shift;
    if (acc >  127) acc =  127;
    if (acc < -128) acc = -128;
    return (int8_t)acc;
}

// --- SW forward pass (core does the MACs) ---------------------------------
static void mlp_sw(int8_t *h, int8_t *y) {
    for (int o = 0; o < DIM_H; ++o) {
        int32_t acc = 0;
        for (int i = 0; i < DIM_IN; ++i)
            acc += (int32_t)w1[o * DIM_IN + i] * (int32_t)x_test[i];
        h[o] = relu_requantize(acc, SHIFT_L1);
    }
    for (int o = 0; o < DIM_OUT; ++o) {
        int32_t acc = 0;
        for (int i = 0; i < DIM_H; ++i)
            acc += (int32_t)w2[o * DIM_H + i] * (int32_t)h[i];
        y[o] = saturate_requantize(acc, SHIFT_L2);
    }
}

// --- HW forward pass (MAC unit does the accumulate; ReLU/sat in SW) -------
static void mlp_hw(int8_t *h, int8_t *y) {
    for (int o = 0; o < DIM_H; ++o) {
        mac_clear();
        for (int i = 0; i < DIM_IN; ++i)
            mac_accumulate(w1[o * DIM_IN + i], x_test[i]);
        h[o] = relu_requantize(mac_read_result(), SHIFT_L1);
    }
    for (int o = 0; o < DIM_OUT; ++o) {
        mac_clear();
        for (int i = 0; i < DIM_H; ++i)
            mac_accumulate(w2[o * DIM_H + i], h[i]);
        y[o] = saturate_requantize(mac_read_result(), SHIFT_L2);
    }
}

// --- main -----------------------------------------------------------------
int main(void) {
    uart_init();

    int8_t h_sw[DIM_H], y_sw[DIM_OUT];
    int8_t h_hw[DIM_H], y_hw[DIM_OUT];

    // SW run
    uint32_t t0 = read_mcycle();
    mlp_sw(h_sw, y_sw);
    uint32_t cycles_sw = read_mcycle() - t0;

    print_vec("SW h=", h_sw, DIM_H);
    print_vec("SW y=", y_sw, DIM_OUT);
    print_str("SW cyc="); print_int((int32_t)cycles_sw); uart_write('\n');

    // HW run
    uint32_t t1 = read_mcycle();
    mlp_hw(h_hw, y_hw);
    uint32_t cycles_hw = read_mcycle() - t1;

    print_vec("HW h=", h_hw, DIM_H);
    print_vec("HW y=", y_hw, DIM_OUT);
    print_str("HW cyc="); print_int((int32_t)cycles_hw); uart_write('\n');

    // cycle comparison (reported, not gated)
    if (cycles_hw < cycles_sw) {
        print_str("MAC faster by "); print_int((int32_t)(cycles_sw - cycles_hw));
    } else {
        print_str("Core faster by "); print_int((int32_t)(cycles_hw - cycles_sw));
    }
    print_str(" cyc\n");

    // PASS/FAIL: correctness of both paths only
    int sw_pass = (y_sw[0] == 6 && y_sw[1] == -6);
    int hw_pass = (y_hw[0] == 6 && y_hw[1] == -6);
    print_str((sw_pass && hw_pass) ? "PASS\n" : "FAIL\n");

    uart_write_flush();
    return (sw_pass && hw_pass) ? 0 : 1;
}
