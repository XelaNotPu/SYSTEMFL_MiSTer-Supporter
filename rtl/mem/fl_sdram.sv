// SPDX-License-Identifier: GPL-3.0-or-later
// 64 MiB x16 SDRAM controller, clocked at 100 MHz (clk2x = exactly 2x the 50 MHz
// core clock, same PLL). The request interface is driven by 50 MHz registers and
// read back by 50 MHz logic: inputs are simply sampled here, `ready` is held for
// TWO 100 MHz cycles so exactly one 50 MHz edge sees it, and rdata stays stable
// until the next transaction. RELEASE waits for the client to drop its request,
// so nothing is accepted twice. Timing recipe copied from the SUPER22/Genesis
// controller proven at 98-107 MHz on this board: CL2, tRCD 3 cycles, SDRAM_CLK
// forwarded by an ALTDDIO_OUT on clk2x (inverted), DQ taken through a plain
// posedge input register and consumed 4 cycles after the READ was registered.
// One aligned 32-bit operation at a time: BL2 reads, two single writes.
// Retain one open row per bank; writes retain independent halfword masks.
//
// Read-ahead block cache (bandwidth): a read MISS fetches the whole 16-byte
// (four 32-bit word) aligned block with the SAME trusted BL2 reads, all within
// the one already-open row, and stores it in a small direct-mapped buffer. The
// video engines fetch 2-4 sequential words per row (C123 tile = 2, C355 sprite
// = 4, C169 road), and the CPU reads sequentially too, so the follow-up words
// are served from the buffer with no further SDRAM access -- amortizing the
// per-word command overhead ~2-4x without touching the BL2/CAS/mask timing or
// the 32-bit request/data interface. Writes invalidate the matching buffer
// index. Everything outside the read path is byte-for-byte the prior controller.
module fl_sdram(
    input wire clk, reset,
    input wire req, write, input wire [25:0] addr,
    input wire [31:0] wdata, input wire [3:0] be,
    output reg ready, output reg [31:0] rdata,
    // The whole 16-byte aligned block the word came from, valid with rdata on
    // reads. The row-fetching video engines take a full row per transaction
    // from it (C169/C355 16 bytes, C123 8 bytes) instead of 2-4 word requests.
    output reg [127:0] rdata_wide,
    output reg initialized,
    output wire sd_clk, output wire sd_cke,
    output reg [12:0] sd_a, output reg [1:0] sd_ba,
    inout wire [15:0] sd_dq, output reg [1:0] sd_dqm,
    output wire sd_cs, sd_ras, sd_cas, sd_we
);
    localparam NOP=4'b0111, ACTIVE=4'b0011, READ=4'b0101,
        WRITE=4'b0100, PRE=4'b0010, REFRESH=4'b0001, MODE=4'b0000;
    reg [3:0] command;
    assign {sd_cs,sd_ras,sd_cas,sd_we}=command;
    // Simulation-only forwarded clock (the top level drives SDRAM_CLK through an
    // ALTDDIO_OUT register on clk2x for a deterministic clock-to-out).
    assign sd_clk=~clk;
    assign sd_cke=1;
    reg drive;
    reg [15:0] dq_out;
    // One direct input register per DQ pin permits I/O-register packing. Read
    // data is taken from dq_in one cycle after the pin (SUPER22 B_IOREG).
    reg [15:0] dq_in;
    always @(posedge clk) dq_in <= sd_dq;
    assign sd_dq=drive ? dq_out : 16'hzzzz;
    reg [4:0] state, next_state;
    reg [14:0] delay_count;
    // Pipelined block read: cycle counter within BURST (READs at 0/2/4/6, beats at 4..11).
    reg [3:0] bc;
    reg [9:0] refresh_count;
    reg refresh_due;
    reg [3:0] init_refresh;
    reg [25:0] a;
    // Open-row decision precomputed at accept (from the 50 MHz addr): the LOOKUP-cycle path
    // a[25] -> bank_row mux -> 13-bit compare -> sd_a missed the 10 ns period by 0.44 ns at 96%
    // density (release 19bf7f0). LOOKUP now only selects between registered results.
    reg row_hit,row_open;
    reg [31:0] data;
    reg [3:0] mask;
    reg wr, beat;
    reg [3:0] open_rows;
    reg [12:0] bank_row[0:3];
    // read-ahead block cache: 16 entries, indexed by a[7:4], one 16-byte block each.
    localparam RA_ENTRIES=16;
    // 16-entry tables belong in MLAB (LUT RAM): as M10K they cost ~5 blocks for 2 Kbit.
    (* ramstyle = "MLAB" *) reg [17:0] ra_tag[0:RA_ENTRIES-1];   // addr[25:8]
    reg        ra_valid[0:RA_ENTRIES-1];
    (* ramstyle = "MLAB" *) reg [127:0] ra_data[0:RA_ENTRIES-1]; // four 32-bit words (a[3:2] = 0..3)
    reg [1:0] req_word;  // a[3:2] of the requested word
    reg [127:0] block;   // block being assembled this miss
    integer ri;
    localparam START=0, INIT_PRE=1, INIT_REF=2, INIT_MODE=3, IDLE=4,
        COLUMN=5, NEXT_BEAT=7, CLOSE=8, FINISH=9, WAIT=10, RELEASE=11, ACTIVATE_ROW=13, REFRESH_RUN=14,
        BURST=16, FINISH2=17, LOOKUP=18;
    // Read-ahead lookup registers: IDLE reads the MLAB tables with the client's
    // address (a 50 MHz register) into these; LOOKUP compares and decides from
    // registered values only. The single-cycle form failed timing at 100 MHz
    // (50 MHz addr -> MLAB -> tag compare -> row decision -> sd_a: -1.6 ns).
    reg [17:0] tag_q;
    reg valid_q;
    reg [127:0] data_q;
    // 100 MHz cycle counts: tRFC 66 ns -> 7 waits, refresh every 7.49 us, 300 us power-up.
    localparam REFRESH_WAIT=7, REFRESH_INTERVAL=749, POWER_UP=30000;
    task wait_for(input [14:0] n, input [4:0] next);
        begin delay_count<=n-1'b1; next_state<=next; state<=WAIT; end
    endtask
    always @(posedge clk) begin
        command<=NOP; drive<=0; ready<=0;
        if(reset) begin
            initialized<=0; state<=START; delay_count<=POWER_UP;
            sd_a<=0; sd_ba<=0; sd_dqm<=0; drive<=0; row_hit<=0; row_open<=0;
            refresh_count<=0; refresh_due<=0; init_refresh<=0;open_rows<=0;
            for(ri=0;ri<RA_ENTRIES;ri=ri+1) ra_valid[ri]<=0;
        end else begin
            if(initialized) begin
                if(refresh_count==REFRESH_INTERVAL) begin refresh_count<=0; refresh_due<=1; end
                else refresh_count<=refresh_count+1'b1;
            end
            case(state)
                START:if(delay_count==0) state<=INIT_PRE; else delay_count<=delay_count-1'b1;
                INIT_PRE:begin command<=PRE; sd_a<=13'h400; wait_for(2,INIT_REF); end
                INIT_REF:begin
                    command<=REFRESH; init_refresh<=init_refresh+1'b1;
                    wait_for(REFRESH_WAIT,init_refresh==7 ? INIT_MODE : INIT_REF);
                end
                INIT_MODE:begin command<=MODE; sd_a<=13'h221; sd_ba<=0; wait_for(2,IDLE); end
                WAIT:if(delay_count==0) state<=next_state; else delay_count<=delay_count-1'b1;
                IDLE:begin
                    initialized<=1; sd_dqm<=0;
                    if(refresh_due) begin
                        if(|open_rows) begin
                            command<=PRE;sd_a<=13'h400;open_rows<=0;wait_for(2,REFRESH_RUN);
                        end else begin command<=REFRESH;refresh_due<=0;wait_for(REFRESH_WAIT,IDLE);end
                    end
                    else if(req) begin
                        a<=addr; data<=wdata; mask<=be; wr<=write; beat<=0;
                        req_word<=addr[3:2]; bc<=0;
                        row_open<=open_rows[addr[25:24]];
                        row_hit<=open_rows[addr[25:24]] && bank_row[addr[25:24]]==addr[23:11];
                        tag_q<=ra_tag[addr[7:4]]; valid_q<=ra_valid[addr[7:4]]; data_q<=ra_data[addr[7:4]];
                        state<=LOOKUP;
                    end
                end
                LOOKUP:begin
                    if(!wr && valid_q && tag_q==a[25:8]) begin
                        // read-ahead HIT: serve the word without any SDRAM access
                        rdata<=data_q[32*req_word+:32];rdata_wide<=data_q;
                        state<=FINISH;
                    end else begin
                        if(wr) ra_valid[a[7:4]]<=0;   // keep the cache coherent with writes
                        if(row_hit) state<=wr ? COLUMN : BURST;
                        else if(row_open) begin
                            command<=PRE;sd_ba<=a[25:24];sd_a<=0;
                            open_rows[a[25:24]]<=0;wait_for(2,ACTIVATE_ROW);
                        end else begin
                            command<=ACTIVE;sd_ba<=a[25:24];sd_a<=a[23:11];
                            open_rows[a[25:24]]<=1;bank_row[a[25:24]]<=a[23:11];
                            wait_for(2,wr ? COLUMN : BURST);
                        end
                    end
                end
                ACTIVATE_ROW:begin
                    command<=ACTIVE;sd_ba<=a[25:24];sd_a<=a[23:11];
                    open_rows[a[25:24]]<=1;bank_row[a[25:24]]<=a[23:11];wait_for(2,wr ? COLUMN : BURST);
                end
                REFRESH_RUN:begin command<=REFRESH;refresh_due<=0;wait_for(REFRESH_WAIT,IDLE);end
                COLUMN:begin
                    // Writes address the requested word (two single halfword WRITEs);
                    // reads never come here (BURST).
                    sd_a<={3'd0,a[10:4],a[3:2],beat}; sd_ba<=a[25:24];
                    command<=WRITE; drive<=1;
                    dq_out<=beat ? data[31:16] : data[15:0];
                    sd_dqm<=~(beat ? mask[3:2] : mask[1:0]);
                    // MiSTer XS/XS-D shares DQM with A11/A12. These
                    // address bits are unused for column commands, but
                    // retain their full row-address role during ACTIVE.
                    sd_a[12:11]<=~(beat ? mask[3:2] : mask[1:0]);
                    wait_for(2,NEXT_BEAT);
                end
                BURST:begin
                    // Pipelined block read: four BL2 READs issued two cycles apart within the
                    // open row (bc = 0,2,4,6). A READ registered at bc=k is on the pins during
                    // k+1, sampled by the device on its (inverted) clock; CL2 data is on the
                    // pins around k+3, lands in dq_in at k+3 and is consumed at k+4 (SUPER22:
                    // STATE_READY = READ + CL + 2). Beats therefore arrive at bc = 4..11;
                    // 16-byte block in 12 cycles at 100 MHz (6 core clocks).
                    if(!bc[0] && bc<4'd8) begin
                        command<=READ; sd_dqm<=0;
                        sd_a<={3'd0,a[10:4],bc[2:1],1'b0}; sd_ba<=a[25:24];
                    end
                    if(bc>=4'd4) block[16*(bc-4'd4)+:16]<=dq_in;
                    if(bc==4'd11) begin
                        // block complete (last beat is on dq_in now): fill the read-ahead cache
                        ra_data[a[7:4]]<={dq_in,block[111:0]};
                        ra_tag[a[7:4]]<=a[25:8];
                        ra_valid[a[7:4]]<=1;
                        rdata<=req_word==2'd3 ? {dq_in,block[111:96]} : block[32*req_word+:32];
                        rdata_wide<={dq_in,block[111:0]};
                        state<=FINISH;
                    end else bc<=bc+1'b1;
                end
                NEXT_BEAT:if(!beat) begin beat<=1; state<=COLUMN; end else state<=FINISH;
                CLOSE:begin command<=PRE; sd_a<=13'h400; wait_for(2,FINISH); end
                // ready is held for two 100 MHz cycles: exactly one 50 MHz edge samples it.
                FINISH:begin ready<=1; state<=FINISH2; end
                FINISH2:begin ready<=1; state<=RELEASE; end
                RELEASE:if(!req) state<=IDLE;
                default:state<=START;
            endcase
        end
    end
endmodule
