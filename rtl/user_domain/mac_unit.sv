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
// Register Map (word-addressed, byte offset):
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
  // Write / accumulate logic (combinational next-state).
  // Each MAC write is self-contained: it accumulates onto the REGISTERED
  // accumulator using the operands from the SAME beat. A stream of MAC writes
  // (even 1 per cycle, back-to-back) chains correctly, because accumulator_q
  // is updated every cycle and there is no cross-transaction dependency.
  // -------------------------------------------------------------------------
  always_comb begin
    accumulator_d = accumulator_q; // default: hold
    if (obi_req_i.req && obi_req_i.a.we) begin
      unique case (word_addr)
        2'b00: begin // MAC: atomic multiply-accumulate
          accumulator_d = accumulator_q + (32'(op_a) * 32'(op_b));
        end
        2'b01: begin // CLEAR
          accumulator_d = 32'h0;
        end
        default: ; // RESULT (read-only) / unused: writes ignored
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Read logic (combinational, feeds the OBI response pipeline)
  // -------------------------------------------------------------------------
  always_comb begin
    rdata_d = '0;
    err_d   = 1'b0;
    if (obi_req_i.req && !obi_req_i.a.we) begin
      unique case (word_addr)
        2'b10:   rdata_d = accumulator_q; // RESULT
        default: rdata_d = '0;            // MAC / CLEAR are write-only -> read 0
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
  `FF(rvalid_q,      rvalid_d,      '0, clk_i, rst_ni)
  `FF(rid_q,         rid_d,         '0, clk_i, rst_ni)
  `FF(rdata_q,       rdata_d,       '0, clk_i, rst_ni)
  `FF(err_q,         err_d,         '0, clk_i, rst_ni)

endmodule
