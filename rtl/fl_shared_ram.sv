// SPDX-License-Identifier: GPL-3.0-or-later
// 32 KiB, little-endian 32-bit i960 / byte-oriented MCU adapter.
// One synchronous RAM port with CPU priority; mux addresses before the RAM
// so enabling the MCU never expands the 32 KiB storage into logic registers.
// Held requests complete once and must deassert before another transaction.
module fl_shared_ram(input wire clk,reset,
    input wire cpu_req,cpu_wr,input wire [12:0] cpu_addr,
    input wire [31:0] cpu_din,input wire [3:0] cpu_be,
    output wire [31:0] cpu_dout,output reg cpu_ack,
    input wire mcu_req,mcu_wr,input wire [14:0] mcu_addr,
    input wire [7:0] mcu_din,output wire [7:0] mcu_dout,output reg mcu_ack);
    reg cpu_seen,mcu_seen;
    reg [1:0] mcu_lane;
    wire grant_cpu=cpu_req && !cpu_seen && !reset;
    wire grant_mcu=mcu_req && !mcu_seen && !grant_cpu && !reset;
    wire [12:0] address=grant_cpu ? cpu_addr : mcu_addr[14:2];
    wire [31:0] data=grant_cpu ? cpu_din : {4{mcu_din}};
    wire [3:0] enables=grant_cpu ? (cpu_wr ? cpu_be : 4'd0) :
        grant_mcu && mcu_wr ? (4'b1<<mcu_addr[1:0]) : 4'd0;
    wire [7:0] q[0:3];
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: byte_lane
        fl_dual_read_ram #(.ADDR_WIDTH(13)) storage(
            .clk(clk),.enable_a(grant_cpu || grant_mcu),.write_a(enables[lane]),
            .address_a(address),.address_b(13'd0),.data_a(data[8*lane+:8]),
            .q_a(q[lane]),.q_b());
    end endgenerate
    assign cpu_dout={q[3],q[2],q[1],q[0]};
    assign mcu_dout=q[mcu_lane];
    always @(posedge clk) begin
        cpu_ack<=grant_cpu;mcu_ack<=grant_mcu;
        if(reset) begin cpu_seen<=0;mcu_seen<=0;mcu_lane<=0;end
        else begin
            if(!cpu_req) cpu_seen<=0;
            if(!mcu_req) mcu_seen<=0;
            if(grant_cpu) cpu_seen<=1;
            if(grant_mcu) begin mcu_seen<=1;mcu_lane<=mcu_addr[1:0];end
        end
    end
endmodule
