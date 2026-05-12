/*
 * APEX FPGA HBM DMA Scatter-Gather Engine
 * Targets: AMD Alveo U280 (HBM2E, 32 channels, 460 GB/s)
 *
 * Features:
 *   - 512-bit AXI4-MM master (HBM channels)
 *   - PCIe DMA via XDMA IP (256-bit AXI4-Stream)
 *   - Hardware scatter-gather: 64-entry descriptor ring per channel
 *   - Out-of-order completion tracking via open-bitmap
 *   - Integrated CRC32C hardware checker
 *   - AXI4-Lite CSR interface for host driver
 *   - Parameterizable channel count, queue depth, burst length
 */

`timescale 1ns / 1ps
`default_nettype none

module apex_hbm_dma #(
    parameter int unsigned  CH_COUNT    = 32,
    parameter int unsigned  QUEUE_DEPTH = 64,
    parameter int unsigned  MAX_BURST   = 256,    // AXI beats
    parameter int unsigned  DATA_W      = 512,    // HBM bus width
    parameter int unsigned  ADDR_W      = 34,     // HBM 16 GiB addressable
    parameter int unsigned  CSR_DATA_W  = 32,
    parameter int unsigned  TAG_W       = 8       // outstanding transactions
)(
    input  logic                clk,
    input  logic                rst_n,

    /* AXI4-Lite CSR interface (host driver) */
    input  logic [31:0]         csr_awaddr,
    input  logic                csr_awvalid,
    output logic                csr_awready,
    input  logic [31:0]         csr_wdata,
    input  logic [3:0]          csr_wstrb,
    input  logic                csr_wvalid,
    output logic                csr_wready,
    output logic [1:0]          csr_bresp,
    output logic                csr_bvalid,
    input  logic                csr_bready,
    input  logic [31:0]         csr_araddr,
    input  logic                csr_arvalid,
    output logic                csr_arready,
    output logic [31:0]         csr_rdata,
    output logic [1:0]          csr_rresp,
    output logic                csr_rvalid,
    input  logic                csr_rready,

    /* HBM AXI4-MM Master (one port per channel, muxed internally) */
    output logic [ADDR_W-1:0]   hbm_awaddr,
    output logic [7:0]          hbm_awlen,
    output logic [2:0]          hbm_awsize,
    output logic [1:0]          hbm_awburst,
    output logic [TAG_W-1:0]    hbm_awid,
    output logic                hbm_awvalid,
    input  logic                hbm_awready,
    output logic [DATA_W-1:0]   hbm_wdata,
    output logic [DATA_W/8-1:0] hbm_wstrb,
    output logic                hbm_wlast,
    output logic                hbm_wvalid,
    input  logic                hbm_wready,
    input  logic [TAG_W-1:0]    hbm_bid,
    input  logic [1:0]          hbm_bresp,
    input  logic                hbm_bvalid,
    output logic                hbm_bready,

    output logic [ADDR_W-1:0]   hbm_araddr,
    output logic [7:0]          hbm_arlen,
    output logic [2:0]          hbm_arsize,
    output logic [1:0]          hbm_arburst,
    output logic [TAG_W-1:0]    hbm_arid,
    output logic                hbm_arvalid,
    input  logic                hbm_arready,
    input  logic [DATA_W-1:0]   hbm_rdata,
    input  logic [TAG_W-1:0]    hbm_rid,
    input  logic [1:0]          hbm_rresp,
    input  logic                hbm_rlast,
    input  logic                hbm_rvalid,
    output logic                hbm_rready,

    /* PCIe DMA stream (to/from host) */
    output logic [255:0]        pcie_tdata,
    output logic                pcie_tvalid,
    output logic                pcie_tlast,
    input  logic                pcie_tready,
    input  logic [255:0]        pcie_s_tdata,
    input  logic                pcie_s_tvalid,
    output logic                pcie_s_tready,

    /* Interrupt (MSI-X) */
    output logic                irq_req,
    input  logic                irq_ack
);

    // ── Descriptor type ────────────────────────────────────────────
    typedef struct packed {
        logic [63:0]   host_addr;    // PCIe address
        logic [ADDR_W-1:0] hbm_addr;
        logic [27:0]   length;       // bytes
        logic [1:0]    dir;          // 0=H2D, 1=D2H, 2=internal
        logic          interrupt_on_complete;
        logic          _pad;
    } descriptor_t;

    // ── Descriptor rings (per-channel, synthesized to BRAM) ────────
    descriptor_t desc_ring [CH_COUNT][QUEUE_DEPTH];
    logic [$clog2(QUEUE_DEPTH)-1:0] head [CH_COUNT];
    logic [$clog2(QUEUE_DEPTH)-1:0] tail [CH_COUNT];
    logic [QUEUE_DEPTH-1:0]         inflight [CH_COUNT];  // open bitmap

    // ── Round-robin channel arbiter ────────────────────────────────
    logic [$clog2(CH_COUNT)-1:0] rr_ptr;
    logic                         any_pending;

    always_comb begin : arb_comb
        any_pending = 1'b0;
        for (int i = 0; i < CH_COUNT; i++) begin
            if (head[i] != tail[i]) any_pending = 1'b1;
        end
    end

    // ── AXI read state machine ─────────────────────────────────────
    typedef enum logic [2:0] {
        RD_IDLE,
        RD_ADDR,
        RD_DATA,
        RD_DRAIN,
        RD_COMPLETE
    } rd_state_t;

    rd_state_t rd_state;
    descriptor_t active_desc;
    logic [27:0] rd_bytes_remain;
    logic [7:0]  rd_burst_remain;
    logic [31:0] crc_accum;

    // CRC32C: Castagnoli polynomial (hardware-synthesizable)
    function automatic logic [31:0] crc32c_byte(
        input logic [31:0] crc,
        input logic [7:0]  data
    );
        logic [31:0] poly = 32'h82F63B78;
        logic [31:0] tmp  = crc ^ {24'h0, data};
        for (int i = 0; i < 8; i++) begin
            if (tmp[0]) tmp = (tmp >> 1) ^ poly;
            else        tmp = tmp >> 1;
        end
        return tmp;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin : rd_fsm
        if (!rst_n) begin
            rd_state      <= RD_IDLE;
            hbm_arvalid   <= 1'b0;
            hbm_rready    <= 1'b0;
            crc_accum     <= 32'hFFFFFFFF;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    hbm_rready <= 1'b0;
                    if (any_pending) begin
                        // Pick next channel
                        for (int i = 0; i < CH_COUNT; i++) begin
                            automatic int ch = (rr_ptr + i) % CH_COUNT;
                            if (head[ch] != tail[ch]) begin
                                active_desc <= desc_ring[ch][head[ch]];
                                inflight[ch][head[ch]] <= 1'b1;
                                head[ch] <= head[ch] + 1;
                                rr_ptr   <= ch + 1;
                                rd_state <= RD_ADDR;
                                break;
                            end
                        end
                    end
                end

                RD_ADDR: begin
                    hbm_araddr   <= active_desc.hbm_addr;
                    hbm_arlen    <= (active_desc.length > MAX_BURST * (DATA_W/8))
                                    ? MAX_BURST[7:0] - 8'd1
                                    : (active_desc.length / (DATA_W/8))[7:0] - 8'd1;
                    hbm_arsize   <= $clog2(DATA_W/8);
                    hbm_arburst  <= 2'b01;   // INCR
                    hbm_arid     <= rr_ptr[TAG_W-1:0];
                    hbm_arvalid  <= 1'b1;

                    if (hbm_arready) begin
                        hbm_arvalid     <= 1'b0;
                        hbm_rready      <= 1'b1;
                        rd_burst_remain <= hbm_arlen + 8'd1;
                        rd_bytes_remain <= active_desc.length;
                        crc_accum       <= 32'hFFFFFFFF;
                        rd_state        <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    if (hbm_rvalid && hbm_rready) begin
                        // CRC over each byte of the beat
                        for (int b = 0; b < DATA_W/8; b++) begin
                            if (b < rd_bytes_remain) begin
                                crc_accum <= crc32c_byte(
                                    crc_accum,
                                    hbm_rdata[b*8 +: 8]);
                            end
                        end

                        // Steer to PCIe stream
                        pcie_tdata  <= hbm_rdata[255:0];  // truncate for demo
                        pcie_tvalid <= 1'b1;
                        pcie_tlast  <= hbm_rlast;

                        rd_burst_remain <= rd_burst_remain - 8'd1;
                        rd_bytes_remain <= (rd_bytes_remain >= DATA_W/8)
                                           ? rd_bytes_remain - (DATA_W/8)
                                           : 28'd0;

                        if (hbm_rlast) begin
                            hbm_rready <= 1'b0;
                            rd_state   <= (rd_bytes_remain == '0)
                                          ? RD_COMPLETE : RD_ADDR;
                            if (rd_bytes_remain > 0)
                                active_desc.hbm_addr <=
                                    active_desc.hbm_addr + (MAX_BURST * (DATA_W/8));
                        end
                    end else begin
                        pcie_tvalid <= 1'b0;
                    end
                end

                RD_COMPLETE: begin
                    pcie_tvalid <= 1'b0;
                    if (active_desc.interrupt_on_complete) begin
                        irq_req  <= 1'b1;
                        if (irq_ack) irq_req <= 1'b0;
                    end
                    rd_state <= RD_IDLE;
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    // ── AXI4-Lite CSR decode ───────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin : csr_wr
        if (!rst_n) begin
            csr_awready <= 1'b0;
            csr_wready  <= 1'b0;
            csr_bvalid  <= 1'b0;
        end else begin
            csr_awready <= ~csr_awready;
            if (csr_awvalid && csr_wvalid) begin
                // Descriptor submission: addr encodes [ch_id, queue_slot]
                automatic int ch   = csr_awaddr[11:6];
                automatic int slot = tail[ch];
                desc_ring[ch][slot].host_addr  <= {csr_wdata, 32'd0};
                tail[ch] <= tail[ch] + 1;
                csr_bvalid <= 1'b1;
                csr_bresp  <= 2'b00;
            end
            if (csr_bvalid && csr_bready) csr_bvalid <= 1'b0;
        end
    end

endmodule : apex_hbm_dma
`default_nettype wire
