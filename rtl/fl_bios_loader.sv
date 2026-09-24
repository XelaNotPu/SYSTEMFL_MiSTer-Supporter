// SPDX-License-Identifier: GPL-3.0-or-later
// Validate the separate 16 KiB C75 BIOS download (MRA index 8).
module fl_bios_loader(
    input wire clk,reset,download,wr,input wire [15:0] index,
    input wire [26:0] address,input wire [7:0] data,
    output wire bios_wr,output wire [13:0] bios_addr,output wire [7:0] bios_data,
    output reg loaded,error
);
    reg previous,active;
    reg [14:0] count;
    wire selected=download && index==8;
    wire [14:0] expected=selected && !previous ? 15'd0 : count;
    assign bios_wr=!reset && wr && selected && address=={12'd0,expected} && address<16384;
    assign bios_addr=address[13:0]; assign bios_data=data;
    always @(posedge clk) begin
        previous<=selected;
        if(reset) begin previous<=0; active<=0; count<=0; loaded<=0; error<=0; end
        else begin
            if(selected && !previous) begin active<=1; loaded<=0; count<=0; error<=0; end
            if(wr && selected) begin
                if(address!={12'd0,expected} || address>=16384) error<=1;
                else count<=expected+1'b1;
            end
            if(!selected && previous && active) begin
                active<=0; loaded<=!error && count==16384;
                if(count!=16384) error<=1;
            end
        end
    end
endmodule
