// SPDX-License-Identifier: GPL-3.0-or-later
// One axis of the C355 tiled-sprite geometry generator. Fractional zoom for
// the signed-magnitude anchor uses the reference's truncated 16.16 value;
// tile origins advance by floor(remaining/count), visible extents round it.
module fl_c355_axis(
    input wire clk,reset,start,consume,
    input wire [10:0] position,input wire [9:0] extent,
    input wire [4:0] tiles,input wire [8:0] anchor,input wire flip,
    output reg busy,valid,done,
    output reg [3:0] tile_index,
    output reg signed [15:0] tile_position,
    output reg [10:0] tile_extent,
    output reg signed [15:0] axis_origin,
    output reg [9:0] base_extent,output reg [4:0] extra_tiles
);
    localparam IDLE=0,DIVIDE=1,ANCHOR=2,SETUP_TILE=3,TILE=4,EMIT=5;
    reg [2:0] state,division_next;
    reg [21:0] dividend,quotient;
    reg [5:0] remainder;
    reg [4:0] divisor,bits_left,remaining_tiles;
    reg [9:0] remaining_extent,advance_size;
    reg [8:0] saved_anchor;
    reg saved_flip;
    reg signed [15:0] cursor;
    wire [9:0] next_advance=base_extent+10'(remaining_tiles<=extra_tiles);
    wire [5:0] twice_extra={extra_tiles,1'b0};
    wire [5:0] shifted_remainder={remainder[4:0],dividend[21]};
    wire subtract=shifted_remainder>={1'b0,divisor};
    wire [29:0] anchor_product=quotient*saved_anchor[7:0];
    wire [30:0] rounded_anchor={1'b0,anchor_product}+31'h8000;
    wire signed [15:0] anchor_magnitude=$signed({1'b0,rounded_anchor[30:16]});
    wire signed [15:0] anchor_delta=saved_anchor[8]?-anchor_magnitude:anchor_magnitude;
    always @(posedge clk) begin
        done<=0;
        if(reset) begin
            state<=IDLE;busy<=0;valid<=0;done<=0;tile_index<=0;tile_position<=0;tile_extent<=0;axis_origin<=0;base_extent<=0;extra_tiles<=0;
            dividend<=0;quotient<=0;remainder<=0;divisor<=0;bits_left<=0;division_next<=0;
            remaining_tiles<=0;remaining_extent<=0;advance_size<=0;saved_anchor<=0;saved_flip<=0;cursor<=0;
        end else case(state)
            IDLE:if(start) begin
                if(extent==0 || tiles==0 || tiles>16) done<=1;
                else begin
                    busy<=1;tile_index<=0;remaining_tiles<=tiles;remaining_extent<=extent;
                    saved_anchor<=anchor;saved_flip<=flip;cursor<={{5{position[10]}},position};
                    dividend<={extent,12'd0};quotient<=0;remainder<=0;divisor<=tiles;bits_left<=22;
                    division_next<=ANCHOR;state<=DIVIDE;
                end
            end
            DIVIDE:begin
                dividend<={dividend[20:0],1'b0};quotient<={quotient[20:0],subtract};
                remainder<=subtract?shifted_remainder-{1'b0,divisor}:shifted_remainder;
                if(bits_left==1) state<=division_next;else bits_left<=bits_left-1'b1;
            end
            ANCHOR:begin
                cursor<=saved_flip?cursor+anchor_delta:cursor-anchor_delta;
                axis_origin<=saved_flip?cursor+anchor_delta:cursor-anchor_delta;
                base_extent<=quotient[21:12];
                extra_tiles<=5'(remaining_extent-quotient[21:12]*remaining_tiles);
                state<=SETUP_TILE;
            end
            SETUP_TILE:begin
                // Remaining-size division always allocates floor(extent/count)
                // to the first count-remainder tiles, then one extra pixel to
                // each final tile. The rounded visible width changes earlier,
                // when remaining_count <= 2*remainder; preserve that overlap.
                advance_size<=next_advance;
                tile_extent<={1'b0,base_extent}+11'({1'b0,remaining_tiles}<=twice_extra);
                tile_position<=saved_flip?cursor-$signed({6'd0,next_advance}):cursor;
                if(saved_flip)cursor<=cursor-$signed({6'd0,next_advance});
                valid<=1;state<=EMIT;
            end
            EMIT:if(consume) begin
                valid<=0;
                if(remaining_tiles==1) begin busy<=0;done<=1;state<=IDLE;end
                else begin
                    remaining_tiles<=remaining_tiles-1'b1;remaining_extent<=remaining_extent-advance_size;
                    tile_index<=tile_index+1'b1;
                    if(!saved_flip)cursor<=cursor+$signed({6'd0,advance_size});
                    state<=SETUP_TILE;
                end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
