// MAC Unit v2 for Croc User Domain
// Register-mapped INT8 SIMD-4 Multiply-Accumulate Unit (4-lane dot product)
//
// This is a SIMD-4 successor to mac_unit.sv (which stays as-is). It is a
// separate module (mac_unit2) so the scalar version remains available; swap it
// in at user_domain.sv and add it to Bender.yml when ready.
//
// WHY SIMD-4: the scalar MAC carried ONE INT8 operand pair per 32-bit OBI write
// and did acc += A*B. It was correct but NOT a speedup vs a real RV32M core:
// with one CPU store (~3 cyc) per MAC, a hardware mul+add is about as cheap as
// the store that feeds it (measured: HW 749 cyc vs SW 595-667 on the 8->4->2
// MLP). The only way to win is MORE WORK PER OBI TRANSACTION. A 32-bit wdata
// holds FOUR packed INT8 values, so one MAC4 write does a 4-lane dot product:
// acc += a0*w0 + a1*w1 + a2*w2 + a3*w3 -> 4 MACs/store.
//
// A 4-wide dot needs 8 bytes (4 activations + 4 weights) but wdata is only 32
// bits, so the four ACTIVATIONS are held RESIDENT in a register (one ACT write)
// and each MAC4 write delivers the four WEIGHTS. Loading the activations once
// and streaming weight quads costs 0.5 stores/MAC after the activation load
// (vs 1 store/MAC before). Capturing cross-neuron activation reuse (a full
// activation RF instead of a single resident quad) is the next step and layers
// directly on top of this.
//
// PIPELINED DATAPATH (2 stages) -- same shape that closed IHP130 timing for the
// scalar MAC (a single-cycle mul+add was THE chip critical path at -0.36 ns
// post-CTS). Each stage carries multiply XOR add, never both:
//   Stage 1 (multiply): register the four 8x8 products into prod_q[k], raise
//                       acc_en_q. (multiplies only)
//   Stage 2 (accumulate): next cycle  accumulator_q += (prod_q[0]+..+prod_q[3]).
//                       (adds only: a 2-level adder tree + the 32-bit accumulate)
// Throughput is still 1 MAC4/cycle; cost is +1 cycle of latency before a term
// reaches accumulator_q. RESULT reads FORWARD the in-flight dot-product sum
// (acc_view = accumulator_q + pending sum) so RESULT is correct >=1 cycle after
// the last MAC4 write, exactly as the scalar version guaranteed. That forward
// path is adds-only and off the tight accumulate loop.
//
// Register Map (word-addressed, byte offset):
//   0x00  ACT    [W]   wdata[7:0]=a0, [15:8]=a1, [23:16]=a2, [31:24]=a3
//                      (signed INT8) -> load the 4 resident activations
//   0x04  MAC4   [W]   wdata[7:0]=w0, [15:8]=w1, [23:16]=w2, [31:24]=w3
//                      (signed INT8) -> acc += a0*w0+a1*w1+a2*w2+a3*w3 (atomic)
//   0x08  CLEAR  [W]   any write clears the accumulator to 0
//   0x0C  RESULT [R]   32-bit signed accumulator value
//
// Usage:
//   1. Write CLEAR once to zero the accumulator.
//   2. Per quad: write ACT with {a3,a2,a1,a0}, then MAC4 with {w3,w2,w1,w0}.
//      (Activations stay resident, so several MAC4 writes can reuse one ACT
//       load if they share the same activation quad.)
//   3. Read RESULT.

`include "common_cells/registers.svh"

module mac_unit2 #(
  parameter obi_pkg::obi_cfg_t ObiCfg  = obi_pkg::ObiDefaultConfig,
  parameter type               obi_req_t = logic,
  parameter type               obi_rsp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o
);

  // -------------------------------------------------------------------------
  // 4 registers -> 2 bits of word address (byte address bits [3:2] select reg)
  // -------------------------------------------------------------------------
  localparam int unsigned AddrBits = 2;
  localparam int unsigned Lanes    = 4;

  // -------------------------------------------------------------------------
  // Internal state
  // -------------------------------------------------------------------------
  logic signed [31:0] accumulator_q, accumulator_d;

  // Resident activations: four packed signed INT8, loaded by an ACT write.
  logic [31:0] act_q, act_d;

  // Stage-1 pipeline registers: four 8x8 signed products (each 16b) + a
  // "accumulate me next cycle" flag.  Packed into one 64b vector for the FF.
  logic [Lanes*16-1:0] prod_q,   prod_d;
  logic                acc_en_q, acc_en_d;

  // -------------------------------------------------------------------------
  // OBI handshake & response pipeline registers.
  // gnt is combinational (always accept), rvalid is registered (1-cycle
  // latency) to match the SbrObiCfg convention used by all other peripherals.
  // -------------------------------------------------------------------------
  logic                         rvalid_d, rvalid_q;
  logic [ObiCfg.IdWidth-1:0]    rid_d,    rid_q;
  logic [ObiCfg.DataWidth-1:0]  rdata_d,  rdata_q;
  logic                         err_d,    err_q;

  // -------------------------------------------------------------------------
  // Address decode
  // -------------------------------------------------------------------------
  logic [AddrBits-1:0] word_addr;
  assign word_addr = obi_req_i.a.addr[AddrBits+1:2]; // bits [3:2]

  // -------------------------------------------------------------------------
  // Decoded write strobes (combinational, from the current OBI beat)
  // -------------------------------------------------------------------------
  logic act_fire, mac_fire, clear_fire;
  assign act_fire   = obi_req_i.req && obi_req_i.a.we && (word_addr == 2'b00);
  assign mac_fire   = obi_req_i.req && obi_req_i.a.we && (word_addr == 2'b01);
  assign clear_fire = obi_req_i.req && obi_req_i.a.we && (word_addr == 2'b10);

  // -------------------------------------------------------------------------
  // Resident activation register: hold unless an ACT write replaces all four.
  // -------------------------------------------------------------------------
  assign act_d = act_fire ? obi_req_i.a.wdata : act_q;

  // -------------------------------------------------------------------------
  // Stage 1: multiply.  For each lane, multiply the resident activation by the
  // weight carried in the current MAC4 write.  prod_d is computed every cycle
  // but only consumed when acc_en_q is set next cycle.
  // -------------------------------------------------------------------------
  always_comb begin
    logic signed [7:0] a_lane, w_lane;
    for (int unsigned k = 0; k < Lanes; k++) begin
      a_lane = signed'(act_q[8*k +: 8]);
      w_lane = signed'(obi_req_i.a.wdata[8*k +: 8]);
      prod_d[16*k +: 16] = a_lane * w_lane;   // signed 8x8 -> signed 16
    end
  end
  assign acc_en_d = mac_fire;

  // -------------------------------------------------------------------------
  // Adder tree (adds only): sum the four pipelined 16b products, each sign-
  // extended to 32b.  Used by both the accumulate stage and the read-forward
  // path, so it is written once here.
  // -------------------------------------------------------------------------
  logic signed [31:0] dot_sum;
  always_comb begin
    dot_sum = '0;
    for (int unsigned k = 0; k < Lanes; k++)
      dot_sum += 32'(signed'(prod_q[16*k +: 16]));
  end

  // -------------------------------------------------------------------------
  // Stage 2: accumulate.  Fold the pending dot-product (from the prior MAC4
  // write) into the accumulator. CLEAR has priority and takes effect with
  // 1-cycle latency, discarding any pending product (CLEAR is ordered after the
  // preceding MAC4 and zeroes the result regardless).
  // -------------------------------------------------------------------------
  always_comb begin
    accumulator_d = accumulator_q;                    // default: hold
    if (clear_fire) begin
      accumulator_d = 32'h0;                          // clear wins
    end else if (acc_en_q) begin
      accumulator_d = accumulator_q + dot_sum;
    end
  end

  // -------------------------------------------------------------------------
  // Read-forwarded accumulator view: committed accumulator plus the in-flight
  // dot-product not yet written back. Keeps RESULT correct even if a read lands
  // the cycle immediately after the last MAC4 write. Adds only, off the loop.
  // -------------------------------------------------------------------------
  logic signed [31:0] acc_view;
  assign acc_view = acc_en_q ? (accumulator_q + dot_sum) : accumulator_q;

  // -------------------------------------------------------------------------
  // Read logic (combinational, feeds the OBI response pipeline)
  // -------------------------------------------------------------------------
  always_comb begin
    rdata_d = '0;
    err_d   = 1'b0;
    if (obi_req_i.req && !obi_req_i.a.we) begin
      unique case (word_addr)
        2'b11:   rdata_d = acc_view; // RESULT (forwarded)
        default: rdata_d = '0;       // ACT / MAC4 / CLEAR are write-only -> 0
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // OBI response assembly: gnt combinational, rvalid registered, aid -> rid
  // -------------------------------------------------------------------------
  assign rvalid_d = obi_req_i.req;
  assign rid_d    = obi_req_i.a.aid;

  always_comb begin
    obi_rsp_o         = '0;
    obi_rsp_o.gnt     = 1'b1;       // always ready to accept
    obi_rsp_o.rvalid  = rvalid_q;
    obi_rsp_o.r.rdata = rdata_q;
    obi_rsp_o.r.rid   = rid_q;
    obi_rsp_o.r.err   = err_q;
  end

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  `FF(accumulator_q, accumulator_d, '0, clk_i, rst_ni)
  `FF(act_q,         act_d,         '0, clk_i, rst_ni)
  `FF(prod_q,        prod_d,        '0, clk_i, rst_ni)
  `FF(acc_en_q,      acc_en_d,      '0, clk_i, rst_ni)
  `FF(rvalid_q,      rvalid_d,      '0, clk_i, rst_ni)
  `FF(rid_q,         rid_d,         '0, clk_i, rst_ni)
  `FF(rdata_q,       rdata_d,       '0, clk_i, rst_ni)
  `FF(err_q,         err_d,         '0, clk_i, rst_ni)

endmodule
