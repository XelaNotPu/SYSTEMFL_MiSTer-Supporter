// SPDX-License-Identifier: GPL-3.0-or-later
// C116 palette/control aperture. Behavioral reference: MAME namco_c116.cpp.
// Four byte lanes per color provide one CPU dword and one pixel lookup/clock.
module fl_c116(
    input wire clk,reset,
    input wire req,write,input wire [14:0] addr,input wire [31:0] wdata,
    input wire [3:0] be,output reg ready,output wire [31:0] rdata,
    input wire [12:0] pen,output wire [23:0] rgb,
    output wire [15:0] clip_left,clip_right,clip_top,clip_bottom,raster_line
);
    reg [15:0] control[0:7];
    reg seen,register_read;
    reg [31:0] register_data;
    reg [1:0] pen_lane,cpu_plane;
    wire internal_reg=&addr[12:11];
    wire [10:0] cpu_index={addr[14:13],addr[10:2]};
    wire access_now=req && !seen && !reset;
    wire [7:0] cpu_data[0:3];
    wire [23:0] pixel_data[0:3];
    assign rdata=register_read ? register_data : {cpu_data[3],cpu_data[2],cpu_data[1],cpu_data[0]};
    assign rgb=pixel_data[pen_lane];
    assign clip_left=control[0]; assign clip_right=control[1];
    assign clip_top=control[2]; assign clip_bottom=control[3];
    assign raster_line=control[5];
    genvar lane,plane;
    generate for(lane=0;lane<4;lane=lane+1) begin: palette_lane
        wire [7:0] plane_q[0:2];
        assign cpu_data[lane]=cpu_plane==3 ? 8'd0 : plane_q[cpu_plane];
        for(plane=0;plane<3;plane=plane+1) begin: color_plane
            fl_dual_read_ram #(.ADDR_WIDTH(11)) storage(
                .clk(clk),.enable_a(access_now && !internal_reg && addr[12:11]==plane),
                .write_a(write && be[lane]),.address_a(cpu_index),
                .address_b(pen[12:2]),.data_a(wdata[8*lane+:8]),
                .q_a(plane_q[plane]),.q_b(pixel_data[lane][23-8*plane-:8]));
        end
    end
    endgenerate
    integer i;
    always @(posedge clk) begin
        ready<=0; pen_lane<=pen[1:0];
        if(reset) begin
            seen<=0; register_read<=0; register_data<=0; cpu_plane<=0;
            for(i=0;i<8;i=i+1) control[i]<=0;
        end else begin
            if(!req) seen<=0;
            if(access_now) begin
                seen<=1; ready<=1; register_read<=internal_reg;
                if(!internal_reg) cpu_plane<=addr[12:11];
                if(internal_reg) begin
                    // Even byte addresses expose the high byte of a register.
                    // The i960 bus itself remains little endian.
                    register_data<={control[{addr[3:2],1'b1}][7:0],control[{addr[3:2],1'b1}][15:8],
                                    control[{addr[3:2],1'b0}][7:0],control[{addr[3:2],1'b0}][15:8]};
                    if(write) begin
                        if(be[0]) control[{addr[3:2],1'b0}][15:8]<=wdata[7:0];
                        if(be[1]) control[{addr[3:2],1'b0}][7:0]<=wdata[15:8];
                        if(be[2]) control[{addr[3:2],1'b1}][15:8]<=wdata[23:16];
                        if(be[3]) control[{addr[3:2],1'b1}][7:0]<=wdata[31:24];
                    end
                end
            end
        end
    end
endmodule
