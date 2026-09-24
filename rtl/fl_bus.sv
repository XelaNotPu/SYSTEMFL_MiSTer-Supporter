// SPDX-License-Identifier: GPL-3.0-or-later
// Board address decode / reset bank / IRQ acknowledgements. Video apertures
// dispatch to implemented devices, including the C355 external-RAM bridge.
`include "rtl/fl_rom_layout.svh"
module fl_bus(input wire clk,reset,
    input wire req,write, input wire [31:0] addr,wdata, input wire [3:0] be,
    output wire ready, output wire [31:0] rdata,
    // The word's whole 16-byte SDRAM block (fl_sdram rdata_wide), valid only when the read was
    // served by SDRAM: the CPU fills a 4-word instruction-cache block from it per miss.
    output wire [127:0] rdata_wide, output wire rdata_wide_valid,
    output reg boot_bank, output reg [3:0] irq_ack,
    output reg [31:0] sprite_bank,
    output reg mem_req, output wire mem_write,
    output reg [25:0] mem_addr, output wire [31:0] mem_wdata,
    output wire [3:0] mem_be, input wire mem_ready, input wire [31:0] mem_rdata, input wire [127:0] mem_rdata_wide,
    output wire sprite_req,input wire sprite_ready,input wire [31:0] sprite_rdata,
    output wire road_req,input wire road_ready,input wire [31:0] road_rdata,
    output wire tile_req,input wire tile_ready,input wire [31:0] tile_rdata,
    output wire palette_req,input wire palette_ready,input wire [31:0] palette_rdata,
    output wire shared_req, input wire shared_ready,input wire [31:0] shared_rdata);
    reg mapped,readonly;
    reg local_ready,seen;
    wire sysreg=addr>=32'h40000000 && addr<32'h40000060;
    wire sprreg=addr>=32'h30100000 && addr<32'h30100004;
    assign sprite_req=req && addr>=32'h30e00000 && addr<32'h30e20000;
    assign road_req=req && ((addr>=32'h30c00000 && addr<32'h30c20000) || (addr>=32'h30d00000 && addr<32'h30d00020));
    assign tile_req=req && ((addr>=32'h30800000 && addr<32'h30810000) || (addr>=32'h30a00000 && addr<32'h30a00040));
    assign palette_req=req && addr>=32'h30400000 && addr<32'h30408000;
    assign shared_req=req && addr>=32'h30284000 && addr<32'h3028c000;
    assign mem_write=write && !readonly;
    assign mem_wdata=wdata;
    assign mem_be=be;
    assign ready=sprite_req ? sprite_ready : road_req ? road_ready : tile_req ? tile_ready : palette_req ? palette_ready : shared_req ? shared_ready : mapped && !(write && readonly) ? mem_ready : local_ready;
    assign rdata_wide=mem_rdata_wide;
    assign rdata_wide_valid=mapped && !sprite_req && !road_req && !tile_req && !palette_req && !shared_req;
    assign rdata=sprite_req ? sprite_rdata : road_req ? road_rdata : tile_req ? tile_rdata : palette_req ? palette_rdata : shared_req ? shared_rdata : mapped ? mem_rdata : sysreg ? 32'd0 :
        addr>=32'h30380000 && addr<32'h30380100 ? (addr[7:2]==0 ? 32'hff7dffff : 32'hffffffff) : 32'hffffffff;
    always @* begin
        mem_addr=0; mapped=1; readonly=0;
        if(addr<32'h00100000) begin
            mem_addr=(boot_bank ? `FL_MAINCPU_BASE : 26'h2000000)+{6'd0,addr[19:0]}; readonly=boot_bank;
        end else if(addr>=32'h10000000 && addr<32'h10100000) begin
            mem_addr=(boot_bank ? 26'h2000000 : `FL_MAINCPU_BASE)+{6'd0,addr[19:0]}; readonly=!boot_bank;
        end else if(addr>=32'h20000000 && addr<32'h20200000) begin
            mem_addr=`FL_DATA_BASE+{5'd0,addr[20:0]}; readonly=1;
        end else if(addr>=32'h30000000 && addr<32'h30002000) mem_addr=26'h2100000+{13'd0,addr[12:0]};
        else if(addr>=32'h30300000 && addr<32'h30304000) mem_addr=26'h2110000+{12'd0,addr[13:0]};
        else if(addr>=32'h30400000 && addr<32'h30408000) mapped=0;
        else if(addr>=32'h30800000 && addr<32'h30810000) mapped=0;
        else if(addr>=32'h30a00000 && addr<32'h30a00040) mapped=0;
        else if(addr>=32'h30c00000 && addr<32'h30c20000) mapped=0;
        else if(addr>=32'h30d00000 && addr<32'h30d00020) mapped=0;
        else if(addr>=32'h30e00000 && addr<32'h30e20000) mapped=0;
        else if(addr>=32'h30f00000 && addr<32'h30f00010) mem_addr=26'h2140200+{22'd0,addr[3:0]};
        else mapped=0;
        mem_req=req && mapped && !(readonly && write);
    end
    integer lane;
    always @(posedge clk) begin
        irq_ack<=0; local_ready<=0;
        if(reset) begin boot_bank<=1; sprite_bank<=0; seen<=0; end
        else begin
            if(!req) seen<=0;
            if(req && !seen && (!mapped || (readonly && write)) && !shared_req && !palette_req && !tile_req && !road_req && !sprite_req) begin
                seen<=1; local_ready<=1;
                if(write) begin
                    if(addr==32'h40000008 && be[0]) boot_bank<=wdata[0];
                    if(addr>=32'h40000040 && addr<32'h40000050 && |be) irq_ack[addr[3:2]]<=1;
                    if(sprreg) for(lane=0;lane<4;lane=lane+1)
                        if(be[lane]) sprite_bank[8*lane+:8]<=wdata[8*lane+:8];
                end
            end
        end
    end
endmodule
