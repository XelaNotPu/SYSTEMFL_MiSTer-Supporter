// SPDX-License-Identifier: GPL-3.0-or-later
// Traverse compact frame descriptors in list/row/column order. Fractional
// tile extents may overlap; both rows/columns are rendered to preserve the
// reference's later-tile overwrite behavior before background priority mix.
module fl_c355_draw(
 input wire clk,reset,start,input wire [8:0] line_y,sprite_count,
 input wire [31:0] sprite_bank,output reg busy,done,
 output reg [7:0] metadata_address,input wire [191:0] metadata_q,
 output reg [14:0] ram_address,input wire [31:0] ram_q,
 output wire paint,solid,output wire [8:0] x,output wire [11:0] pen,
 output wire [3:0] priority_value,
 output wire rom_req,output wire [25:0] rom_addr,input wire rom_ready,input wire [31:0] rom_data,input wire [127:0] rom_data_wide,
 output wire rom_lock
);
 localparam IDLE=0,META_WAIT=1,META_GET=2,TEST_SPRITE=3,ROW=4,Y_DIVIDE=5,Y_SAMPLE=6,
  COLUMN=7,TILE_WAIT=8,TILE_GET=9,PIXEL_START=10,PIXEL_WAIT=11,NEXT_COLUMN=12,NEXT_ROW=13,NEXT_SPRITE=14;
 reg [3:0] state;
 reg [191:0] descriptor;
 reg [8:0] count,draw_y;
 reg [1:0] bank;
 reg [4:0] row_index,column_index;
 wire [15:0] clip_left=descriptor[191:176],clip_right=descriptor[175:160];
 wire [15:0] clip_top=descriptor[159:144],clip_bottom=descriptor[143:128];
 wire signed [15:0] origin_x=descriptor[127:112],origin_y=descriptor[111:96];
 wire [9:0] base_x=descriptor[95:86],base_y=descriptor[75:66];
 wire [4:0] extra_x=descriptor[85:81],columns=descriptor[80:76];
 wire [4:0] extra_y=descriptor[65:61],rows=descriptor[60:56];
 wire [15:0] tile_base=descriptor[55:40],tile_offset=descriptor[39:24];
 wire flip_x=descriptor[23],flip_y=descriptor[22];
 wire [4:0] rows_left=rows-row_index,columns_left=columns-column_index;
 wire [10:0] advance_x={1'b0,base_x}+11'(columns_left<=extra_x);
 wire [10:0] advance_y={1'b0,base_y}+11'(rows_left<=extra_y);
 wire [10:0] visible_x={1'b0,base_x}+11'({1'b0,columns_left}<={extra_x,1'b0});
 wire [10:0] visible_y={1'b0,base_y}+11'({1'b0,rows_left}<={extra_y,1'b0});
 wire [14:0] total_y=base_y*rows+{10'd0,extra_y};
 wire signed [31:0] line_value=$signed({23'd0,draw_y});
 wire signed [31:0] sprite_top=flip_y ? $signed(origin_y)-$signed({17'd0,total_y}) : $signed(origin_y);
 // Flipped rounded tiles may extend one pixel beyond their nominal origin.
 wire signed [31:0] sprite_bottom=flip_y ? $signed(origin_y)+(extra_y!=0?32'sd1:32'sd0) : $signed(origin_y)+$signed({17'd0,total_y});
 reg signed [15:0] cursor_x,cursor_y,draw_left;
 wire signed [15:0] column_left=flip_x?cursor_x-$signed({5'd0,advance_x}):cursor_x;
 wire signed [15:0] row_top=flip_y?cursor_y-$signed({5'd0,advance_y}):cursor_y;
 wire signed [31:0] row_delta=line_value-$signed(row_top);
 wire signed [31:0] column_right=$signed(column_left)+$signed({21'd0,visible_x});
 reg [10:0] draw_width,y_offset,y_divisor;
 reg [20:0] dividend,quotient;
 reg [11:0] remainder;
 reg [4:0] bits_left;
 // Last Y-divider result: rows of one sprite share visible_y, so the 21-clock serial
 // divide is replayed from this cache instead of re-run (bit-identical quotient).
 reg [10:0] ydiv_last;reg [20:0] ydiv_q;reg ydiv_valid;
 wire [11:0] shifted_remainder={remainder[10:0],dividend[20]};
 wire subtract=shifted_remainder>={1'b0,y_divisor};
 wire [31:0] y_fixed=y_offset*quotient;
 reg [3:0] source_row;
 wire [15:0] tile_index=tile_base+16'(row_index*columns)+{11'd0,column_index};
 reg tile_half;
 wire [15:0] tile_word=tile_half?ram_q[31:16]:ram_q[15:0];
 wire [14:0] banked_tile=tile_word[13]?{bank,tile_word[12:0]}:tile_word[14:0];
 reg [14:0] code;
 wire pixels_done;
 fl_c355_pixels pixels(.clk(clk),.reset(reset),.start(state==PIXEL_START),.consume(1'b1),
  .tile(code),.source_row(source_row),.position(draw_left),.extent(draw_width),.flip(flip_x),
  .clip_left(clip_left),.clip_right(clip_right),.color(descriptor[17:14]),.priority_in(descriptor[21:18]),
  .busy(),.done(pixels_done),.paint(paint),.solid(solid),.x(x),.pen(pen),.priority_value(priority_value),
  .rom_req(rom_req),.rom_addr(rom_addr),.rom_ready(rom_ready),.rom_data(rom_data),.rom_data_wide(rom_data_wide),.rom_lock(rom_lock));
 always @(posedge clk)begin
  done<=0;
  if(reset)begin
   state<=IDLE;busy<=0;done<=0;metadata_address<=0;ram_address<=0;descriptor<=0;
   count<=0;draw_y<=0;bank<=0;row_index<=0;column_index<=0;cursor_x<=0;cursor_y<=0;
   draw_left<=0;draw_width<=0;y_offset<=0;y_divisor<=0;dividend<=0;quotient<=0;remainder<=0;bits_left<=0;
   ydiv_last<=0;ydiv_q<=0;ydiv_valid<=0;
   source_row<=0;tile_half<=0;code<=0;
  end else case(state)
   IDLE:if(start)begin
    if(sprite_count==0)done<=1;
    else begin busy<=1;count<=sprite_count;draw_y<=line_y;bank<=sprite_bank[1:0];metadata_address<=0;state<=META_WAIT;end
   end
   META_WAIT:state<=META_GET;
   META_GET:begin descriptor<=metadata_q;state<=TEST_SPRITE;end
   TEST_SPRITE:begin
    if(descriptor[13] || draw_y<clip_top || draw_y>clip_bottom || line_value<sprite_top || line_value>=sprite_bottom)state<=NEXT_SPRITE;
    else begin cursor_y<=origin_y;row_index<=0;state<=ROW;end
   end
   ROW:begin
    cursor_y<=flip_y?row_top:cursor_y+$signed({5'd0,advance_y});
    if(line_value<$signed(row_top) || row_delta>=$signed({21'd0,visible_y}))state<=NEXT_ROW;
    else begin
     y_offset<=flip_y ? visible_y-1'b1-row_delta[10:0] : row_delta[10:0];
     y_divisor<=visible_y;
     if(ydiv_valid && visible_y==ydiv_last)begin quotient<=ydiv_q;state<=Y_SAMPLE;end
     else begin dividend<=21'h100000;quotient<=0;remainder<=0;bits_left<=21;state<=Y_DIVIDE;end
    end
   end
   Y_DIVIDE:begin
    dividend<={dividend[19:0],1'b0};quotient<={quotient[19:0],subtract};
    remainder<=subtract?shifted_remainder-{1'b0,y_divisor}:shifted_remainder;
    if(bits_left==1)begin
     ydiv_last<=y_divisor;ydiv_q<={quotient[19:0],subtract};ydiv_valid<=1;state<=Y_SAMPLE;
    end else bits_left<=bits_left-1'b1;
   end
   Y_SAMPLE:begin source_row<=y_fixed[19:16];cursor_x<=origin_x;column_index<=0;state<=COLUMN;end
   COLUMN:begin
    cursor_x<=flip_x?column_left:cursor_x+$signed({5'd0,advance_x});
    draw_left<=column_left;draw_width<=visible_x;
    if(visible_x==0 || $signed(column_left)>=288 || $signed(column_left)>$signed({16'd0,clip_right}) ||
       column_right<=0 || column_right<=$signed({16'd0,clip_left}))state<=NEXT_COLUMN;
    else begin ram_address<=15'h2000+tile_index[15:1];tile_half<=tile_index[0];state<=TILE_WAIT;end
   end
   TILE_WAIT:state<=TILE_GET;
   TILE_GET:if(tile_word[15])state<=NEXT_COLUMN;
            else begin code<=banked_tile+tile_offset[14:0];state<=PIXEL_START;end
   PIXEL_START:state<=PIXEL_WAIT;
   PIXEL_WAIT:if(pixels_done)state<=NEXT_COLUMN;
   NEXT_COLUMN:if(column_index+1'b1==columns)state<=NEXT_ROW;
               else begin column_index<=column_index+1'b1;state<=COLUMN;end
   NEXT_ROW:if(row_index+1'b1==rows)state<=NEXT_SPRITE;
            else begin row_index<=row_index+1'b1;state<=ROW;end
   NEXT_SPRITE:if({1'b0,metadata_address}+9'd1==count)begin busy<=0;done<=1;state<=IDLE;end
               else begin metadata_address<=metadata_address+1'b1;state<=META_WAIT;end
   default:state<=IDLE;
  endcase
 end
endmodule
