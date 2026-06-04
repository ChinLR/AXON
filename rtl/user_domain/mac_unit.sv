// MAC Unit for Croc User Domain
// Register-mapped INT8 x INT8 -> INT32 Multiply-Accumulate Unit
//
// SINGLE-TRANSACTION MAC: the two operands AND the accumulate trigger are
// carried in ONE OBI write. The previous design used three separate writes
// (OPERAND_A, OPERAND_B, then CONTROL) and raced under back-to-back access:
// the accumulate trigger and the operand registers desynchronized, so the
// multiply paired operands from different terms (confirmed on waveform).
// Folding everything into one beat makes operand/trigger pairing atomic, so
// there is nothing left to skew at any access spacing (also survives obi_cut).
// Bonus: one store per MAC instead of three -> ~3x less inner-loop overhead.
//
// PIPELINED DATAPATH (2 stages): a smoke-test P&R run (IHP130, 100 MHz/10 ns)
// showed the single-cycle  acc += A*B  was THE chip critical path: the worst
// setup endpoint at every opt stage was i_mac_unit.accumulator_q_*reg/D
// (post-CTS WNS -0.36 ns, unrepairable after routing). The 8x8 multiply +
// 32-bit add + accumulate all sat in one combinational cloud. We now split it:
//   Stage 1 (multiply):   register the 8x8 product into prod_q, raise acc_en_q
//   Stage 2 (accumulate): next cycle   accumulator_q += prod_q
// Each stage carries only a multiply OR an add, not both. Throughput is still
// 1 MAC/cycle (proper pipeline); the only cost is +1 cycle of latency before a
// term reaches accumulator_q. To keep the exact "RESULT is correct >=1 cycle
// after the last write" guarantee the old design had, RESULT reads FORWARD the
// in-flight product (acc_view = accumulator_q + pending prod_q). That forward
// path is an add only (no multiply) and is off the tight accumulate loop.
//
// Register Map (word-addressed, byte offset)  -- UNCHANGED, SW driver unchanged:
//   0x00  MAC      [W]   wdata[7:0]  = signed operand A
//                        wdata[15:8] = signed operand B
//                        write performs (atomic):  accumulator += A * B
//   0x04  CLEAR    [W]   any write clears the accumulator to 0
//   0x08  RESULT   [R]   32-bit signed accumulator value
//
// Usage:
//   1. Write CLEAR once to zero the accumulator.
//   2. Write MAC with {B,A} packed  -> acc += A*B   (repeat per term).
//   3. Read RESULT.

`include "common_cells/registers.svh"

module mac_unit #(
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
  // 3 registers -> 2 bits of word address (byte address bits [3:2] select reg)
  // -------------------------------------------------------------------------
  localparam int unsigned AddrBits = 2;

  // -------------------------------------------------------------------------
  // Internal state
  // -------------------------------------------------------------------------
  logic signed [31:0] accumulator_q, accumulator_d;

  // Stage-1 pipeline registers (multiply result + "accumulate me next cycle").
  logic signed [15:0] prod_q,   prod_d;    // 8x8 signed product
  logic               acc_en_q, acc_en_d;  // prod_q is a valid pending term

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
  // Packed signed operands carried in the MAC write
  // -------------------------------------------------------------------------
  logic signed [7:0] op_a, op_b;
  assign op_a = signed'(obi_req_i.a.wdata[7:0]);
  assign op_b = signed'(obi_req_i.a.wdata[15:8]);

  // -------------------------------------------------------------------------
  // Decoded write strobes (combinational, from the current OBI beat)
  // -------------------------------------------------------------------------
  logic mac_fire, clear_fire;
  assign mac_fire   = obi_req_i.req && obi_req_i.a.we && (word_addr == 2'b00);
  assign clear_fire = obi_req_i.req && obi_req_i.a.we && (word_addr == 2'b01);

  // -------------------------------------------------------------------------
  // Stage 1: multiply.  Register the 8x8 product of the current MAC write and
  // flag it as a pending term for the accumulate stage next cycle. prod_d is
  // computed every cycle but only consumed when acc_en_q is set.
  // -------------------------------------------------------------------------
  assign prod_d   = op_a * op_b;  // signed 8x8 -> signed 16
  assign acc_en_d = mac_fire;

  // -------------------------------------------------------------------------
  // Stage 2: accumulate.  Each cycle, fold the pending product (from the prior
  // MAC write) into the accumulator. CLEAR has priority and takes effect with
  // 1-cycle latency, discarding any pending product (CLEAR is ordered after the
  // preceding MAC, and zeroes the result regardless).
  // -------------------------------------------------------------------------
  always_comb begin
    accumulator_d = accumulator_q;                       // default: hold
    if (clear_fire) begin
      accumulator_d = 32'h0;                             // clear wins
    end else if (acc_en_q) begin
      accumulator_d = accumulator_q + 32'(prod_q);       // 32'(signed) sign-extends
    end
  end

  // -------------------------------------------------------------------------
  // Read-forwarded accumulator view: committed accumulator plus the in-flight
  // product not yet written back. Keeps RESULT correct even if a read lands the
  // cycle immediately after the last MAC write (same guarantee as before the
  // pipeline). Add-only path (no multiply), off the accumulate loop.
  // -------------------------------------------------------------------------
  logic signed [31:0] acc_view;
  assign acc_view = acc_en_q ? (accumulator_q + 32'(prod_q)) : accumulator_q;

  // -------------------------------------------------------------------------
  // Read logic (combinational, feeds the OBI response pipeline)
  // -------------------------------------------------------------------------
  always_comb begin
    rdata_d = '0;
    err_d   = 1'b0;
    if (obi_req_i.req && !obi_req_i.a.we) begin
      unique case (word_addr)
        2'b10:   rdata_d = acc_view; // RESULT (forwarded)
        default: rdata_d = '0;       // MAC / CLEAR are write-only -> read 0
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
  `FF(prod_q,        prod_d,        '0, clk_i, rst_ni)
  `FF(acc_en_q,      acc_en_d,      '0, clk_i, rst_ni)
  `FF(rvalid_q,      rvalid_d,      '0, clk_i, rst_ni)
  `FF(rid_q,         rid_d,         '0, clk_i, rst_ni)
  `FF(rdata_q,       rdata_d,       '0, clk_i, rst_ni)
  `FF(err_q,         err_d,         '0, clk_i, rst_ni)

endmodule
