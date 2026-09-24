// SPDX-License-Identifier: GPL-3.0-or-later
// Exact average 6.048 MHz pixel cadence from 50 MHz; pulses have +/-1 source
// clock interval variation. Sync placement is a bring-up convention, pending
// measurements; native totals and visible envelope follow System FL.
module fl_video_timing(input wire clk, reset,
    output wire ce_pixel, output reg [8:0] x,y,
    output wire hsync,vsync,de, output wire line_start,frame_start);
    reg [12:0] phase;
    wire [13:0] sum={1'b0,phase}+14'd756;
    assign ce_pixel=sum>=6250;
    assign de=x<288 && y<224;
    assign hsync=!(x>=304 && x<336);
    assign vsync=!(y>=240 && y<244);
    assign line_start=ce_pixel && x==383;
    assign frame_start=line_start && y==263;
    always @(posedge clk) begin
        if(reset) begin phase<=0; x<=0; y<=0; end
        else begin
            phase<=ce_pixel ? 13'(sum-6250) : sum[12:0];
            if(ce_pixel) begin
                if(x==383) begin x<=0; y<=y==263 ? 9'd0 : y+1'b1; end
                else x<=x+1'b1;
            end
        end
    end
endmodule
