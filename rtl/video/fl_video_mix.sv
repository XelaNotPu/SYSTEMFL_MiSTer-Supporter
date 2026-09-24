// SPDX-License-Identifier: GPL-3.0-or-later
// C169 -> C123 (ties) -> already-composed C355 (ties). C355 shadow pen 0xffe
// sets the background's palette shadow bit. A shadow on blank stays black.
module fl_video_mix(
 input wire road_valid,tile_valid,sprite_valid,
 input wire [12:0] road_pen,tile_pen,input wire [11:0] sprite_pen,
 input wire [3:0] road_priority,tile_priority,sprite_priority,
 output reg [12:0] pen,output reg pixel_valid
);
 wire choose_tile=tile_valid && (!road_valid || tile_priority>=road_priority);
 wire background_valid=road_valid || tile_valid;
 wire [12:0] background_pen=choose_tile?tile_pen:road_pen;
 wire [3:0] background_priority=background_valid?(choose_tile?tile_priority:road_priority):4'd0;
 always @* begin
  pixel_valid=background_valid;pen=background_valid?background_pen:13'd0;
  if(sprite_valid && sprite_priority>=background_priority)begin
   if(sprite_pen==12'hffe)pen=pen|13'h0800;
   else begin pixel_valid=1;pen={1'b0,sprite_pen};end
  end
 end
endmodule
