// SPDX-License-Identifier: GPL-3.0-or-later
// C123-only scanline compositor. Eight banks paint a tile run in parallel.
// A line becomes visible only if fully composed before its raster deadline.
// Missing lines are black and counted; they never display stale buffer data.
//
// Greedy four-line buffer: the compositor composes ahead of the raster (up to
// three lines) into a mod-4 buffer, banking a lead during cheap lines so an
// occasional over-budget line is drawn from the lead instead of dropped black.
// The three-ahead bound keeps composition off the one slot the raster is
// reading, so there is no read/write collision (same guarantee as the prior
// parity double-buffer, which composed one line ahead into the opposite slot).
module fl_tile_video(
    input wire clk,reset,line_start,input wire [8:0] x,y,
    input wire cpu_req,cpu_write,cpu_control,input wire [15:0] cpu_addr,
    input wire [31:0] cpu_data,input wire [3:0] cpu_be,
    output wire cpu_ready,output wire [31:0] cpu_q,
    output wire rom_req,output wire [25:0] rom_addr,
    input wire rom_ready,input wire [31:0] rom_data,input wire [127:0] rom_data_wide,
    output wire [12:0] pen,output wire [3:0] pixel_priority,output wire pixel_valid,
    output reg [31:0] missed_lines,output reg [31:0] completed_lines,
    output wire rom_lock,
    output wire [2:0] lead,
    // Road coverage query: which row we are composing -> {road fully solid, road pri}
    // (registered in fl_road_video). Layers with 2*pri < road pri are invisible on
    // a fully solid road row, so they are skipped entirely (no map/mask/pixel fetch).
    output wire [8:0] road_query_y,input wire [4:0] road_row_q
);
    wire draw_req;
    wire [7:0] uncovered;
    wire draw_skip=!(|uncovered);
    reg [2:0] layer;
    reg [8:0] draw_x,draw_y;
    wire draw_ready,draw_busy,reverse;
    wire [63:0] pixels;
    wire [7:0] opaque;
    wire [2:0] phase,color;
    wire [3:0] priority_value;
    fl_c123 tiles(.clk(clk),.reset(reset),.cpu_req(cpu_req),.cpu_write(cpu_write),
        .cpu_control(cpu_control),.cpu_addr(cpu_addr),.cpu_data(cpu_data),.cpu_be(cpu_be),
        .cpu_ready(cpu_ready),.cpu_q(cpu_q),.draw_req(draw_req),.draw_skip(draw_skip),.layer(req_layer),.x(req_x),.y(draw_y),
        .draw_busy(draw_busy),.draw_ready(draw_ready),.pixels(pixels),.opaque(opaque),
        .phase(phase),.color(color),.reverse(reverse),.priority_value(priority_value),
        .rom_req(rom_req),.rom_addr(rom_addr),.rom_ready(rom_ready),.rom_data(rom_data),.rom_data_wide(rom_data_wide),
        .rom_lock(rom_lock),.layer_disabled(layer_disabled),.layer_pri(layer_pri));
    wire [5:0] layer_disabled;
    wire [17:0] layer_pri;
    // Layer skipping. A disabled layer costs a 4-clock dummy request per 8-px run
    // (216 requests/line total); a layer under a fully solid road row is invisible
    // (MAME draws C123 layer pri p at pass 2p, the road line at its own pri). Skip
    // both at the layer level. road_row_q is registered on draw_y, valid from the
    // second CLEAR cycle, i.e. long before the first ISSUE.
    assign road_query_y=draw_y;
    wire road_full=road_row_q[4];
    wire [3:0] road_pri=road_row_q[3:0];
    wire [5:0] layer_skip;
    genvar sl;
    generate for(sl=0;sl<6;sl=sl+1) begin: skip_bits
        assign layer_skip[sl]=layer_disabled[sl] || (road_full && {layer_pri[3*sl+:3],1'b0}<road_pri);
    end endgenerate
    // Highest layer index <= from that is not skipped; 7 when none.
    function automatic [2:0] pick_layer(input [2:0] from,input [5:0] skip);
        integer k;
        begin
            pick_layer=3'd7;
            for(k=0;k<6;k=k+1) if(k<=from && !skip[k]) pick_layer=k[2:0];
        end
    endfunction
    reg [2:0] state;
    localparam IDLE=0,CLEAR=1,ISSUE=2,WAIT_ROW=3,PAINT=4,FINISH=5;
    // Lines of slack until the raster reaches the line being composed: the SDRAM
    // arbiter's deadline urgency (0 = due now .. 7 = relaxed; 7 while idle).
    wire [8:0] lead_lines=draw_y>=y ? draw_y-y : draw_y+9'd264-y;
    assign lead=state==IDLE ? 3'd7 : (lead_lines>9'd7 ? 3'd7 : lead_lines[2:0]);
    reg [5:0] clear_chunk;
    reg [8:0] buffer_line[0:3];
    reg [3:0] buffer_valid;
    reg [8:0] compose_line;
    reg display_valid;
    reg [2:0] display_lane;
    integer bi;
    wire [8:0] next_line=y==263 ? 9'd0 : y+1'b1;
    // Compose the next line, snapped forward to y+1 if it fell behind the raster
    // in the visible frame, bounded to <=3 lines ahead during the visible frame
    // (the read slot is y[1:0]; y+1..y+3 map to the other three slots). During
    // vblank the compositor freely pre-fills the next frame's first lines; the
    // slot-valid check naturally caps that pre-fill at four.
    wire [8:0] compose_target=(y<9'd224 && compose_line<(y+9'd1)) ? (y+9'd1) : compose_line;
    wire compose_go=compose_target<9'd224 && !buffer_valid[compose_target[1:0]]
                    && (y>=9'd224 || compose_target<=(y+9'd3));
    wire [3:0] available=reverse ? {1'b0,phase}+4'd1 : 4'd8-{1'b0,phase};
    wire [8:0] remaining=9'd288-draw_x;
    wire [3:0] run_length=remaining<{5'd0,available} ? remaining[3:0] : available;
    // Three-clock request loop (was five): the run is painted in the very cycle
    // draw_ready is seen, and the next run's request is asserted combinationally in
    // that same cycle with its x/layer presented as wires, so fl_c123 (already back
    // in IDLE) latches it immediately: request -> MAP_GET -> CACHE_GET -> paint+request.
    // old_pixel for the run is valid by then (its address settled at the request edge).
    wire run_end=draw_x+{5'd0,run_length}==9'd288;
    wire [2:0] lower_layer=pick_layer(layer-3'd1,layer_skip);
    wire finish_line=run_end && (layer==3'd0 || lower_layer==3'd7);
    wire [8:0] next_x=run_end ? 9'd0 : draw_x+{5'd0,run_length};
    wire [2:0] next_layer=run_end ? lower_layer : layer;
    wire paint_now=state==WAIT_ROW && draw_ready;
    assign draw_req=state==ISSUE || (paint_now && !finish_line);
    wire [8:0] req_x=state==ISSUE ? draw_x : next_x;
    wire [2:0] req_layer=state==ISSUE ? layer : next_layer;
    wire [17:0] screen_pixel[0:7];
    genvar bank;
    generate for(bank=0;bank<8;bank=bank+1) begin: line_bank
        wire [17:0] old_pixel,screen_q;
        wire [2:0] ordinal=3'(bank)-draw_x[2:0];
        wire [8:0] destination=draw_x+{6'd0,ordinal};
        wire [7:0] paint_address={draw_y[1:0],destination[8:3]};
        wire [2:0] source_pixel=reverse ? phase-ordinal : phase+ordinal;
        wire [7:0] pixel_color=pixels[8*source_pixel+:8];
        wire solid=opaque[7-source_pixel];
        assign screen_pixel[bank]=screen_q;
        // Visit higher layer indices first, preserving their tie precedence.
        // Old line-buffer pixels are available before the tile-cache lookup.
        assign uncovered[bank]={1'b0,ordinal}<run_length &&
            (!old_pixel[17] || priority_value>old_pixel[16:13]);
        wire paint=paint_now && uncovered[bank] && solid;
        fl_dual_read_ram #(.ADDR_WIDTH(8),.DATA_WIDTH(18)) storage(
            .clk(clk),.enable_a(1'b1),.write_a(!reset && (state==CLEAR || paint)),
            .address_a(state==CLEAR ? {draw_y[1:0],clear_chunk} : paint_address),
            .address_b({y[1:0],x[8:3]}),
            .data_a(state==CLEAR ? 18'd0 : {1'b1,priority_value,2'b10,color,pixel_color}),
            .q_a(old_pixel),.q_b(screen_q));
    end endgenerate
    assign pixel_priority=screen_pixel[display_lane][16:13];
    assign pen=screen_pixel[display_lane][12:0];
    assign pixel_valid=display_valid && x<288 && y<224 && screen_pixel[display_lane][17];
    always @(posedge clk) begin
        display_lane<=x[2:0];
        if(reset) begin
            state<=IDLE;draw_x<=0;draw_y<=0;layer<=5;clear_chunk<=0;
            buffer_valid<=0;for(bi=0;bi<4;bi=bi+1) buffer_line[bi]<=0;
            display_valid<=0;missed_lines<=0;completed_lines<=0;compose_line<=0;
        end else begin
            if(line_start) begin
                display_valid<=next_line<224 && buffer_valid[next_line[1:0]] && buffer_line[next_line[1:0]]==next_line;
                if(next_line<224 && !(buffer_valid[next_line[1:0]] && buffer_line[next_line[1:0]]==next_line))
                    missed_lines<=missed_lines+1'b1;
            end
            case(state)
                IDLE:if(compose_go) begin
                    draw_y<=compose_target;draw_x<=0;layer<=5;clear_chunk<=0;
                    compose_line<=compose_target+9'd1;state<=CLEAR;
                end
                CLEAR:if(clear_chunk==35) begin
                    // Start at the highest drawable layer; none -> the line is empty.
                    if(pick_layer(3'd5,layer_skip)==3'd7) state<=FINISH;
                    else begin layer<=pick_layer(3'd5,layer_skip);state<=ISSUE;end
                end else clear_chunk<=clear_chunk+1'b1;
                // draw_req is a wire: high during ISSUE, and during the paint cycle
                // (WAIT_ROW && draw_ready) unless the line is finished. The banks paint
                // in that same cycle; the next run's x/layer are already on the request.
                ISSUE:state<=WAIT_ROW;
                WAIT_ROW:if(draw_ready) begin
                    if(finish_line) begin draw_x<=0;state<=FINISH;end
                    else begin draw_x<=next_x;layer<=next_layer;end
                end
                FINISH:begin
                    buffer_line[draw_y[1:0]]<=draw_y;buffer_valid[draw_y[1:0]]<=1;
                    completed_lines<=completed_lines+1'b1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
            // Consume the slot of the line about to be displayed (its data persists
            // for the scanline; display_valid was latched above). Reset the compose
            // pointer in deep vblank so the next frame pre-fills from line 0.
            if(line_start && next_line<224) buffer_valid[next_line[1:0]]<=0;
            if(line_start && y==9'd255) compose_line<=0;
        end
    end
endmodule
