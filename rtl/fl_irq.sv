// SPDX-License-Identifier: GPL-3.0-or-later
// Board interrupt levels: clear by system-register writes, set by raster.
module fl_irq(
    input wire clk,reset,ce_pixel,input wire [8:0] x,y,
    input wire [15:0] raster_line,input wire [3:0] acknowledge,
    output reg [3:0] irq
);
    wire [15:0] raster_y=raster_line-16'd33;
    wire start_line=ce_pixel && x==0;
    wire [3:0] events={1'b0,start_line && y==224,
        start_line && {7'd0,y}==raster_y,start_line && y==226};
    always @(posedge clk)
        if(reset) irq<=0;
        else irq<=(irq & ~acknowledge) | events;
endmodule
