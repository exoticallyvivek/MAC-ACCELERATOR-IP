// ============================================================
// Module  : mac_system_top
// Desc    : MAC Accelerator IP - Top Level
//           AXI4-Lite slave + FIFO + 2×2 MAC Array + Output Regs
//           Complete data flow:
//           CPU → AXI → FIFO → MAC Array → Output Regs → CPU
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP | Sky130 130nm | OpenLane
// ============================================================
module mac_system_top (
    // ---- Global ----
    input  wire        ACLK,
    input  wire        ARESETN,

    // ---- AXI4-Lite Write Address ----
    input  wire [31:0] AWADDR,
    input  wire        AWVALID,
    output wire        AWREADY,

    // ---- AXI4-Lite Write Data ----
    input  wire [31:0] WDATA,
    input  wire [3:0]  WSTRB,
    input  wire        WVALID,
    output wire        WREADY,

    // ---- AXI4-Lite Write Response ----
    output wire [1:0]  BRESP,
    output wire        BVALID,
    input  wire        BREADY,

    // ---- AXI4-Lite Read Address ----
    input  wire [31:0] ARADDR,
    input  wire        ARVALID,
    output wire        ARREADY,

    // ---- AXI4-Lite Read Data ----
    output wire [31:0] RDATA,
    output wire [1:0]  RRESP,
    output wire        RVALID,
    input  wire        RREADY
);

    // ============================================================
    // Internal wires
    // ============================================================

    // AXI → Control FSM
    wire [15:0] axi_mac_A;
    wire [15:0] axi_mac_B;
    wire        axi_mac_start;
    wire        axi_mac_rst_acc;
    wire [1:0]  axi_mac_sel;

    // FIFO
    wire        fifo_wr_en;
    wire [31:0] fifo_wr_data;
    wire        fifo_rd_en;
    wire [31:0] fifo_rd_data;
    wire        fifo_full;
    wire        fifo_empty;
    wire        fifo_almost_full;
    wire        fifo_almost_empty;
    wire [4:0]  fifo_count;      // ADDR_BITS+1 = 5

    // MAC Array
    wire [15:0] mac_A_wire;
    wire [15:0] mac_B_wire;
    wire        mac_valid_in;
    wire [1:0]  mac_sel_wire;
    wire        mac_rst_acc_wire;
    wire [31:0] result_mac0, result_mac1, result_mac2, result_mac3;
    wire        valid_mac0,  valid_mac1,  valid_mac2,  valid_mac3;

    // Output register bank
    wire [31:0] orb_result0, orb_result1, orb_result2, orb_result3;
    wire        orb_done;

    // Status signals to AXI
    wire mac_busy;
    wire mac_done_sig;

    // ============================================================
    // Control FSM
    // Manages: FIFO writes from AXI, FIFO reads to MAC, busy/done
    // ============================================================
    localparam FSM_IDLE    = 3'd0;
    localparam FSM_PUSH    = 3'd1;
    localparam FSM_POP     = 3'd2;
    localparam FSM_COMPUTE = 3'd3;
    localparam FSM_DONE    = 3'd4;

    reg [2:0]  fsm_state;
    reg        busy_reg;
    reg        done_reg;
    reg [1:0]  mac_sel_reg;
    reg        fifo_rd_en_reg;
    reg        mac_valid_reg;

    assign mac_busy     = busy_reg;
    // DONE = result captured in output reg bank
    assign mac_done_sig = orb_done;
    assign fifo_rd_en   = fifo_rd_en_reg;
    assign mac_valid_in = mac_valid_reg;
    assign mac_sel_wire = mac_sel_reg;

    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            fsm_state      <= FSM_IDLE;
            busy_reg       <= 1'b0;
            done_reg       <= 1'b0;
            mac_sel_reg    <= 2'b00;
            fifo_rd_en_reg <= 1'b0;
            mac_valid_reg  <= 1'b0;
        end else begin
            case (fsm_state)
                // IDLE: wait for START pulse from AXI
                FSM_IDLE: begin
                    fifo_rd_en_reg <= 1'b0;
                    mac_valid_reg  <= 1'b0;
                    done_reg       <= 1'b0;
                    if (axi_mac_start) begin
                        busy_reg    <= 1'b1;
                        mac_sel_reg <= axi_mac_sel;
                        // FIFO write happens combinatorially via fifo_wr_en
                        // Wait 2 cycles for FIFO to register data then pop
                        fsm_state   <= FSM_PUSH;
                    end
                end

                // PUSH: wait 2 cycles for FIFO to have valid data
                FSM_PUSH: begin
                    if (!fifo_empty) begin
                        fifo_rd_en_reg <= 1'b1;
                        fsm_state      <= FSM_COMPUTE;
                    end
                end

                // COMPUTE: rd_data valid next cycle, assert mac_valid
                FSM_COMPUTE: begin
                    fifo_rd_en_reg <= 1'b0;
                    mac_valid_reg  <= 1'b1;
                    fsm_state      <= FSM_POP;
                end

                // POP: deassert valid, check if more data in FIFO
                FSM_POP: begin
                    mac_valid_reg <= 1'b0;
                    if (!fifo_empty) begin
                        fifo_rd_en_reg <= 1'b1;
                        fsm_state      <= FSM_COMPUTE;
                    end else begin
                        fsm_state <= FSM_DONE;
                    end
                end

                // DONE: clear busy, wait for orb_done from output reg bank
                FSM_DONE: begin
                    busy_reg  <= 1'b0;
                    done_reg  <= 1'b1;
                    fsm_state <= FSM_IDLE;
                end

                default: fsm_state <= FSM_IDLE;
            endcase
        end
    end

    // ============================================================
    // FIFO write: when AXI asserts start, pack A+B → FIFO
    // ============================================================
    assign fifo_wr_en   = axi_mac_start && !fifo_full;
    assign fifo_wr_data = {axi_mac_A, axi_mac_B};

    // ============================================================
    // MAC inputs from FIFO output
    // ============================================================
    assign mac_A_wire   = fifo_rd_data[31:16];
    assign mac_B_wire   = fifo_rd_data[15:0];
    assign mac_rst_acc_wire = axi_mac_rst_acc;

    // ============================================================
    // Block instantiations
    // ============================================================

    // ---- AXI4-Lite Slave ----
    axi4_lite_slave u_axi (
        .ACLK          (ACLK),
        .ARESETN       (ARESETN),
        .AWADDR        (AWADDR),
        .AWVALID       (AWVALID),
        .AWREADY       (AWREADY),
        .WDATA         (WDATA),
        .WSTRB         (WSTRB),
        .WVALID        (WVALID),
        .WREADY        (WREADY),
        .BRESP         (BRESP),
        .BVALID        (BVALID),
        .BREADY        (BREADY),
        .ARADDR        (ARADDR),
        .ARVALID       (ARVALID),
        .ARREADY       (ARREADY),
        .RDATA         (RDATA),
        .RRESP         (RRESP),
        .RVALID        (RVALID),
        .RREADY        (RREADY),
        .mac_A         (axi_mac_A),
        .mac_B         (axi_mac_B),
        .mac_start     (axi_mac_start),
        .mac_rst_acc   (axi_mac_rst_acc),
        .mac_sel       (axi_mac_sel),
        .result_mac0   (orb_result0),
        .result_mac1   (orb_result1),
        .result_mac2   (orb_result2),
        .result_mac3   (orb_result3),
        .mac_busy      (mac_busy),
        .mac_done      (mac_done_sig),
        .fifo_full     (fifo_full),
        .fifo_empty    (fifo_empty)
    );

    // ---- Sync FIFO ----
    sync_fifo #(
        .DEPTH     (16),
        .WIDTH     (32),
        .ADDR_BITS (4)
    ) u_fifo (
        .clk          (ACLK),
        .rst_n        (ARESETN),
        .wr_en        (fifo_wr_en),
        .wr_data      (fifo_wr_data),
        .rd_en        (fifo_rd_en),
        .rd_data      (fifo_rd_data),
        .full         (fifo_full),
        .empty        (fifo_empty),
        .almost_full  (fifo_almost_full),
        .almost_empty (fifo_almost_empty),
        .count        (fifo_count)
    );

    // ---- 2×2 MAC Array ----
    mac_array u_mac_array (
        .clk          (ACLK),
        .rst_n        (ARESETN),
        .A            (mac_A_wire),
        .B            (mac_B_wire),
        .valid_in     (mac_valid_in),
        .mac_sel      (mac_sel_wire),
        .rst_acc      (mac_rst_acc_wire),
        .result_mac0  (result_mac0),
        .result_mac1  (result_mac1),
        .result_mac2  (result_mac2),
        .result_mac3  (result_mac3),
        .valid_mac0   (valid_mac0),
        .valid_mac1   (valid_mac1),
        .valid_mac2   (valid_mac2),
        .valid_mac3   (valid_mac3)
    );

    // ---- Output Register Bank ----
    output_reg_bank u_orb (
        .clk          (ACLK),
        .rst_n        (ARESETN),
        .result_mac0  (result_mac0),
        .result_mac1  (result_mac1),
        .result_mac2  (result_mac2),
        .result_mac3  (result_mac3),
        .valid_mac0   (valid_mac0),
        .valid_mac1   (valid_mac1),
        .valid_mac2   (valid_mac2),
        .valid_mac3   (valid_mac3),
        .reg_mac0     (orb_result0),
        .reg_mac1     (orb_result1),
        .reg_mac2     (orb_result2),
        .reg_mac3     (orb_result3),
        .done_flag    (orb_done)
    );

endmodule

// ============================================================
// Module  : axi4_lite_slave
// Desc    : AXI4-Lite Slave Controller
//           Bridges CPU ↔ MAC System
//           5 channels: AW, W, B, AR, R
//           Register map:
//             0x00 → Operand A   (W)
//             0x04 → Operand B   (W)
//             0x08 → Control     (W) [START|RESET|MAC_SEL[1:0]]
//             0x0C → Result MAC0 (R)
//             0x10 → Result MAC1 (R)
//             0x14 → Result MAC2 (R)
//             0x18 → Result MAC3 (R)
//             0x1C → Status      (R) [FIFO_EMPTY|FIFO_FULL|DONE|BUSY]
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================
module axi4_lite_slave (
    // ---- Global ----
    input  wire        ACLK,
    input  wire        ARESETN,    // Active LOW

    // ---- Write Address Channel (AW) ----
    input  wire [31:0] AWADDR,
    input  wire        AWVALID,
    output reg         AWREADY,

    // ---- Write Data Channel (W) ----
    input  wire [31:0] WDATA,
    input  wire [3:0]  WSTRB,
    input  wire        WVALID,
    output reg         WREADY,

    // ---- Write Response Channel (B) ----
    output reg  [1:0]  BRESP,
    output reg         BVALID,
    input  wire        BREADY,

    // ---- Read Address Channel (AR) ----
    input  wire [31:0] ARADDR,
    input  wire        ARVALID,
    output reg         ARREADY,

    // ---- Read Data Channel (R) ----
    output reg  [31:0] RDATA,
    output reg  [1:0]  RRESP,
    output reg         RVALID,
    input  wire        RREADY,

    // ---- MAC System Interface ----
    output reg  [15:0] mac_A,
    output reg  [15:0] mac_B,
    output reg         mac_start,
    output reg         mac_rst_acc,
    output reg  [1:0]  mac_sel,
    // Inputs from MAC system
    input  wire [31:0] result_mac0,
    input  wire [31:0] result_mac1,
    input  wire [31:0] result_mac2,
    input  wire [31:0] result_mac3,
    input  wire        mac_busy,
    input  wire        mac_done,
    input  wire        fifo_full,
    input  wire        fifo_empty
);

    // ============================================================
    // Internal registers
    // ============================================================
    reg [31:0] reg_A;       // 0x00
    reg [31:0] reg_B;       // 0x04
    reg [31:0] reg_ctrl;    // 0x08
    // 0x0C-0x18: read from mac output ports
    // 0x1C: status (built from signals)

    // ============================================================
    // AW + W FSM states
    // ============================================================
    localparam WR_IDLE   = 2'd0;
    localparam WR_ADDR   = 2'd1;
    localparam WR_DATA   = 2'd2;
    localparam WR_RESP   = 2'd3;

    reg [1:0]  wr_state;
    reg [31:0] wr_addr_latch;

    // ============================================================
    // AR + R FSM states
    // ============================================================
    localparam RD_IDLE   = 2'd0;
    localparam RD_ADDR   = 2'd1;
    localparam RD_DATA   = 2'd2;

    reg [1:0]  rd_state;
    reg [31:0] rd_addr_latch;

    // ============================================================
    // WRITE FSM
    // ============================================================
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            wr_state      <= WR_IDLE;
            AWREADY       <= 1'b0;
            WREADY        <= 1'b0;
            BVALID        <= 1'b0;
            BRESP         <= 2'b00;
            wr_addr_latch <= 32'd0;
            reg_A         <= 32'd0;
            reg_B         <= 32'd0;
            reg_ctrl      <= 32'd0;
            mac_A         <= 16'd0;
            mac_B         <= 16'd0;
            mac_start     <= 1'b0;
            mac_rst_acc   <= 1'b0;
            mac_sel       <= 2'b00;
        end else begin
            // Default pulse signals
            mac_start   <= 1'b0;
            mac_rst_acc <= 1'b0;

            case (wr_state)
                WR_IDLE: begin
                    AWREADY <= 1'b1;
                    WREADY  <= 1'b0;
                    BVALID  <= 1'b0;
                    if (AWVALID && AWREADY) begin
                        wr_addr_latch <= AWADDR;
                        AWREADY       <= 1'b0;
                        WREADY        <= 1'b1;
                        wr_state      <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (WVALID && WREADY) begin
                        WREADY <= 1'b0;
                        // ---- Write to register map ----
                        case (wr_addr_latch[4:0])
                            5'h00: begin
                                reg_A <= WDATA;
                                mac_A <= WDATA[15:0];
                            end
                            5'h04: begin
                                reg_B <= WDATA;
                                mac_B <= WDATA[15:0];
                            end
                            5'h08: begin
                                reg_ctrl    <= WDATA;
                                mac_start   <= WDATA[0];
                                mac_rst_acc <= WDATA[1];
                                mac_sel     <= WDATA[3:2];
                            end
                            default: ; // ignore writes to read-only regs
                        endcase
                        // Send OKAY response
                        BRESP  <= 2'b00;
                        BVALID <= 1'b1;
                        wr_state <= WR_RESP;
                    end
                end

                WR_RESP: begin
                    if (BVALID && BREADY) begin
                        BVALID   <= 1'b0;
                        wr_state <= WR_IDLE;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // ============================================================
    // READ FSM
    // ============================================================
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            rd_state      <= RD_IDLE;
            ARREADY       <= 1'b0;
            RVALID        <= 1'b0;
            RDATA         <= 32'd0;
            RRESP         <= 2'b00;
            rd_addr_latch <= 32'd0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    ARREADY <= 1'b1;
                    RVALID  <= 1'b0;
                    if (ARVALID && ARREADY) begin
                        rd_addr_latch <= ARADDR;
                        ARREADY       <= 1'b0;
                        rd_state      <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    RVALID <= 1'b1;
                    RRESP  <= 2'b00;
                    // ---- Read from register map ----
                    case (rd_addr_latch[4:0])
                        5'h00: RDATA <= reg_A;
                        5'h04: RDATA <= reg_B;
                        5'h08: RDATA <= reg_ctrl;
                        5'h0C: RDATA <= result_mac0;
                        5'h10: RDATA <= result_mac1;
                        5'h14: RDATA <= result_mac2;
                        5'h18: RDATA <= result_mac3;
                        5'h1C: RDATA <= {28'd0,
                                         fifo_empty,
                                         fifo_full,
                                         mac_done,
                                         mac_busy};
                        default: RDATA <= 32'hDEAD_BEEF;
                    endcase

                    if (RVALID && RREADY) begin
                        RVALID   <= 1'b0;
                        rd_state <= RD_IDLE;
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule





// ============================================================
// Module  : mac_array
// Desc    : 2×2 MAC Array - 4 parallel mac_unit instances
//           MAC0 MAC1
//           MAC2 MAC3
//           All receive same A,B but accumulate independently
//           MAC SELECT: control which MAC gets valid_in
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================
module mac_array (
    input  wire        clk,
    input  wire        rst_n,
    // Operands
    input  wire [15:0] A,
    input  wire [15:0] B,
    // Control
    input  wire        valid_in,
    input  wire [1:0]  mac_sel,    // 00=MAC0, 01=MAC1, 10=MAC2, 11=MAC3
    input  wire        rst_acc,    // Broadcast clear all accumulators
    // Results
    output wire [31:0] result_mac0,
    output wire [31:0] result_mac1,
    output wire [31:0] result_mac2,
    output wire [31:0] result_mac3,
    output wire        valid_mac0,
    output wire        valid_mac1,
    output wire        valid_mac2,
    output wire        valid_mac3
);

    // ---- MAC select decoder ----
    wire en0 = valid_in & (mac_sel == 2'b00);
    wire en1 = valid_in & (mac_sel == 2'b01);
    wire en2 = valid_in & (mac_sel == 2'b10);
    wire en3 = valid_in & (mac_sel == 2'b11);

    // ---- MAC0 ----
    mac_unit u_mac0 (
        .clk          (clk),
        .rst_n        (rst_n),
        .rst_acc      (rst_acc),
        .valid_in     (en0),
        .A            (A),
        .B            (B),
        .result       (result_mac0),
        .result_valid (valid_mac0)
    );

    // ---- MAC1 ----
    mac_unit u_mac1 (
        .clk          (clk),
        .rst_n        (rst_n),
        .rst_acc      (rst_acc),
        .valid_in     (en1),
        .A            (A),
        .B            (B),
        .result       (result_mac1),
        .result_valid (valid_mac1)
    );

    // ---- MAC2 ----
    mac_unit u_mac2 (
        .clk          (clk),
        .rst_n        (rst_n),
        .rst_acc      (rst_acc),
        .valid_in     (en2),
        .A            (A),
        .B            (B),
        .result       (result_mac2),
        .result_valid (valid_mac2)
    );

    // ---- MAC3 ----
    mac_unit u_mac3 (
        .clk          (clk),
        .rst_n        (rst_n),
        .rst_acc      (rst_acc),
        .valid_in     (en3),
        .A            (A),
        .B            (B),
        .result       (result_mac3),
        .result_valid (valid_mac3)
    );

endmodule




// ============================================================
// Module  : mac_unit
// Desc    : 5-Stage Pipelined 16×16 Signed MAC
//           Stage 1 : Input register
//           Stage 2 : Booth encoder  (booth_encoder.v)
//           Stage 3 : Wallace L1+L2  (wallace_stage3)
//           Stage 4 : Wallace L3+CPA (wallace_stage4)
//           Stage 5 : Accumulator    (accumulator.v)
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================
module mac_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rst_acc,    // Clear accumulator
    input  wire        valid_in,   // Input pair valid
    input  wire [15:0] A,          // Multiplicand (signed)
    input  wire [15:0] B,          // Multiplier   (signed)
    output wire [31:0] result,     // MAC output
    output wire        result_valid
);

    // ============================================================
    // STAGE 1 - Input Register
    // ============================================================
    reg [15:0] s1_A, s1_B;
    reg        s1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_A     <= 16'd0;
            s1_B     <= 16'd0;
            s1_valid <= 1'b0;
        end else begin
            s1_A     <= A;
            s1_B     <= B;
            s1_valid <= valid_in;
        end
    end

    // ============================================================
    // STAGE 2 - Booth Encoder
    // ============================================================
    wire [31:0] s2_pp0, s2_pp1, s2_pp2;
    wire [31:0] s2_pp3, s2_pp4, s2_pp5;
    wire [31:0] s2_pp6, s2_pp7, s2_pp8;
    wire [31:0] s2_A_out;
    wire        s2_valid;

    booth_encoder u_booth (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (s1_valid),
        .A         (s1_A),
        .B         (s1_B),
        .pp0       (s2_pp0), .pp1(s2_pp1), .pp2(s2_pp2),
        .pp3       (s2_pp3), .pp4(s2_pp4), .pp5(s2_pp5),
        .pp6       (s2_pp6), .pp7(s2_pp7), .pp8(s2_pp8),
        .A_reg_out (s2_A_out),
        .valid_out (s2_valid)
    );

    // ============================================================
    // STAGE 3 - Wallace Tree Level 1 + Level 2
    // ============================================================
    wire [31:0] s3_ws0, s3_wc0, s3_ws1, s3_wc1;
    wire [31:0] s3_A_out;
    wire        s3_valid;

    wallace_stage3 u_wl3 (
        .clk       (clk),
        .rst_n     (rst_n),
        .pp0       (s2_pp0), .pp1(s2_pp1), .pp2(s2_pp2),
        .pp3       (s2_pp3), .pp4(s2_pp4), .pp5(s2_pp5),
        .pp6       (s2_pp6), .pp7(s2_pp7), .pp8(s2_pp8),
        .A_in      (s2_A_out),
        .valid_in  (s2_valid),
        .w_s0      (s3_ws0), .w_c0(s3_wc0),
        .w_s1      (s3_ws1), .w_c1(s3_wc1),
        .A_out     (s3_A_out),
        .valid_out (s3_valid)
    );

    // ============================================================
    // STAGE 4 - Wallace Tree Level 3 + CPA
    // ============================================================
    wire [31:0] s4_product;
    wire [31:0] s4_A_out;
    wire        s4_valid;

    wallace_stage4 u_wl4 (
        .clk       (clk),
        .rst_n     (rst_n),
        .w_s0      (s3_ws0), .w_c0(s3_wc0),
        .w_s1      (s3_ws1), .w_c1(s3_wc1),
        .A_in      (s3_A_out),
        .valid_in  (s3_valid),
        .product   (s4_product),
        .A_out     (s4_A_out),
        .valid_out (s4_valid)
    );

    // ============================================================
    // STAGE 5 - Accumulator + Output Register
    // ============================================================
    accumulator u_acc (
        .clk          (clk),
        .rst_n        (rst_n),
        .rst_acc      (rst_acc),
        .product      (s4_product),
        .valid_in     (s4_valid),
        .result       (result),
        .result_valid (result_valid)
    );

endmodule




// ============================================================
// Module  : booth_encoder
// Desc    : Signed 16×16 Partial Product Generator (Stage 2)
//           valid_in registered pipeline, computes only when valid
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================
module booth_encoder (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [15:0] A,
    input  wire [15:0] B,
    output reg  [31:0] pp0, pp1, pp2, pp3,
    output reg  [31:0] pp4, pp5, pp6, pp7, pp8,
    output reg  [31:0] A_reg_out,
    output reg         valid_out
);
    wire signed [31:0] A_ext = {{16{A[15]}}, A};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pp0<=0;pp1<=0;pp2<=0;pp3<=0;pp4<=0;
            pp5<=0;pp6<=0;pp7<=0;pp8<=0;
            A_reg_out<=0; valid_out<=0;
        end else begin
            valid_out <= valid_in;
            A_reg_out <= A_ext;
            pp8 <= 32'd0;
            if (valid_in) begin
                pp0 <= B[0] ? (A_ext<<<0)  : 32'sd0;
                pp1 <= B[1] ? (A_ext<<<1)  : 32'sd0;
                pp2 <= B[2] ? (A_ext<<<2)  : 32'sd0;
                pp3 <= B[3] ? (A_ext<<<3)  : 32'sd0;
                pp4 <= B[4] ? (A_ext<<<4)  : 32'sd0;
                pp5 <= B[5] ? (A_ext<<<5)  : 32'sd0;
                pp6 <= B[6] ? (A_ext<<<6)  : 32'sd0;
                pp7 <= (B[7]  ?(A_ext<<<7) :32'sd0)
                     + (B[8]  ?(A_ext<<<8) :32'sd0)
                     + (B[9]  ?(A_ext<<<9) :32'sd0)
                     + (B[10] ?(A_ext<<<10):32'sd0)
                     + (B[11] ?(A_ext<<<11):32'sd0)
                     + (B[12] ?(A_ext<<<12):32'sd0)
                     + (B[13] ?(A_ext<<<13):32'sd0)
                     + (B[14] ?(A_ext<<<14):32'sd0)
                     + (B[15] ?-(A_ext<<<15):32'sd0);
            end else begin
                pp0<=0;pp1<=0;pp2<=0;pp3<=0;
                pp4<=0;pp5<=0;pp6<=0;pp7<=0;
            end
        end
    end
endmodule


// ============================================================
// Module  : wallace_tree
// Desc    : Wallace Tree CSA Reducer
//           9 partial products → 2 (sum + carry) → CPA → 32b
//           Split across Stage 3 (L1+L2) and Stage 4 (L3+CPA)
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================

// ---- Full Adder primitive ----
module fa_cell (
    input  wire a, b, cin,
    output wire sum, cout
);
    assign sum  = a ^ b ^ cin;
    assign cout = (a & b) | (b & cin) | (a & cin);
endmodule

// ---- Half Adder primitive ----
module ha_cell (
    input  wire a, b,
    output wire sum, cout
);
    assign sum  = a ^ b;
    assign cout = a & b;
endmodule

// ============================================================
// CSA 3:2 compressor (32-bit wide)
// ============================================================
module csa_32 (
    input  wire [31:0] a, b, c,
    output wire [31:0] sum,
    output wire [31:0] carry
);
    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : csa_bits
            fa_cell fa (
                .a(a[i]), .b(b[i]), .cin(c[i]),
                .sum(sum[i]), .cout(carry[i])
            );
        end
    endgenerate
endmodule

// ============================================================
// Stage 3: Wallace Level 1 + Level 2
// Input  : 9 partial products (pp0..pp8)
// Output : 4 intermediate values (s0,c0,s1,c1) + pipeline regs
// ============================================================
module wallace_stage3 (
    input  wire        clk,
    input  wire        rst_n,
    // 9 partial products from Stage 2
    input  wire [31:0] pp0, pp1, pp2,
    input  wire [31:0] pp3, pp4, pp5,
    input  wire [31:0] pp6, pp7, pp8,
    input  wire [31:0] A_in,
    input  wire        valid_in,
    // Outputs to Stage 4
    output reg  [31:0] w_s0, w_c0,
    output reg  [31:0] w_s1, w_c1,
    output reg  [31:0] A_out,
    output reg         valid_out
);

    // ---- Level 1: 3 CSAs → reduce 9 to 6 ----
    wire [31:0] l1_s0, l1_c0;  // CSA(pp0,pp1,pp2)
    wire [31:0] l1_s1, l1_c1;  // CSA(pp3,pp4,pp5)
    wire [31:0] l1_s2, l1_c2;  // CSA(pp6,pp7,pp8)

    csa_32 csa_l1_0 (.a(pp0), .b(pp1), .c(pp2), .sum(l1_s0), .carry(l1_c0));
    csa_32 csa_l1_1 (.a(pp3), .b(pp4), .c(pp5), .sum(l1_s1), .carry(l1_c1));
    csa_32 csa_l1_2 (.a(pp6), .b(pp7), .c(pp8), .sum(l1_s2), .carry(l1_c2));

    // After L1: 6 values = {l1_s0, l1_c0<<1, l1_s1, l1_c1<<1, l1_s2, l1_c2<<1}
    // (carry shift by 1 is implicit in positional weight)

    // ---- Level 2: 2 CSAs → reduce 6 to 4 ----
    wire [31:0] l2_s0, l2_c0;  // CSA(l1_s0, l1_c0<<1, l1_s1)
    wire [31:0] l2_s1, l2_c1;  // CSA(l1_c1<<1, l1_s2, l1_c2<<1)

    csa_32 csa_l2_0 (
        .a(l1_s0),
        .b({l1_c0[30:0], 1'b0}),  // carry shift left by 1
        .c(l1_s1),
        .sum(l2_s0), .carry(l2_c0)
    );
    csa_32 csa_l2_1 (
        .a({l1_c1[30:0], 1'b0}),
        .b(l1_s2),
        .c({l1_c2[30:0], 1'b0}),
        .sum(l2_s1), .carry(l2_c1)
    );

    // ---- Pipeline register at end of Stage 3 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_s0 <= 32'd0; w_c0 <= 32'd0;
            w_s1 <= 32'd0; w_c1 <= 32'd0;
            A_out <= 32'd0;
            valid_out <= 1'b0;
        end else begin
            w_s0 <= l2_s0;
            w_c0 <= {l2_c0[30:0], 1'b0};
            w_s1 <= l2_s1;
            w_c1 <= {l2_c1[30:0], 1'b0};
            A_out <= A_in;
            valid_out <= valid_in;
        end
    end

endmodule

// ============================================================
// Stage 4: Wallace Level 3 + CPA
// Input  : 4 values (s0,c0,s1,c1)
// Output : 32-bit product (pipelined)
// ============================================================
module wallace_stage4 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] w_s0, w_c0,
    input  wire [31:0] w_s1, w_c1,
    input  wire [31:0] A_in,
    input  wire        valid_in,
    output reg  [31:0] product,
    output reg  [31:0] A_out,
    output reg         valid_out
);

    // ---- Level 3: 1 CSA → reduce 4 to 3 ----
    wire [31:0] l3_s, l3_c;
    csa_32 csa_l3 (
        .a(w_s0), .b(w_c0), .c(w_s1),
        .sum(l3_s), .carry(l3_c)
    );

    // After L3: 3 values = l3_s, l3_c<<1, w_c1
    // One more CSA to get to 2
    wire [31:0] l4_s, l4_c;
    csa_32 csa_l4 (
        .a(l3_s),
        .b({l3_c[30:0], 1'b0}),
        .c(w_c1),
        .sum(l4_s), .carry(l4_c)
    );

    // ---- CPA: Ripple Carry Adder (32+1 bit) ----
    // For Sky130 area efficiency; replace with CLA for timing
    wire [32:0] cpa_result;
    assign cpa_result = {1'b0, l4_s} + {1'b0, {l4_c[30:0], 1'b0}};

    // ---- Pipeline register at end of Stage 4 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product   <= 32'd0;
            A_out     <= 32'd0;
            valid_out <= 1'b0;
        end else begin
            product   <= cpa_result[31:0];
            A_out     <= A_in;
            valid_out <= valid_in;
        end
    end

endmodule







// ============================================================
// Module  : accumulator
// Desc    : Stage 5 - Accumulate product + hold output
//           acc = acc + product (when valid)
//           Reset acc on rst_acc signal
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================
module accumulator (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rst_acc,    // Clear accumulator (from control)
    input  wire [31:0] product,    // From Stage 4
    input  wire        valid_in,   // Product valid
    output reg  [31:0] result,     // Accumulated result
    output reg         result_valid
);

    // ---- Saturating accumulator (64-bit internal, truncate to 32) ----
    // For full precision use 48-bit; 32-bit shown for cell budget
    reg [31:0] acc_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg      <= 32'd0;
            result       <= 32'd0;
            result_valid <= 1'b0;
        end else if (rst_acc) begin
            acc_reg      <= 32'd0;
            result       <= 32'd0;
            result_valid <= 1'b0;
        end else begin
            // result_valid is a 1-cycle pulse only when new data arrives
            if (valid_in) begin
                acc_reg      <= acc_reg + product;
                result       <= acc_reg + product;
                result_valid <= 1'b1;
            end else begin
                // Hold result value but drop valid
                result_valid <= 1'b0;
            end
        end
    end

endmodule





// ============================================================
// Module  : sync_fifo
// Desc    : Synchronous FIFO - 16 entries × 32-bit
//           Stores packed {A[15:0], B[15:0]} pairs
//           Flags: FULL, EMPTY, ALMOST_FULL, ALMOST_EMPTY
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================
module sync_fifo #(
    parameter DEPTH     = 16,
    parameter WIDTH     = 32,
    parameter ADDR_BITS = 4    // log2(DEPTH)
)(
    input  wire             clk,
    input  wire             rst_n,
    // Write port
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    // Read port
    input  wire             rd_en,
    output reg  [WIDTH-1:0] rd_data,
    // Status flags
    output wire             full,
    output wire             empty,
    output wire             almost_full,   // 1 slot left
    output wire             almost_empty,  // 1 entry left
    // Count
    output wire [ADDR_BITS:0] count
);

    // ---- Storage ----
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // ---- Pointers ----
    reg [ADDR_BITS:0] wr_ptr;  // extra bit for full/empty detect
    reg [ADDR_BITS:0] rd_ptr;

    // ---- Status ----
    assign count        = wr_ptr - rd_ptr;
    assign full         = (count == DEPTH);
    assign empty        = (count == 0);
    assign almost_full  = (count == DEPTH - 1);
    assign almost_empty = (count == 1);

    // ---- Write logic ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
               wr_ptr <= 0;
               mem[0]<=0;mem[1]<=0;mem[2]<=0;mem[3]<=0;
               mem[4]<=0;mem[5]<=0;mem[6]<=0;mem[7]<=0;
               mem[8]<=0;mem[9]<=0;mem[10]<=0;mem[11]<=0;
               mem[12]<=0;mem[13]<=0;mem[14]<=0;mem[15]<=0;
        end else if (wr_en && !full) begin
            mem[wr_ptr[ADDR_BITS-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // ---- Read logic ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= 0;
            rd_data <= {WIDTH{1'b0}};
        end else if (rd_en && !empty) begin
            rd_data <= mem[rd_ptr[ADDR_BITS-1:0]];
            rd_ptr  <= rd_ptr + 1;
        end
    end

endmodule




// ============================================================
// Module  : output_reg_bank
// Desc    : Holds 4 MAC results stable until CPU reads via AXI
//           Captures result on valid pulse from each MAC
//           Clears on rst_n or explicit clear
// Author  : Vivek Singh | Nirma University
// Project : MAC Accelerator IP
// ============================================================
module output_reg_bank (
    input  wire        clk,
    input  wire        rst_n,
    // Inputs from MAC array
    input  wire [31:0] result_mac0,
    input  wire [31:0] result_mac1,
    input  wire [31:0] result_mac2,
    input  wire [31:0] result_mac3,
    input  wire        valid_mac0,
    input  wire        valid_mac1,
    input  wire        valid_mac2,
    input  wire        valid_mac3,
    // Stable outputs to AXI
    output reg  [31:0] reg_mac0,
    output reg  [31:0] reg_mac1,
    output reg  [31:0] reg_mac2,
    output reg  [31:0] reg_mac3,
    // DONE flag: all 4 results captured
    output reg         done_flag
);

    reg mac0_done, mac1_done, mac2_done, mac3_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_mac0   <= 32'd0;
            reg_mac1   <= 32'd0;
            reg_mac2   <= 32'd0;
            reg_mac3   <= 32'd0;
            mac0_done  <= 1'b0;
            mac1_done  <= 1'b0;
            mac2_done  <= 1'b0;
            mac3_done  <= 1'b0;
            done_flag  <= 1'b0;
        end else begin
            // Capture each MAC result on valid pulse
            if (valid_mac0) begin
                reg_mac0  <= result_mac0;
                mac0_done <= 1'b1;
            end
            if (valid_mac1) begin
                reg_mac1  <= result_mac1;
                mac1_done <= 1'b1;
            end
            if (valid_mac2) begin
                reg_mac2  <= result_mac2;
                mac2_done <= 1'b1;
            end
            if (valid_mac3) begin
                reg_mac3  <= result_mac3;
                mac3_done <= 1'b1;
            end

            // DONE = at least one result captured this cycle
            done_flag <= valid_mac0 | valid_mac1 | valid_mac2 | valid_mac3;
        end
    end

endmodule



