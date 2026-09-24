// SPDX-License-Identifier: GPL-3.0-or-later
// Frame-ahead layer framebuffer in DDR3, shared by the C169 road and C355 sprite
// compositors. The layer's scanline engine composes a whole frame ahead of the
// raster into a 4-slot compose ring (the engine's own RAM, read here through
// ring_addr/ring_q); this module streams each finished slot to a double-buffered
// framebuffer in DDR3 through the MiSTer DDRAM port, fetches each line back one
// raster line ahead into a 2-line MLAB display ring, and sequences the banks.
//
// Why: some scenes cost several scanline budgets on a few lines (the desert
// wipe's horizon puts every pixel in a different ROZ tile: 15,087 clk for one
// line; sprite pile-ups reach 7,500-13,000 clk) while the frame as a whole fits
// (road 691k of 838k clk, sprites ~340k). No line-ring depth absorbs a 131-line
// deficit; a frame period does. The layer lags the raster-composed tile layer
// by one frame (16.6 ms), invisible in motion.
//
// Pixel format: 16 bits per pixel, encoded/decoded by the layer (pix_in from the
// ring entry, pix_out to the display). 4 pixels per 64-bit word, 72 words per
// 288-pixel line, line stride 1 KB, bank stride 256 KB, two banks per layer at
// byte 0x30000000 + LAYER<<19 (512 KB per layer).
//
// Engine handshake: line_req/line_y = "compose this line into slot line_y[1:0]
// now" (held until line_ack); line_done = the slot holds the finished line.
// Frame sequencing: the display bank flips at the start of line 263 when the
// other bank holds a COMPLETE newer frame ("fresh" and no composition in
// flight); the next frame's composition starts right after a flip into the bank
// not on screen. A frame that overruns the frame period is not flipped in
// half-done: the raster repeats the previous complete frame (one dropped
// frame of this layer, invisible next to a hole-riddled one) and the skipped
// flip is counted as 224 missed lines so the probes and sweep tools keep their
// meaning. A line is fetched only once the writer has completed it (safety).
// DDRAM_CLK is clk: single clock domain. All bursts are 24 words (3 per line).
module fl_layer_fb #(parameter LAYER=0)(
    input wire clk,reset,line_start,input wire [8:0] x,y,
    // engine
    output wire line_req,output wire [8:0] line_y,input wire line_ack,line_done,engine_idle,
    input wire [8:0] draw_y,          // line the engine is composing (for lead)
    output wire [10:0] ring_addr,input wire [15:0] ring_q,   // {slot,x}, registered read
    output wire compose_bank,display_bank,next_display_bank,
    output wire composing,            // a frame's composition is in flight
    output wire [2:0] lead,
    // display
    output wire [15:0] pix_out,output reg display_valid,
    output reg [31:0] missed_lines,
    // MiSTer DDRAM port
    output reg ddr_rd,ddr_we,output reg [28:0] ddr_addr,output wire [7:0] ddr_burstcnt,
    output reg [63:0] ddr_din,output wire [7:0] ddr_be,
    input wire ddr_busy,input wire [63:0] ddr_dout,input wire ddr_dout_ready
);
    // ---------------------------------------------------------------- sequencing
    reg [8:0] compose_line;      // next line of the frame being composed (224 = done)
    reg compose_bank_r,display_bank_r,fresh,frame_pending,composing_r;
    assign composing=composing_r;
    reg [3:0] slot_full;         // ring slot holds a finished line the writer has not drained
    reg [7:0] slot_y[0:3];
    reg [3:0] slot_bank;
    reg [8:0] written_upto[0:1]; // lines of the bank the writer has completed (composed in order)
    wire [8:0] next_line=y==9'd263 ? 9'd0 : y+1'b1;
    wire flip=line_start && next_line==9'd263;
    assign compose_bank=compose_bank_r;
    assign display_bank=display_bank_r;
    assign next_display_bank=(fresh && !composing_r) ? ~display_bank_r : display_bank_r;
    assign line_req=composing_r && compose_line<9'd224 && !slot_full[compose_line[1:0]];
    assign line_y=compose_line;
    // Arbiter urgency: composing ahead -> 2 while behind the proportional schedule
    // (compose_line < 224/264 * raster line) else 7; composing the frame on screen
    // (late) -> lines of slack as before.
    wire late=composing_r && compose_bank_r==display_bank_r;
    wire [8:0] behind_lines=draw_y>=y ? draw_y-y : draw_y+9'd264-y;
    wire [8:0] schedule_target=y-{3'd0,y[8:3]};
    assign lead=!composing_r ? 3'd7 :
                late ? (engine_idle ? 3'd7 : (behind_lines>9'd7 ? 3'd7 : behind_lines[2:0])) :
                (compose_line<schedule_target ? 3'd2 : 3'd7);
    // ---------------------------------------------------------------- writer
    localparam W_IDLE=0,W_PIX=1,W_LAST=2,W_WRITE=3,W_ACK=4;
    reg [2:0] wstate;
    reg [1:0] wslot;
    reg [8:0] wx;
    reg [63:0] word;
    reg ring_q_valid;
    assign ring_addr={wslot,wx};
    // ---------------------------------------------------------------- reader
    localparam R_IDLE=0,R_ISSUE=1,R_ACCEPT=2,R_DATA=3;
    reg [1:0] rstate;
    reg [1:0] rburst;
    reg [4:0] rcount;
    reg [6:0] rword;
    reg rslot,rbank;
    reg [7:0] rline;
    reg [1:0] slot_ok;
    wire fetch_go=line_start && (next_line<9'd223 || next_line==9'd263);
    wire [8:0] fetch_line=next_line==9'd263 ? 9'd0 : next_line+1'b1;
    wire fetch_bank=next_line==9'd263 ? next_display_bank : display_bank_r;
    wire fetch_ok=fetch_line<written_upto[fetch_bank];
    assign ddr_burstcnt=ddr_we ? 8'd1 : 8'd24;
    assign ddr_be=8'hff;
    wire [3:0] layer_id=LAYER;
    (* ramstyle = "MLAB, no_rw_check" *) reg [63:0] disp_ring[0:255];
    reg [63:0] disp_q;
    assign pix_out=disp_q[16*x[1:0]+:16];
    integer bi;
    // Returned words are registered once (data + ring address) before the MLAB write: the
    // direct path from the HPS bridge's DDRAM_DOUT register into the MLAB write port had
    // -0.010 ns hold at the slow 100C corner (PATREON build 5eb2b78b).
    reg [63:0] dout_q;
    reg [7:0] waddr_q;
    reg dout_v;
    always @(posedge clk) begin
        disp_q<=disp_ring[{y[0],x[8:2]}];
        dout_q<=ddr_dout;waddr_q<={rslot,rword};dout_v<=rstate==R_DATA && ddr_dout_ready;
        if(dout_v) disp_ring[waddr_q]<=dout_q;
    end
    always @(posedge clk) begin
        if(reset) begin
            compose_line<=0;compose_bank_r<=0;display_bank_r<=0;fresh<=0;frame_pending<=0;composing_r<=0;
            slot_full<=0;slot_bank<=0;for(bi=0;bi<4;bi=bi+1) slot_y[bi]<=0;
            written_upto[0]<=0;written_upto[1]<=0;
            wstate<=W_IDLE;wslot<=0;wx<=0;word<=0;ring_q_valid<=0;
            rstate<=R_IDLE;rburst<=0;rcount<=0;rword<=0;rslot<=0;rbank<=0;rline<=0;slot_ok<=0;
            ddr_rd<=0;ddr_we<=0;ddr_addr<=0;ddr_din<=0;
            display_valid<=0;missed_lines<=0;
        end else begin
            if(flip) begin
                frame_pending<=1;
                if(fresh && !composing_r) begin display_bank_r<=~display_bank_r;fresh<=0;end
                else if(fresh) missed_lines<=missed_lines+32'd224;   // late frame: repeat the previous one
            end
            // ---- engine handshake (a new frame needs a free bank: none while a
            // complete frame is still waiting for its flip)
            if(composing_r && compose_line==9'd224) composing_r<=0;
            else if(!composing_r && frame_pending && !fresh) begin
                composing_r<=1;frame_pending<=0;fresh<=1;
                compose_bank_r<=~display_bank_r;compose_line<=0;
                written_upto[~display_bank_r]<=0;
            end
            if(line_ack) compose_line<=compose_line+1'b1;
            if(line_done) begin
                slot_full[draw_y[1:0]]<=1;slot_y[draw_y[1:0]]<=draw_y[7:0];slot_bank[draw_y[1:0]]<=compose_bank_r;
            end
            // ---- writer: drain the oldest full slot, 4 ring pixels -> one 64-bit word
            ring_q_valid<=wstate==W_PIX;
            if(ring_q_valid) word<={ring_q,word[63:16]};
            case(wstate)
                W_IDLE:if(slot_full[wslot]) begin wx<=0;wstate<=W_PIX;end
                W_PIX:begin wx<=wx+1'b1;if(wx[1:0]==2'd3) wstate<=W_LAST;end
                W_LAST:wstate<=W_WRITE;
                W_WRITE:if(rstate==R_IDLE && !fetch_go) begin
                    ddr_we<=1;ddr_din<=word;
                    ddr_addr<={4'b0011,5'd0,layer_id,slot_bank[wslot],slot_y[wslot],wx[8:2]-7'd1};
                    wstate<=W_ACK;
                end
                W_ACK:if(!ddr_busy) begin
                    ddr_we<=0;
                    if(wx==9'd288) begin
                        slot_full[wslot]<=0;written_upto[slot_bank[wslot]]<={1'b0,slot_y[wslot]}+9'd1;
                        wslot<=wslot+1'b1;wstate<=W_IDLE;
                    end else wstate<=W_PIX;
                end
                default:wstate<=W_IDLE;
            endcase
            // ---- reader: line n+1 of the display bank during line n, 3 bursts of 24
            if(fetch_go) begin
                slot_ok[fetch_line[0]]<=0;
                if(fetch_ok) begin
                    rslot<=fetch_line[0];rbank<=fetch_bank;rline<=fetch_line[7:0];
                    rburst<=0;rword<=0;rstate<=R_ISSUE;
                end
            end
            case(rstate)
                R_ISSUE:if(!ddr_we) begin
                    ddr_rd<=1;ddr_addr<={4'b0011,5'd0,layer_id,rbank,rline,rword};rcount<=5'd24;rstate<=R_ACCEPT;
                end
                R_ACCEPT:if(!ddr_busy) begin ddr_rd<=0;rstate<=R_DATA;end
                R_DATA:if(ddr_dout_ready) begin
                    rword<=rword+1'b1;rcount<=rcount-1'b1;
                    if(rcount==5'd1) begin
                        if(rburst==2'd2) begin slot_ok[rslot]<=1;rstate<=R_IDLE;end
                        else begin rburst<=rburst+1'b1;rstate<=R_ISSUE;end
                    end
                end
                default:;
            endcase
            // ---- raster: a line shows only if its slot holds the complete line
            if(line_start) begin
                display_valid<=next_line<9'd224 && slot_ok[next_line[0]];
                if(next_line<9'd224 && !slot_ok[next_line[0]]) missed_lines<=missed_lines+1'b1;
            end
        end
    end
endmodule
