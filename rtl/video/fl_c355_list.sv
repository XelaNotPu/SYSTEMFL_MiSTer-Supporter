// SPDX-License-Identifier: GPL-3.0-or-later
// Decode the snapshotted C355 list once per frame. Compact quotient/remainder
// geometry avoids retaining all 16x16 tile positions for each sprite.
module fl_c355_list(
 input wire clk,reset,start,output reg busy,done,ready,
 output reg [14:0] ram_address,input wire [31:0] ram_q,
 input wire [7:0] metadata_address,output reg [191:0] metadata_q,
 output reg [8:0] sprite_count
);
 localparam IDLE=0,LIST_SET=1,LIST_WAIT=2,LIST_GET=3,ATTR_WAIT=4,ATTR_GET=5,
  CLIP_WAIT=6,CLIP_GET=7,FORMAT_WAIT=8,FORMAT_GET=9,GEOM_START=10,GEOM_WAIT=11,STORE=12;
 reg [3:0] state;reg [7:0] index;reg [1:0] pair;
 reg last_entry;reg [15:0] attrs[0:7],clip[0:3],format[0:3];
 reg [191:0] metadata[0:255];
 always @(posedge clk)metadata_q<=metadata[metadata_address];
 wire [15:0] list_word=index[0]?ram_q[31:16]:ram_q[15:0];
 wire [4:0] columns=format[1][7:4]==0 ? 5'd16 : {1'b0,format[1][7:4]};
 wire [4:0] rows=format[1][3:0]==0 ? 5'd16 : {1'b0,format[1][3:0]};
 wire disabled=attrs[4][9:0]==0 || attrs[5][9:0]==0;
 wire x_done,y_done;
 wire signed [15:0] x_origin,y_origin;
 wire [9:0] x_base,y_base;wire [4:0] x_extra,y_extra;
 reg x_complete,y_complete;
 fl_c355_axis xaxis(.clk(clk),.reset(reset),.start(state==GEOM_START),.consume(1'b1),
  .position(attrs[2][10:0]),.extent(attrs[4][9:0]),.tiles(columns),.anchor(format[2][8:0]),.flip(attrs[4][15]),
  .busy(),.valid(),.done(x_done),.tile_index(),.tile_position(),.tile_extent(),
  .axis_origin(x_origin),.base_extent(x_base),.extra_tiles(x_extra));
 fl_c355_axis yaxis(.clk(clk),.reset(reset),.start(state==GEOM_START),.consume(1'b1),
  .position(attrs[3][10:0]),.extent(attrs[5][9:0]),.tiles(rows),.anchor(format[3][8:0]),.flip(attrs[5][15]),
  .busy(),.valid(),.done(y_done),.tile_index(),.tile_position(),.tile_extent(),
  .axis_origin(y_origin),.base_extent(y_base),.extra_tiles(y_extra));
 integer i;
 always @(posedge clk)begin
  done<=0;
  if(reset)begin
   state<=IDLE;busy<=0;done<=0;ready<=0;ram_address<=0;sprite_count<=0;
   index<=0;pair<=0;last_entry<=0;x_complete<=0;y_complete<=0;
   for(i=0;i<8;i=i+1)attrs[i]<=0;
   for(i=0;i<4;i=i+1)begin clip[i]<=0;format[i]<=0;end
  end else case(state)
   IDLE:if(start)begin busy<=1;ready<=0;sprite_count<=0;index<=0;state<=LIST_SET;end
   LIST_SET:begin ram_address<=15'h0800+{8'd0,index[7:1]};state<=LIST_WAIT;end
   LIST_WAIT:state<=LIST_GET;
   LIST_GET:begin
    last_entry<=list_word[8];ram_address<={5'd0,list_word[7:0],2'b00};pair<=0;state<=ATTR_WAIT;
   end
   ATTR_WAIT:state<=ATTR_GET;
   ATTR_GET:begin
    attrs[{pair,1'b0}]<=ram_q[15:0];attrs[{pair,1'b1}]<=ram_q[31:16];
    if(pair==3)begin
     // Attribute word 6 arrives on this edge; use the bus directly.
     ram_address<=15'h0900+{10'd0,ram_q[11:8],1'b0};pair<=0;state<=CLIP_WAIT;
    end else begin pair<=pair+1'b1;ram_address<=ram_address+1'b1;state<=ATTR_WAIT;end
   end
   CLIP_WAIT:state<=CLIP_GET;
   CLIP_GET:begin
    clip[{pair[0],1'b0}]<=ram_q[15:0];clip[{pair[0],1'b1}]<=ram_q[31:16];
    if(pair==1)begin ram_address<=15'h1000+{3'd0,attrs[0][10:0],1'b0};pair<=0;state<=FORMAT_WAIT;end
    else begin pair<=1;ram_address<=ram_address+1'b1;state<=CLIP_WAIT;end
   end
   FORMAT_WAIT:state<=FORMAT_GET;
   FORMAT_GET:begin
    format[{pair[0],1'b0}]<=ram_q[15:0];format[{pair[0],1'b1}]<=ram_q[31:16];
    if(pair==1)begin x_complete<=0;y_complete<=0;state<=disabled?STORE:GEOM_START;end
    else begin pair<=1;ram_address<=ram_address+1'b1;state<=FORMAT_WAIT;end
   end
   GEOM_START:state<=GEOM_WAIT;
   GEOM_WAIT:begin
    if(x_done)x_complete<=1;if(y_done)y_complete<=1;
    if((x_complete||x_done)&&(y_complete||y_done))state<=STORE;
   end
   STORE:begin
    // [191:128] clip L/R/T/B, [127:96] signed origins X/Y,
    // [95:76] X base/extra/count, [75:56] Y base/extra/count,
    // [55:24] tile-list base/offset, [23:14] flips/priority/palette,
    // [13] disabled, [12:0] reserved.
    metadata[index]<={clip[0],clip[1],clip[2],clip[3],
     disabled?16'd0:x_origin,disabled?16'd0:y_origin,
     disabled?10'd0:x_base,disabled?5'd0:x_extra,columns,
     disabled?10'd0:y_base,disabled?5'd0:y_extra,rows,
     format[0],attrs[1],attrs[4][15],attrs[5][15],attrs[6][7:4],attrs[6][3:0],disabled,13'd0};
    sprite_count<={1'b0,index}+9'd1;
    if(last_entry || index==255)begin ready<=1;busy<=0;done<=1;state<=IDLE;end
    else begin index<=index+1'b1;state<=LIST_SET;end
   end
   default:state<=IDLE;
  endcase
 end
endmodule
