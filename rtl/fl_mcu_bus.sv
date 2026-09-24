// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-oriented MCU adapter. Retains completion until a CPU-enable edge;
// handles consecutive byte accesses that change address without dropping RD.
`include "rtl/fl_rom_layout.svh"
module fl_mcu_bus(
    input wire clk,reset,ce,
    input wire rd,wr,input wire [23:0] addr,input wire [7:0] dout,
    output wire ready,output reg [7:0] din,
    output reg shared_req,output reg shared_write,output reg [14:0] shared_addr,
    output reg [7:0] shared_data,input wire shared_ready,input wire [7:0] shared_q,
    output reg mem_req,output reg [25:0] mem_addr,input wire mem_ready,input wire [31:0] mem_q,
    output reg sound_wr,output reg [11:0] sound_addr,output reg [7:0] sound_data,input wire [7:0] sound_q
);
    localparam IDLE=0,SHARED=1,ROM=2,SOUND=3,ACK=4,RELEASE=5;
    reg [2:0] state;
    reg [23:0] saved_addr;
    reg saved_write;
    reg [7:0] saved_data;
    assign ready=state==ACK && addr==saved_addr && wr==saved_write;
    always @(posedge clk) begin
        sound_wr<=0;
        if(reset) begin
            state<=IDLE; shared_req<=0; shared_write<=0; shared_addr<=0; shared_data<=0;
            mem_req<=0; mem_addr<=0; din<=0; sound_addr<=0; sound_data<=0;
            saved_addr<=0; saved_write<=0; saved_data<=0;
        end else case(state)
            IDLE:if(rd || wr) begin
                saved_addr<=addr; saved_write<=wr; saved_data<=dout;
                if(addr>=24'h004000 && addr<24'h00c000) begin
                    shared_req<=1; shared_write<=wr; shared_addr<=15'(addr-24'h004000);
                    shared_data<=dout; state<=SHARED;
                end else if(addr>=24'h200000 && addr<24'h280000 && rd) begin
                    mem_req<=1; mem_addr<=`FL_C75DATA_BASE+{7'd0,addr[18:2],2'b00}; state<=ROM;
                end else if(addr>=24'h002000 && addr<24'h003000) begin
                    sound_addr<=addr[11:0]; sound_data<=dout; sound_wr<=wr; state<=SOUND;
                end else begin din<=8'hff; state<=ACK; end
            end
            SHARED:if(shared_ready) begin shared_req<=0; din<=shared_q; state<=ACK; end
            ROM:if(mem_ready) begin mem_req<=0; din<=mem_q[8*saved_addr[1:0]+:8]; state<=ACK; end
            SOUND:begin din<=sound_q; state<=ACK; end
            ACK:if(ce) state<=RELEASE;
            RELEASE:if(!(rd || wr) || addr!=saved_addr || wr!=saved_write || (wr && dout!=saved_data)) state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
