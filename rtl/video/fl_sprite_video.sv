// SPDX-License-Identifier: GPL-3.0-or-later
// C355 CPU RAM/snapshot, frame list preparation and scanline renderer composing
// ONE FRAME AHEAD through the DDR3 layer framebuffer (fl_layer_fb, layer 1).
// Sprite pixels overwrite in list order; background priorities/shadows are
// applied later by the board mixer, after this sprite-only composition.
//
// Timeline: the object RAM is snapshotted at the end of the visible frame
// (line 223) as before, the list is built during vblank, the whole next frame
// is composed from it over the following frame period (264 lines; the busiest
// measured scene needs ~110 line budgets, but single lines peak at 2-4 budgets
// which an 8-line ring could not bank), and it is displayed the frame after.
// The snapshot waits for the composition in flight to finish so one frame never
// mixes two lists. Sprites and the road both lag the tile layer by one frame.
// Pixel packing: {pri[3:0],palette[3:0],px[7:0]}; a drawn pixel is never 0xff
// (transparent), so 0xff encodes "empty" and no valid bit is needed.
module fl_sprite_video(
 input wire clk,reset,line_start,input wire [8:0] x,y,input wire [31:0] sprite_bank,
 input wire cpu_req,cpu_write,input wire [16:0] cpu_addr,input wire [31:0] cpu_data,input wire [3:0] cpu_be,
 output wire cpu_ready,output wire [31:0] cpu_q,
 output wire mem_req,mem_write,output wire [25:0] mem_addr,output wire [31:0] mem_data,output wire [3:0] mem_be,
 input wire mem_ready,input wire [31:0] mem_q,
 output wire rom_req,output wire [25:0] rom_addr,input wire rom_ready,input wire [31:0] rom_data,input wire [127:0] rom_data_wide,
 output wire rom_lock,
 output wire [2:0] lead,
 // Object-RAM write-queue telemetry (probe): full flag and current depth.
 output wire queue_full,output wire [11:0] queued_writes,
 output wire [11:0] pen,output wire [3:0] priority_value,output wire pixel_valid,
 output wire [31:0] missed_lines,output reg [31:0] completed_lines,
 // DDR3 framebuffer master: the MiSTer DDRAM port (Avalon-MM), on clk.
 output wire ddr_rd,ddr_we,output wire [28:0] ddr_addr,output wire [7:0] ddr_burstcnt,
 output wire [63:0] ddr_din,output wire [7:0] ddr_be,
 input wire ddr_busy,input wire [63:0] ddr_dout,input wire ddr_dout_ready
);
 wire snapshot_busy,snapshot_done,initializing,list_busy,list_ready,list_done,composing;
 wire [14:0] list_address,draw_address;
 wire [31:0] render_q;
 // Snapshot at the end of the visible frame, deferred while a composition from a
 // valid list is in flight (a late frame) so one frame never renders from two
 // lists. With no list yet (boot) the composition is only waiting, so snapshot.
 reg snapshot_pending;
 wire snapshot=(snapshot_pending || (line_start && y==9'd223)) && !(composing && list_ready) && !snapshot_busy && !list_busy;
 always @(posedge clk) if(reset) snapshot_pending<=0;
  else if(snapshot) snapshot_pending<=0;
  else if(line_start && y==9'd223) snapshot_pending<=1;
 reg [31:0] frame_bank;
 always @(posedge clk)if(reset)frame_bank<=0;else if(snapshot)frame_bank<=sprite_bank;
 fl_c355_ram storage(.clk(clk),.reset(reset),.cpu_req(cpu_req),.cpu_write(cpu_write),
 .cpu_addr(cpu_addr),.cpu_data(cpu_data),.cpu_be(cpu_be),.cpu_ready(cpu_ready),.cpu_q(cpu_q),
 .mem_req(mem_req),.mem_write(mem_write),.mem_addr(mem_addr),.mem_data(mem_data),.mem_be(mem_be),.mem_ready(mem_ready),.mem_q(mem_q),
 .snapshot(snapshot),.snapshot_busy(snapshot_busy),.snapshot_done(snapshot_done),.initializing(initializing),
 .render_address(list_busy?list_address:draw_address),.render_q(render_q),.queue_full(queue_full),.queued_writes(queued_writes));
 wire [7:0] meta_address;wire [191:0] meta_q;wire [8:0] sprite_count;
 fl_c355_list list(.clk(clk),.reset(reset),.start(snapshot_done),.busy(list_busy),.done(list_done),.ready(list_ready),
 .ram_address(list_address),.ram_q(render_q),.metadata_address(meta_address),.metadata_q(meta_q),.sprite_count(sprite_count));
 reg [2:0] state;
 localparam IDLE=0,CLEAR=1,ISSUE=2,DRAW=3,FINISH=4;
 reg [8:0] draw_y,clear_x;
 wire line_req,display_valid;
 wire [8:0] line_y;
 wire [10:0] ring_addr;
 wire [16:0] ring_q;
 wire [15:0] pix_out;
 wire compose_go=line_req && list_ready && !list_busy && !snapshot_busy && !initializing;
 wire draw_done,paint,solid;wire [8:0] paint_x;wire [11:0] draw_pen;wire [3:0] draw_priority;
 fl_c355_draw draw(.clk(clk),.reset(reset),.start(state==ISSUE),.line_y(draw_y),.sprite_count(sprite_count),.sprite_bank(frame_bank),
 .busy(),.done(draw_done),.metadata_address(meta_address),.metadata_q(meta_q),.ram_address(draw_address),.ram_q(render_q),
 .paint(paint),.solid(solid),.x(paint_x),.pen(draw_pen),.priority_value(draw_priority),
 .rom_req(rom_req),.rom_addr(rom_addr),.rom_ready(rom_ready),.rom_data(rom_data),.rom_data_wide(rom_data_wide),.rom_lock(rom_lock));
 fl_dual_read_ram #(.ADDR_WIDTH(11),.DATA_WIDTH(17)) buffer_ram(
 .clk(clk),.enable_a(1'b1),.write_a(!reset && (state==CLEAR || (paint && solid))),
 .address_a({draw_y[1:0],state==CLEAR?clear_x:paint_x}),.address_b(ring_addr),
 .data_a(state==CLEAR ? 17'd0 : {1'b1,draw_priority,draw_pen}),.q_a(),.q_b(ring_q));
 fl_layer_fb #(.LAYER(1)) fb(.clk(clk),.reset(reset),.line_start(line_start),.x(x),.y(y),
  .line_req(line_req),.line_y(line_y),.line_ack(state==IDLE && compose_go),.line_done(state==FINISH),
  .engine_idle(state==IDLE),.draw_y(draw_y),
  .ring_addr(ring_addr),.ring_q({ring_q[15:8],ring_q[16] ? ring_q[7:0] : 8'hff}),
  .compose_bank(),.display_bank(),.next_display_bank(),.composing(composing),
  .lead(lead),.pix_out(pix_out),.display_valid(display_valid),.missed_lines(missed_lines),
  .ddr_rd(ddr_rd),.ddr_we(ddr_we),.ddr_addr(ddr_addr),.ddr_burstcnt(ddr_burstcnt),.ddr_din(ddr_din),.ddr_be(ddr_be),
  .ddr_busy(ddr_busy),.ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dout_ready));
 assign pen=pix_out[11:0];assign priority_value=pix_out[15:12];
 assign pixel_valid=display_valid && x<9'd288 && y<9'd224 && pix_out[7:0]!=8'hff;
 always @(posedge clk)begin
  if(reset)begin
   state<=IDLE;draw_y<=0;clear_x<=0;completed_lines<=0;
  end else case(state)
    IDLE:if(compose_go)begin draw_y<=line_y;clear_x<=0;state<=CLEAR;end
    CLEAR:if(clear_x==287)state<=ISSUE;else clear_x<=clear_x+1'b1;
    ISSUE:state<=DRAW;
    DRAW:if(draw_done)state<=FINISH;
    FINISH:begin completed_lines<=completed_lines+1'b1;state<=IDLE;end
    default:state<=IDLE;
  endcase
 end
endmodule
