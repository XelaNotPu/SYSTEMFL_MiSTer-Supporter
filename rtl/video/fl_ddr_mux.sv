// SPDX-License-Identifier: GPL-3.0-or-later
// Two DDRAM masters (the road and sprite layer framebuffers, fl_layer_fb) on
// the one MiSTer DDRAM port, one transaction at a time: a single-word write
// holds the port until accepted; a burst read holds it until its last word has
// returned, so DOUT_READY is routed unambiguously. A master that is not granted
// sees BUSY and simply keeps its request up. Master 0 wins a tie; a transaction
// is at most 24 words (~30 clk), so neither waits long.
module fl_ddr_mux(
    input wire clk,reset,
    // master 0 / master 1
    input wire [1:0] m_rd,m_we,input wire [1:0][28:0] m_addr,input wire [1:0][7:0] m_burstcnt,
    input wire [1:0][63:0] m_din,input wire [1:0][7:0] m_be,
    output wire [1:0] m_busy,m_dout_ready,output wire [63:0] m_dout,
    // port
    output wire ddr_rd,ddr_we,output wire [28:0] ddr_addr,output wire [7:0] ddr_burstcnt,
    output wire [63:0] ddr_din,output wire [7:0] ddr_be,
    input wire ddr_busy,input wire [63:0] ddr_dout,input wire ddr_dout_ready
);
    reg locked,owner,reading;
    reg [7:0] remaining;
    wire [1:0] want=m_rd|m_we;
    wire pick=want[0] ? 1'b0 : 1'b1;
    wire sel=locked ? owner : pick;
    wire active=locked || want!=2'b00;
    assign ddr_rd=active && m_rd[sel];
    assign ddr_we=active && m_we[sel];
    assign ddr_addr=m_addr[sel];
    assign ddr_burstcnt=m_burstcnt[sel];
    assign ddr_din=m_din[sel];
    assign ddr_be=m_be[sel];
    assign m_busy[0]=ddr_busy || (active && sel!=1'b0);
    assign m_busy[1]=ddr_busy || (active && sel!=1'b1);
    assign m_dout=ddr_dout;
    assign m_dout_ready[0]=ddr_dout_ready && locked && reading && owner==1'b0;
    assign m_dout_ready[1]=ddr_dout_ready && locked && reading && owner==1'b1;
    wire accept=active && (ddr_rd || ddr_we) && !ddr_busy;
    always @(posedge clk) begin
        if(reset) begin locked<=0;owner<=0;reading<=0;remaining<=0;end
        else if(!locked) begin
            if(want!=2'b00) begin
                owner<=pick;locked<=1;
                if(accept) begin
                    // accepted in the same cycle it was picked
                    if(ddr_rd) begin reading<=1;remaining<=ddr_burstcnt;end
                    else locked<=0;   // single-word write done
                end else reading<=0;
            end
        end else if(!reading) begin
            if(accept) begin
                if(ddr_rd) begin reading<=1;remaining<=ddr_burstcnt;end
                else locked<=0;
            end
        end else if(ddr_dout_ready) begin
            remaining<=remaining-1'b1;
            if(remaining==8'd1) begin locked<=0;reading<=0;end
        end
    end
endmodule
