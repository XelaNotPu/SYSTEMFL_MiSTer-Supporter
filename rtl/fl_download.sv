// SPDX-License-Identifier: GPL-3.0-or-later
// Byte stream into SDRAM. Registers every byte and holds its payload until
// acknowledgement. Download completion waits for the final SDRAM write.
`include "rtl/fl_rom_layout.svh"
module fl_download(input wire clk,reset, initialized,
    input wire download,wr, input wire [15:0] index,
    input wire [26:0] address, input wire [7:0] data,
    output wire wait_host, output reg mem_req,
    output reg [25:0] mem_addr, output reg [31:0] mem_data,
    output reg [3:0] mem_be, input wire mem_ready,
    output reg loaded,output reg error,output reg [26:0] received);
    reg active, old_download, finishing;
    wire first_byte=download && !old_download && index==0;
    wire [26:0] expected=first_byte ? 27'd0 : received;
    assign wait_host=!initialized || mem_req || finishing;
    always @(posedge clk) begin
        old_download<=download;
        if(reset) begin
            loaded<=0; error<=0; active<=0; old_download<=0;
            finishing<=0; received<=0; mem_req<=0; mem_addr<=0; mem_data<=0; mem_be<=0;
        end else begin
            if(download && !old_download && index==0) begin
                loaded<=0; error<=0; received<=0; active<=1;
            end
            if(mem_req && mem_ready) mem_req<=0;
            if(wr && download && index==0) begin
                if(mem_req || address!=expected || address>=`FL_STREAM_SIZE) error<=1;
                else begin
                    mem_addr<={address[25:2],2'b00}; mem_data<={24'd0,data}<<(8*address[1:0]);
                    mem_be<=4'b0001<<address[1:0]; mem_req<=1; received<=expected+1'b1;
                end
            end
            if(!download && old_download && active) begin finishing<=1; active<=0; end
            if(finishing && !mem_req) begin
                finishing<=0; loaded<=!error && received==`FL_STREAM_SIZE;
                if(received!=`FL_STREAM_SIZE) error<=1;
            end
        end
    end
endmodule
