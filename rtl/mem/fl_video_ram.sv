// SPDX-License-Identifier: GPL-3.0-or-later
// CPU read/write plus video read port. Both ports return the newly written
// value on collisions. Unlike fl_dual_read_ram's old-data contract, this can
// use one Cyclone V true-dual-port memory. Primitive configuration follows
// the existing MiSTer sys/sd_card.sv pattern; explicit mixed-port forwarding
// gives deterministic simulation and hardware behavior.
module fl_video_ram #(
 parameter ADDR_WIDTH=13,DATA_WIDTH=8,
`ifdef SYSTEMFL_INTEL_RAM
 parameter USE_PRIMITIVE=1
`else
 parameter USE_PRIMITIVE=0
`endif
)(input wire clk,enable_a,write_a,
 input wire [ADDR_WIDTH-1:0] address_a,address_b,
 input wire [DATA_WIDTH-1:0] data_a,
 output wire [DATA_WIDTH-1:0] q_a,q_b);
 generate if(USE_PRIMITIVE) begin: device_memory
 wire [DATA_WIDTH-1:0] raw_b;
 reg collision;reg [DATA_WIDTH-1:0] forward_data;
 always @(posedge clk)begin collision<=enable_a && write_a && address_a==address_b;forward_data<=data_a;end
 assign q_b=collision?forward_data:raw_b;
 altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),.intended_device_family("Cyclone V"),
 .width_a(DATA_WIDTH),.widthad_a(ADDR_WIDTH),.numwords_a(1<<ADDR_WIDTH),
 .width_b(DATA_WIDTH),.widthad_b(ADDR_WIDTH),.numwords_b(1<<ADDR_WIDTH),
 .address_reg_b("CLOCK1"),.indata_reg_b("CLOCK1"),.wrcontrol_wraddress_reg_b("CLOCK1"),
 .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
 .clock_enable_input_a("NORMAL"),.clock_enable_input_b("BYPASS"),
 .clock_enable_output_a("BYPASS"),.clock_enable_output_b("BYPASS"),
 .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
 .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
 .read_during_write_mode_mixed_ports("DONT_CARE"),.power_up_uninitialized("TRUE"),
 .width_byteena_a(1),.width_byteena_b(1)) storage(
 .clock0(clk),.clock1(clk),.clocken0(enable_a),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),
 .address_a(address_a),.address_b(address_b),.data_a(data_a),.data_b({DATA_WIDTH{1'b0}}),
 .wren_a(enable_a && write_a),.wren_b(1'b0),.rden_a(1'b1),.rden_b(1'b1),
 .byteena_a(1'b1),.byteena_b(1'b1),.addressstall_a(1'b0),.addressstall_b(1'b0),.aclr0(1'b0),.aclr1(1'b0),
 .q_a(q_a),.q_b(raw_b),.eccstatus());

 end else begin: behavioral_memory
  reg [DATA_WIDTH-1:0] memory[0:(1<<ADDR_WIDTH)-1];
  reg [DATA_WIDTH-1:0] qa,qb;
  assign q_a=qa;assign q_b=qb;
  always @(posedge clk)begin
   if(enable_a)begin
    if(write_a)memory[address_a]<=data_a;
    qa<=write_a?data_a:memory[address_a];
   end
   qb<=enable_a && write_a && address_a==address_b ? data_a : memory[address_b];
  end
 end endgenerate
endmodule
