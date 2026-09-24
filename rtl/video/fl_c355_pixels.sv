// SPDX-License-Identifier: GPL-3.0-or-later
// One zoomed C355 tile row, clipped to its window and the 288-pixel display.
// Pixel sampling uses floor(16*65536/extent), including flip-before-clipping.
module fl_c355_pixels(
 input wire clk,reset,start,consume,
 input wire [14:0] tile,input wire [3:0] source_row,
 input wire signed [15:0] position,input wire [10:0] extent,input wire flip,
 input wire [15:0] clip_left,clip_right,input wire [3:0] color,priority_in,
 output reg busy,done,output wire paint,solid,
 output reg [8:0] x,output wire [11:0] pen,output reg [3:0] priority_value,
 output reg rom_req,output reg [25:0] rom_addr,input wire rom_ready,input wire [31:0] rom_data,input wire [127:0] rom_data_wide,
 output wire rom_lock
);
 `include "rtl/fl_rom_layout.svh"
 localparam IDLE=0,DIVIDE=1,SETUP=2,CACHE_WAIT=3,CACHE_GET=4,FETCH=5,RELEASE=6,EMIT=7;
 reg [2:0] state;
 reg [14:0] code;reg [3:0] row,palette;
 reg [8:0] end_x;
 reg reversed;
 reg [10:0] offset,divisor;
 reg [20:0] dividend,quotient,step,source_index;
 reg [11:0] remainder;
 reg [4:0] bits_left;
 // Last divider result: consecutive tiles of a sprite share the same extent, so the
 // 21-clock serial divide is replayed from this cache (bit-identical quotient).
 reg [10:0] div_last;reg [20:0] div_q;reg div_valid;
 wire [11:0] shifted_remainder={remainder[10:0],dividend[20]};
 wire subtract=shifted_remainder>={1'b0,divisor};
 reg [127:0] pixels;
 // Direct-mapped pixel-row cache. Index = {tile[3:0],source_row} (16 tile buckets),
 // tag = code[14:4]. The old 64-entry {tile[1:0],..} index gave only 4 tile buckets
 // and thrashed on sprite-heavy scenes (large multi-tile character art), causing C355
 // scanline-deadline misses. 256 entries x 139 bits is M10K width-limited, so the 4x
 // depth increase is essentially free. tag+index together cover the full 15-bit code.
 reg [138:0] cache[0:255];reg [255:0] cache_valid;
 reg [7:0] cache_address;reg [138:0] cache_q;reg hit_valid;
 always @(posedge clk)begin cache_q<=cache[cache_address];hit_valid<=cache_valid[cache_address];end
 reg signed [31:0] left_edge,right_edge,pixel_offset;
 always @* begin
  left_edge={{16{position[15]}},position};
  if(left_edge<0)left_edge=0;
  if(left_edge<$signed({16'd0,clip_left}))left_edge=$signed({16'd0,clip_left});
  right_edge=$signed({{16{position[15]}},position})+$signed({21'd0,extent});
  if(right_edge>288)right_edge=288;
  if(right_edge>$signed({16'd0,clip_right})+1)right_edge=$signed({16'd0,clip_right})+1;
  pixel_offset=left_edge-$signed({{16{position[15]}},position});
 end
 wire [7:0] pixel=pixels[8*source_index[19:16]+:8];
 assign paint=state==EMIT;
 // Words 0..2 of a sprite row are each followed by the next word: hold the bus grant.
 // A sprite row (16 bytes) is ONE wide read: nothing to hold the grant for.
 assign rom_lock=1'b0;
 assign solid=paint && pixel!=8'hff;
 assign pen={palette,pixel};
 always @(posedge clk)begin
  done<=0;
  if(reset)begin
   state<=IDLE;busy<=0;done<=0;x<=0;end_x<=0;priority_value<=0;rom_req<=0;rom_addr<=0;
   code<=0;row<=0;palette<=0;reversed<=0;offset<=0;divisor<=0;dividend<=0;quotient<=0;
   step<=0;source_index<=0;remainder<=0;bits_left<=0;pixels<=0;cache_valid<=0;cache_address<=0;
   div_last<=0;div_q<=0;div_valid<=0;
  end else case(state)
   IDLE:if(start)begin
    if(extent==0 || extent>1023 || left_edge>=right_edge)done<=1;
    else begin
     busy<=1;code<=tile;row<=source_row;palette<=color;priority_value<=priority_in;reversed<=flip;
     x<=left_edge[8:0];end_x<=right_edge[8:0];
     offset<=flip ? extent-1'b1-pixel_offset[10:0] : pixel_offset[10:0];
     divisor<=extent;
     if(div_valid && extent==div_last)begin quotient<=div_q;state<=SETUP;end
     else begin dividend<=21'h100000;quotient<=0;remainder<=0;bits_left<=21;state<=DIVIDE;end
     cache_address<={tile[3:0],source_row};
    end
   end
   DIVIDE:begin
    dividend<={dividend[19:0],1'b0};quotient<={quotient[19:0],subtract};
    remainder<=subtract?shifted_remainder-{1'b0,divisor}:shifted_remainder;
    if(bits_left==1)begin
     div_last<=divisor;div_q<={quotient[19:0],subtract};div_valid<=1;state<=SETUP;
    end else bits_left<=bits_left-1'b1;
   end
   SETUP:begin step<=quotient;source_index<=21'(offset*quotient);state<=CACHE_WAIT;end
   CACHE_WAIT:state<=CACHE_GET;
   CACHE_GET:begin
    if(hit_valid && cache_q[138:128]==code[14:4])begin pixels<=cache_q[127:0];state<=EMIT;end
    else begin rom_addr<=`FL_C355SPR_BASE+{3'd0,code,row,4'b0000};rom_req<=1;state<=FETCH;end
   end
   FETCH:if(rom_ready)begin
    pixels<=rom_data_wide;rom_req<=0;state<=RELEASE;
    cache[cache_address]<={code[14:4],rom_data_wide};cache_valid[cache_address]<=1;
   end
   RELEASE:if(!rom_ready)state<=EMIT;
   EMIT:if(consume)begin
    if(x+1'b1==end_x)begin busy<=0;done<=1;state<=IDLE;end
    else begin x<=x+1'b1;source_index<=reversed?source_index-step:source_index+step;end
   end
   default:state<=IDLE;
  endcase
 end
endmodule
