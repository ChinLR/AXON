// Copyright (c) 2026 ETH Zurich.
// Licensed under Solderpad Hardware License 0.51.

// nn_test.c — Minimal 2-layer INT8 MLP for Croc bring-up.

// 8 -> 4 -> 2 INT8 MLP forward pass with one hardcoded test input.
// Mirrors the accelerator's arithmetic pattern: INT8 * INT8 -> INT32
// accumulator, ReLU between layers, arithmetic right-shift and
// saturate back to INT8.

// Hand-computed expected output (verified in Python):
//     layer 1 acc          : [ 0, 15, -15, 15]
//     after ReLU + (>> 2)  : [ 0,  3,   0,  3]
//     layer 2 acc          : [ 6, -6]
//     final output         : [ 6, -6]

// Note on output: Croc's printf only supports %x. We use a local
// print_int helper (via putchar) for signed decimal output.

// Author: Li Ren, VLSI 2 Spring 2026.

#include <stdint.h>
#include "uart.h"
#include "print.h"
#include "config.h"

// --- Signed-decimal helper (Croc's printf only does %x) -------------------

static void print_int(int v) {
    if (v < 0) { putchar('-'); v = -v; }
    if (v == 0) { putchar('0'); return; }
    char buf[12];
    int n = 0;
    while (v > 0) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--)   putchar(buf[n]);
}

// --- The network ----------------------------------------------------------

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

// --- Cycle counter --------------------------------------------------------

static inline uint32_t read_mcycle(void) {
    uint32_t v;
    asm volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

// --- Forward pass --------------------------------------------------------

static int8_t relu_requantize(int32_t acc, int shift) {
    if (acc < 0) acc = 0;
    acc >>= shift;
    if (acc > 127) acc = 127;
    return (int8_t)acc;
}

static int8_t saturate_requantize(int32_t acc, int shift) {
    acc >>= shift;            // GCC: arithmetic shift on signed int32
    if (acc >  127) acc =  127;
    if (acc < -128) acc = -128;
    return (int8_t)acc;
}

// --- main ----------------------------------------------------------------

int main(void) {
    uart_init();

    printf("nn_test: 8 -> 4 -> 2 INT8 MLP\n");

    int8_t h[DIM_H];
    int8_t y[DIM_OUT];

    uint32_t t0 = read_mcycle();

    // Layer 1: 8 -> 4, ReLU + requantize
    for (int o = 0; o < DIM_H; ++o) {
        int32_t acc = 0;
        for (int i = 0; i < DIM_IN; ++i) {
            acc += (int32_t)w1[o * DIM_IN + i] * (int32_t)x_test[i];
        }
        h[o] = relu_requantize(acc, SHIFT_L1);
    }

    // Layer 2: 4 -> 2, signed saturate
    for (int o = 0; o < DIM_OUT; ++o) {
        int32_t acc = 0;
        for (int i = 0; i < DIM_H; ++i) {
            acc += (int32_t)w2[o * DIM_H + i] * (int32_t)h[i];
        }
        y[o] = saturate_requantize(acc, SHIFT_L2);
    }

    uint32_t t1 = read_mcycle();

    printf("h      = [");
    print_int(h[0]); printf(", ");
    print_int(h[1]); printf(", ");
    print_int(h[2]); printf(", ");
    print_int(h[3]); printf("]\n");

    printf("output = [");
    print_int(y[0]); printf(", ");
    print_int(y[1]); printf("]\n");

    printf("cycles = ");
    print_int((int)(t1 - t0));
    printf("\n");

    if (y[0] == 6 && y[1] == -6) {
        printf("PASS (expected [6, -6])\n");
    } else {
        printf("FAIL (expected [6, -6])\n");
    }

    uart_write_flush();
    return 0;
}
