// SPDX-License-Identifier: GPL-3.0-or-later
// CPU sprite RAM stays in external memory. Completed writes queue for an
// on-chip render snapshot. A snapshot commits exactly the queued writes at
// its trigger; later CPU writes wait for the next snapshot. Full queues
// backpressure CPU writes instead of dropping updates. Page-1 alias writes
// update both CPU-visible external memory and the render snapshot.
module fl_c355_ram # (parameter FIFO_BITS=11)(
 input wire clk,reset,
 input wire cpu_req,cpu_write,input wire [16:0] cpu_addr,
 input wire [31:0] cpu_data,input wire [3:0] cpu_be,
 output reg cpu_ready,output reg [31:0] cpu_q,
 output reg mem_req,output reg mem_write,output reg [25:0] mem_addr,
 output reg [31:0] mem_data,output reg [3:0] mem_be,
 input wire mem_ready,input wire [31:0] mem_q,
 input wire snapshot,output reg snapshot_busy,output reg snapshot_done,output reg initializing,
 input wire [14:0] render_address,output wire [31:0] render_q,
 output wire queue_full,output wire [FIFO_BITS:0] queued_writes
);
 localparam [25:0] SPRITE_BASE=26'h2180000;
 reg [FIFO_BITS:0] write_pointer,read_pointer,snapshot_end;
 reg [50:0] fifo[0:(1<<FIFO_BITS)-1];
 reg [50:0] fifo_q;
 always @(posedge clk)fifo_q<=fifo[read_pointer[FIFO_BITS-1:0]];
 assign queued_writes=write_pointer-read_pointer;
 assign queue_full=queued_writes==(1<<FIFO_BITS);
 function automatic is_alias(input [14:0] address);
  is_alias=(address>=15'h4000 && address<15'h4800) || (address>=15'h5000 && address<15'h5100);
 endfunction
 function automatic [14:0] alias_address(input [14:0] address);
  alias_address=address<15'h4800 ? address-15'h4000 : address-15'h4800;
 endfunction
 reg [1:0] cpu_state;
 localparam CPU_IDLE=0,CPU_WAIT=1,CPU_RELEASE=2,CPU_DONE=3;
 reg seen,second;
 reg [14:0] saved_address;
 always @(posedge clk)begin
  cpu_ready<=0;
  if(reset)begin
   cpu_state<=CPU_IDLE;seen<=0;second<=0;saved_address<=0;
   cpu_ready<=0;cpu_q<=0;mem_req<=0;mem_write<=0;mem_addr<=0;mem_data<=0;mem_be<=0;write_pointer<=0;
  end else begin
   if(!cpu_req)seen<=0;
   case(cpu_state)
    CPU_IDLE:if(cpu_req && !seen && (!cpu_write || !queue_full))begin
     seen<=1;second<=0;saved_address<=cpu_addr[16:2];
     mem_req<=1;mem_write<=cpu_write;mem_addr<=SPRITE_BASE+{9'd0,cpu_addr[16:2],2'b00};
     mem_data<=cpu_data;mem_be<=cpu_be;cpu_state<=CPU_WAIT;
    end
    CPU_WAIT:if(mem_ready)begin
     mem_req<=0;cpu_q<=mem_q;
     if(mem_write && is_alias(saved_address) && !second)cpu_state<=CPU_RELEASE;
     else begin
      if(mem_write)begin
       fifo[write_pointer[FIFO_BITS-1:0]]<={saved_address,mem_be,mem_data};
       write_pointer<=write_pointer+1'b1;
      end
      cpu_ready<=1;cpu_state<=CPU_DONE;
     end
    end
    CPU_RELEASE:if(!mem_ready)begin
     second<=1;mem_addr<=SPRITE_BASE+{9'd0,alias_address(saved_address),2'b00};
     mem_req<=1;cpu_state<=CPU_WAIT;
    end
    CPU_DONE:if(!mem_ready)cpu_state<=CPU_IDLE;
   endcase
  end
 end
 localparam SNAP_IDLE=0,SNAP_FETCH=1,SNAP_WRITE=2,SNAP_MIRROR=3;
 reg [1:0] snapshot_state;reg [14:0] initialize_address;
 // A frame snapshot that arrives while a drain is running is remembered and run
 // right after it (a drain can now start early, see SNAP_IDLE).
 reg snapshot_pending;
 wire [14:0] queued_address=fifo_q[50:36];
 wire [3:0] queued_be=fifo_q[35:32];
 wire [14:0] commit_address=initializing ? initialize_address : snapshot_state==SNAP_MIRROR?alias_address(queued_address):queued_address;
 wire commit=!reset && (initializing || snapshot_state==SNAP_WRITE || snapshot_state==SNAP_MIRROR);
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1)begin: snapshot_lane
  fl_dual_read_ram #(.ADDR_WIDTH(15)) storage(.clk(clk),.enable_a(commit),
   .write_a(initializing || queued_be[lane]),.address_a(commit_address),.data_a(initializing ? 8'd0 : fifo_q[lane*8+:8]),
   .q_a(),.address_b(render_address),.q_b(render_q[lane*8+:8]));
 end endgenerate
 always @(posedge clk)begin
  snapshot_done<=0;
  if(reset)begin
   snapshot_state<=SNAP_IDLE;snapshot_busy<=0;snapshot_done<=0;read_pointer<=0;snapshot_end<=0;initializing<=1;initialize_address<=0;
   snapshot_pending<=0;
  end else if(initializing)begin
   if(initialize_address==15'h7fff)initializing<=0;
   else initialize_address<=initialize_address+1'b1;
  end else begin
   if(snapshot && snapshot_state!=SNAP_IDLE)snapshot_pending<=1;
   case(snapshot_state)
   // Early drain: a FULL queue used to stall the CPU until the next frame snapshot
   // (up to a whole frame per 2048 object-RAM writes; scene loads issue up to ~24k
   // in one frame, tearing the list for ~12 frames). Draining as soon as the queue
   // fills keeps write ORDER intact and bounds the stall to one drain (~2 lines);
   // that frame is torn either way (scene-load frames are window-blanked anyway).
   SNAP_IDLE:if(snapshot || snapshot_pending || queue_full)begin
    snapshot_pending<=0;
    snapshot_end<=write_pointer;
    if(read_pointer==write_pointer)snapshot_done<=1;
    else begin snapshot_busy<=1;snapshot_state<=SNAP_FETCH;end
   end
   SNAP_FETCH:snapshot_state<=SNAP_WRITE;
   SNAP_WRITE:if(is_alias(queued_address))snapshot_state<=SNAP_MIRROR;
              else begin
               read_pointer<=read_pointer+1'b1;
               if(read_pointer+1'b1==snapshot_end)begin snapshot_busy<=0;snapshot_done<=1;snapshot_state<=SNAP_IDLE;end
               else snapshot_state<=SNAP_FETCH;
              end
   SNAP_MIRROR:begin
    read_pointer<=read_pointer+1'b1;
    if(read_pointer+1'b1==snapshot_end)begin snapshot_busy<=0;snapshot_done<=1;snapshot_state<=SNAP_IDLE;end
    else snapshot_state<=SNAP_FETCH;
   end
  endcase
  end
 end
endmodule
