// SPDX-License-Identifier: GPL-3.0-or-later
// One read/write port and one read-only port, synchronous old-data reads.
// Keep storage at module scope: Quartus 17.0.2 expanded equivalent arrays
// declared inside the callers' generate blocks into logic registers.
module fl_dual_read_ram #(
    parameter ADDR_WIDTH=13,
    parameter DATA_WIDTH=8
)(
    input wire clk,
    input wire enable_a,write_a,
    input wire [ADDR_WIDTH-1:0] address_a,address_b,
    input wire [DATA_WIDTH-1:0] data_a,
    output reg [DATA_WIDTH-1:0] q_a,q_b
);
    reg [DATA_WIDTH-1:0] ram[0:(1<<ADDR_WIDTH)-1];
    always @(posedge clk) begin
        if(enable_a) begin
            q_a<=ram[address_a];
            if(write_a) ram[address_a]<=data_a;
        end
        q_b<=ram[address_b];
    end
endmodule
