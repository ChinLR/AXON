// MAC Unit for Croc User Domain
// Register-mapped INT8 x INT8 -> INT32 Multiply-Accumulate Unit
//
// Register Map (word-addressed, byte offset):
//   0x00  OPERAND_A  [W]   lower 8 bits = signed operand A
//   0x04  OPERAND_B  [W]   lower 8 bits = signed operand B
//   0x08  CONTROL    [W]   bit[0] = accumulate, bit[1] = clear
//   0x0C  RESULT     [R]   32-bit signed accumulator value
//
// Operation sequence:
//   1. Write OPERAND_A
//   2. Write OPERAND_B
//   3. Write CONTROL with bit[0]=1 to trigger acc += A*B
//      Write CONTROL with bit[1]=1 to clear accumulator
//      Both bits can be set simultaneously: clear happens first, then accumulate

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
  // Local address width: we only need 4 registers -> 2 bits of word address
  // -------------------------------------------------------------------------
  localparam int unsigned AddrBits = 2; // bits [3:2] of byte address select reg

  // -------------------------------------------------------------------------
  // Internal registers
  // -------------------------------------------------------------------------
  logic signed [7:0]  operand_a_q, operand_a_d;
  logic signed [7:0]  operand_b_q, operand_b_d;
  logic signed [31:0] accumulator_q, accumulator_d;

  // -------------------------------------------------------------------------
  // OBI handshake & pipeline registers
  // We must delay gnt->rvalid by one cycle (combinational gnt, registered rvalid)
  // to match the SbrObiCfg latency convention used by all other peripherals.
  // -------------------------------------------------------------------------
  logic                          rvalid_d, rvalid_q;
  logic [ObiCfg.IdWidth-1:0]    rid_d,    rid_q;
  logic [ObiCfg.DataWidth-1:0]  rdata_d,  rdata_q;
  logic                          err_d,    err_q;

  // -------------------------------------------------------------------------
  // Address decoding
  // -------------------------------------------------------------------------
  logic [AddrBits-1:0] word_addr;
  assign word_addr = obi_req_i.a.addr[AddrBits+1:2]; // bits [3:2]

  // -------------------------------------------------------------------------
  // Register write logic (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    // Default: hold values
    operand_a_d   = operand_a_q;
    operand_b_d   = operand_b_q;
    accumulator_d = accumulator_q;

    if (obi_req_i.req && obi_req_i.a.we) begin
      unique case (word_addr)
        2'b00: begin // 0x00 OPERAND_A
          operand_a_d = signed'(obi_req_i.a.wdata[7:0]);
        end
        2'b01: begin // 0x04 OPERAND_B
          operand_b_d = signed'(obi_req_i.a.wdata[7:0]);
        end
        2'b10: begin // 0x08 CONTROL
          // Clear has priority, then accumulate
          // bit[1] = clear, bit[0] = accumulate
          if (obi_req_i.a.wdata[1]) begin
            // Clear first
            accumulator_d = 32'h0;
          end
          if (obi_req_i.a.wdata[0]) begin
            // Accumulate: use the NEW operand values if written this same cycle,
            // otherwise use the latched values.
            // Since operand_a_d/b_d already reflect this cycle's write (above),
            // we use those.
            accumulator_d = (obi_req_i.a.wdata[1] ? 32'h0 : accumulator_q)
                          + (32'(signed'(operand_a_d)) * 32'(signed'(operand_b_d)));
          end
        end
        default: ; // 0x0C RESULT is read-only, writes ignored
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Register read logic (combinational, feeds into OBI response pipeline)
  // -------------------------------------------------------------------------
  always_comb begin
    rdata_d = '0;
    err_d   = 1'b0;
    if (obi_req_i.req && !obi_req_i.a.we) begin
      unique case (word_addr)
        2'b00: rdata_d = 32'(signed'(operand_a_q));
        2'b01: rdata_d = 32'(signed'(operand_b_q));
        2'b10: rdata_d = '0;                        // CONTROL is write-only
        2'b11: rdata_d = accumulator_q;             // RESULT
        default: begin
          rdata_d = '0;
          err_d   = 1'b1;
        end
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // OBI response pipeline
  // gnt is combinational (always accept), rvalid is registered (1-cycle latency)
  // -------------------------------------------------------------------------
  assign rvalid_d           = obi_req_i.req;
  assign rid_d              = obi_req_i.a.aid;

  // OBI response assembly
  always_comb begin
    obi_rsp_o           = '0;
    obi_rsp_o.gnt       = 1'b1;       // always ready to accept
    obi_rsp_o.rvalid    = rvalid_q;
    obi_rsp_o.r.rdata   = rdata_q;
    obi_rsp_o.r.rid     = rid_q;
    obi_rsp_o.r.err     = err_q;
  end

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  `FF(operand_a_q,   operand_a_d,   '0, clk_i, rst_ni)
  `FF(operand_b_q,   operand_b_d,   '0, clk_i, rst_ni)
  `FF(accumulator_q, accumulator_d, '0, clk_i, rst_ni)
  `FF(rvalid_q,      rvalid_d,      '0, clk_i, rst_ni)
  `FF(rid_q,         rid_d,         '0, clk_i, rst_ni)
  `FF(rdata_q,       rdata_d,       '0, clk_i, rst_ni)
  `FF(err_q,         err_d,         '0, clk_i, rst_ni)

endmodule