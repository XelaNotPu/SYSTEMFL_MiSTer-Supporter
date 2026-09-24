// SPDX-License-Identifier: GPL-3.0-or-later
// Two C169 layers compose into a tagged line ONE FRAME AHEAD of the raster,
// through the DDR3 layer framebuffer (fl_layer_fb, layer 0). A missed line is
// shown black, never as stale pixels.
//
// Why a framebuffer: at the horizon of a zoomed-out ROZ scene (Speed Racer's
// intro desert wipe) every pixel of a line lands in a different 16x16 tile, so a
// line costs ~288 random SDRAM reads = five scanline budgets even in isolation
// (replay of the t=88 dump: 15,087 clk for line 76 at latency 30; 131 lines of
// budget short over the frame at latency 60). No line-ring depth or cache can
// absorb that; spreading the layer's work over the whole frame period can
// (264 lines = 838k clk against 691k needed). The C169 walker is unchanged.
//
// The engine composes into a 4-slot ring (M10K: read-modify-write for the
// layer-0-over-layer-1 priority compare); fl_layer_fb drains the slots to DDR3
// and feeds the raster. Pixel packing: {valid,pri[3:0],color[2:0],px[7:0]}
// (pen = {2'b11,color,px}). The road layer lags the tile layer by one frame.
module fl_road_video(
    input wire clk,reset,line_start,input wire [8:0] x,y,
    input wire cpu_req,cpu_write,cpu_control,input wire [16:0] cpu_addr,
    input wire [31:0] cpu_data,input wire [3:0] cpu_be,
    output wire cpu_ready,output wire [31:0] cpu_q,
    output wire rom_req,output wire [25:0] rom_addr,
    input wire rom_ready,input wire [31:0] rom_data,input wire [127:0] rom_data_wide,
    output wire [12:0] pen,output wire [3:0] priority_value,
    output wire pixel_valid,
    output wire [31:0] missed_lines,output reg [31:0] completed_lines,
    output wire rom_lock,
    output wire [2:0] lead,
    // Per-row road coverage table for the tile compositor: for the queried row,
    // {layer-0 painted all 288 px solid, its priority} of the frame the raster
    // shows (double-buffered with the framebuffer). Registered read.
    input wire [8:0] road_query_y,output reg [4:0] road_query_q,
    output wire [191:0] dbg_c169,
    // DDR3 framebuffer master: the MiSTer DDRAM port (Avalon-MM), on clk.
    output wire ddr_rd,ddr_we,output wire [28:0] ddr_addr,output wire [7:0] ddr_burstcnt,
    output wire [63:0] ddr_din,output wire [7:0] ddr_be,
    input wire ddr_busy,input wire [63:0] ddr_dout,input wire ddr_dout_ready
);
    reg [2:0] state;
    localparam IDLE=0,CLEAR=1,ISSUE=2,DRAW=3,FINISH=4;
    reg [8:0] draw_y,clear_x;
    wire line_req,compose_bank,display_bank,next_display_bank,display_valid;
    wire [8:0] line_y;
    wire [10:0] ring_addr;
    wire [17:0] old_pixel,ring_q;
    wire [15:0] pix_out;
    wire busy,done,paint,solid,road_overwrite,line_full;
    wire [3:0] line_pri;
    wire [8:0] paint_x;
    wire [12:0] draw_pen;
    wire [3:0] draw_priority;
    fl_c169 road(.clk(clk),.reset(reset),.cpu_req(cpu_req),.cpu_write(cpu_write),
        .cpu_control(cpu_control),.cpu_addr(cpu_addr),.cpu_data(cpu_data),.cpu_be(cpu_be),
        .cpu_ready(cpu_ready),.cpu_q(cpu_q),.start(state==ISSUE),.line_y(draw_y),
        .busy(busy),.done(done),.paint(paint),.solid(solid),.paint_x(paint_x),
        .pen(draw_pen),.priority_value(draw_priority),.rom_req(rom_req),.rom_addr(rom_addr),
        .rom_ready(rom_ready),.rom_data(rom_data),.rom_data_wide(rom_data_wide),.overwrite(road_overwrite),.rom_lock(rom_lock),
        .line_full(line_full),.line_pri(line_pri),
        .dbg_mode(dbg_c169_mode),.dbg_attr0(dbg_c169_attr0),
        .dbg_pline_attr(dbg_c169_pattr),.dbg_pline_sx(dbg_c169_psx),
        .dbg_road_lines(dbg_c169_lines),.dbg_road_posv(dbg_c169_posv),
        .dbg_road_solid(dbg_c169_solid),.dbg_grass_solid(dbg_c169_grass));
    wire [15:0] dbg_c169_mode,dbg_c169_attr0,dbg_c169_pattr,dbg_c169_psx;
    wire [31:0] dbg_c169_lines,dbg_c169_posv,dbg_c169_solid,dbg_c169_grass;
    assign dbg_c169={dbg_c169_mode,dbg_c169_attr0,dbg_c169_pattr,dbg_c169_psx,
                     dbg_c169_lines,dbg_c169_posv,dbg_c169_solid,dbg_c169_grass};
    // overwrite: the pass paints into a cleared buffer (layer 1, or layer 0 with layer 1
    // disabled), so the registered old_pixel read is irrelevant and the walker may paint
    // back-to-back. Otherwise (layer 0 over layer 1) the walker keeps a 1-cycle gap so
    // old_pixel is the pixel at paint_x.
    wire write_pixel=paint && solid && (road_overwrite || !old_pixel[17] || draw_priority>=old_pixel[16:13]);
    fl_dual_read_ram #(.ADDR_WIDTH(11),.DATA_WIDTH(18)) buffer_ram(
        .clk(clk),.enable_a(1'b1),.write_a(!reset && (state==CLEAR || write_pixel)),
        .address_a({draw_y[1:0],state==CLEAR?clear_x:paint_x}),.address_b(ring_addr),
        .data_a(state==CLEAR ? 18'd0 : {1'b1,draw_priority,draw_pen}),
        .q_a(old_pixel),.q_b(ring_q));
    fl_layer_fb #(.LAYER(0)) fb(.clk(clk),.reset(reset),.line_start(line_start),.x(x),.y(y),
        .line_req(line_req),.line_y(line_y),.line_ack(state==IDLE && line_req),.line_done(state==FINISH),
        .engine_idle(state==IDLE),.draw_y(draw_y),
        .ring_addr(ring_addr),.ring_q({ring_q[17],ring_q[16:13],ring_q[10:0]}),   // pen[12:11] is constant 2'b11
        .compose_bank(compose_bank),.display_bank(display_bank),.next_display_bank(next_display_bank),
        .lead(lead),.pix_out(pix_out),.display_valid(display_valid),.missed_lines(missed_lines),
        .ddr_rd(ddr_rd),.ddr_we(ddr_we),.ddr_addr(ddr_addr),.ddr_burstcnt(ddr_burstcnt),.ddr_din(ddr_din),.ddr_be(ddr_be),
        .ddr_busy(ddr_busy),.ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dout_ready));
    assign pen={2'b11,pix_out[10:0]};
    assign priority_value=pix_out[14:11];
    assign pixel_valid=display_valid && x<9'd288 && y<9'd224 && pix_out[15];
    // Per-row {layer0 fully solid, priority}, double-buffered with the framebuffer.
    (* ramstyle = "MLAB, no_rw_check" *) reg [4:0] road_row[0:511];
    // Rows 0..7 queried near the end of the frame belong to the frame about to flip in
    // (next_display_bank already accounts for a late frame that will not flip).
    wire query_bank=(road_query_y<9'd8 && y>9'd200) ? next_display_bank : display_bank;
    always @(posedge clk) begin
        road_query_q<=road_query_y<9'd224 ? road_row[{query_bank,road_query_y[7:0]}] : 5'd0;
        if(state==FINISH) road_row[{compose_bank,draw_y[7:0]}]<={line_full,line_pri};
    end
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;draw_y<=0;clear_x<=0;completed_lines<=0;
        end else case(state)
            IDLE:if(line_req) begin draw_y<=line_y;clear_x<=0;state<=CLEAR;end
            CLEAR:if(clear_x==287) state<=ISSUE;else clear_x<=clear_x+1'b1;
            ISSUE:state<=DRAW;
            DRAW:if(done) state<=FINISH;
            FINISH:begin completed_lines<=completed_lines+1'b1;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
