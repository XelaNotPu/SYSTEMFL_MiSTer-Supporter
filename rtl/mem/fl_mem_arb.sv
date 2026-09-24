// SPDX-License-Identifier: GPL-3.0-or-later
// Retain transaction ownership/payload across resets or host download start.
module fl_mem_arb(input wire clk,reset,
    input wire a_req,input wire [25:0] a_addr,input wire [31:0] a_data,input wire [3:0] a_be,
    output reg a_ready,
    input wire b_req,b_write,input wire [25:0] b_addr,input wire [31:0] b_data,input wire [3:0] b_be,
    output reg b_ready,
    output reg req,write,output reg [25:0] addr,output reg [31:0] data,output reg [3:0] be,
    input wire ready);
    reg [1:0] state;
    reg owner;
    always @(posedge clk) begin
        a_ready<=0; b_ready<=0;
        if(reset) begin state<=0; req<=0; write<=0; addr<=0; data<=0; be<=0; owner<=0; end
        else case(state)
            0:if(a_req || b_req) begin
                owner<=a_req; req<=1; write<=a_req || b_write;
                addr<=a_req ? a_addr : b_addr;
                data<=a_req ? a_data : b_data;
                be<=a_req ? a_be : b_be;
                state<=1;
            end
            1:if(ready) begin
                if(owner) a_ready<=1; else b_ready<=1;
                req<=0; state<=2;
            end
            2:if(!ready && !(owner ? a_req : b_req)) state<=0;
            default:state<=0;
        endcase
    end
endmodule
