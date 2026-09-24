// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer arcade index-9 persistence for the existing external 8 KiB NVRAM.
// The host reads a single on-chip mirror; game accesses retain their SDRAM path.
module fl_nvram #(parameter SAVE_DELAY=50_000_000)(
 input wire clk,reset,initialized,
 input wire download,upload,host_wr,input wire [15:0] index,
 input wire [26:0] address,input wire [7:0] host_data,
 output wire wait_host,output wire [7:0] host_q,output reg upload_req,
 output reg ready,output reg error,
 input wire game_write,input wire [25:0] game_addr,input wire [31:0] game_data,input wire [3:0] game_be,
 output reg mem_req,output reg [25:0] mem_addr,output reg [31:0] mem_data,output reg [3:0] mem_be,input wire mem_ready
);
 localparam [25:0] BASE=26'h2100000;
 reg old_download,load_active,finishing,restart_pending,clearing;
 reg [10:0] clear_address;
 reg [13:0] received;
 reg dirty;
 reg [31:0] save_timer;
 wire new_rom=download && !old_download && index==0;
 wire new_nvram=download && !old_download && index==9;
 wire [13:0] expected=new_nvram ? 14'd0 : received;
 wire game_commit=game_write && game_addr>=BASE && game_addr<BASE+26'd8192 && |game_be;
 wire host_commit=mem_req && mem_ready;
 wire mirror_write=host_commit || game_commit;
 wire [10:0] mirror_address=host_commit ? mem_addr[12:2] : game_addr[12:2];
 wire [31:0] mirror_data=host_commit ? mem_data : game_data;
 wire [3:0] mirror_be=host_commit ? mem_be : game_be;
 wire [31:0] mirror_q;
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1)begin:bytes
  fl_dual_read_ram #(.ADDR_WIDTH(11),.DATA_WIDTH(8)) mirror(
   .clk(clk),.enable_a(mirror_write),.write_a(mirror_be[lane]),
   .address_a(mirror_address),.data_a(mirror_data[lane*8+:8]),.q_a(),
   .address_b(address[12:2]),.q_b(mirror_q[lane*8+:8]));
 end endgenerate
 assign host_q=upload && index==9 && address<8192 ? mirror_q[8*address[1:0]+:8] : 8'hff;
 assign wait_host=!initialized || restart_pending || clearing || mem_req || finishing;
 always @(posedge clk)begin
  old_download<=download;upload_req<=0;
  if(reset)begin
   old_download<=0;load_active<=0;finishing<=0;restart_pending<=1;clearing<=0;clear_address<=0;
   received<=0;ready<=0;error<=0;mem_req<=0;mem_addr<=BASE;mem_data<=0;mem_be<=0;
   dirty<=0;save_timer<=0;upload_req<=0;
  end else begin
   if(host_commit)begin
    mem_req<=0;
    if(clearing)begin
     if(clear_address==2047)begin clearing<=0;ready<=1;end
     else clear_address<=clear_address+1'b1;
    end
   end
   if(initialized && !mem_req)begin
    if(restart_pending)begin
     restart_pending<=0;clearing<=1;clear_address<=0;ready<=0;error<=0;
    end else if(clearing)begin
     mem_req<=1;mem_addr<=BASE+{13'd0,clear_address,2'b00};mem_data<=32'hffffffff;mem_be<=4'hf;
    end
   end
   if(new_nvram)begin load_active<=1;received<=0;ready<=0;error<=0;end
   if(download && index==9 && host_wr)begin
    if(wait_host || address>=8192 || address!={13'd0,expected})error<=1;
    else begin
     mem_req<=1;mem_addr<=BASE+{13'd0,address[12:2],2'b00};
     mem_data<={24'd0,host_data}<<(8*address[1:0]);mem_be<=4'b0001<<address[1:0];received<=expected+1'b1;
    end
   end
   if(!download && old_download && load_active)begin finishing<=1;load_active<=0;end
   if(finishing && !mem_req)begin
    finishing<=0;ready<=!error && received==8192;
    if(received!=8192)error<=1;
   end
   // Coalesce game writes after one second of quiet. Writes during an upload
   // remain dirty, so a later save captures anything changed during that upload.
   if(game_commit)begin dirty<=1;save_timer<=SAVE_DELAY;end
   else if(dirty && !upload && !download && ready)begin
    if(save_timer!=0)save_timer<=save_timer-1'b1;
    else begin upload_req<=1;dirty<=0;end
   end
   if(new_nvram || new_rom)begin dirty<=0;save_timer<=0;end
   if(new_rom)begin restart_pending<=1;ready<=0;error<=0;load_active<=0;finishing<=0;end
  end
 end
endmodule
