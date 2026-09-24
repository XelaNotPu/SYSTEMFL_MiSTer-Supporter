// SPDX-License-Identifier: GPL-3.0-or-later
// System FL C169 parameter RAM, affine scanline walker and immutable ROM-row cache.
// Layers are emitted in reference order (1 then 0); the caller mixes priorities.
module fl_c169(
    input wire clk,reset,
    input wire cpu_req,cpu_write,cpu_control,input wire [16:0] cpu_addr,
    input wire [31:0] cpu_data,input wire [3:0] cpu_be,
    output reg cpu_ready,output wire [31:0] cpu_q,
    input wire start,input wire [8:0] line_y,
    output reg busy,done,
    output wire paint,solid,output wire [8:0] paint_x,
    output wire [12:0] pen,output wire [3:0] priority_value,
    output reg rom_req,output reg [25:0] rom_addr,
    input wire rom_ready,input wire [31:0] rom_data,input wire [127:0] rom_data_wide,
    // High while the current paint pass writes into a known-empty line buffer
    // (layer 1, or layer 0 with layer 1 disabled): the compositor may skip its
    // registered old-pixel priority read, which lets this walker paint 1 px/clk.
    output wire overwrite,
    // High with a ROM request that will be followed immediately by the next
    // sequential word of the same tile row (4 pixel words + mask): lets the bus
    // arbiter hold the grant so the row costs one round of contention, not five.
    output wire rom_lock,
    // Valid with `done`: layer 0 painted every one of the 288 pixels of this line
    // solid (line_full) and at which priority (line_pri). The tile compositor uses
    // this (from the previous composition of that row) to skip C123 layers the
    // opaque road hides.
    output wire line_full,output wire [3:0] line_pri,
    // --- h_road debug: discriminate why the per-line road (layer 0) is absent ---
    output wire [15:0] dbg_mode,dbg_attr0,          // control[0] (mode), control[1] (layer0 attrs)
    output reg  [15:0] dbg_pline_attr,dbg_pline_sx, // sampled per-line params[1]/[6] at y=120
    output reg  [31:0] dbg_road_lines,              // road per-line path entered
    output reg  [31:0] dbg_road_posv,               // layer0 PAINT with position_valid
    output reg  [31:0] dbg_road_solid,              // layer0 PAINT with solid
    output reg  [31:0] dbg_grass_solid              // layer1 PAINT with solid (positive control)
);
    assign dbg_mode=control[0];
    assign dbg_attr0=control[1];
    `include "rtl/fl_rom_layout.svh"
    reg [15:0] control[0:15],params[0:7];
    reg seen,control_read;
    reg [31:0] control_q;
    reg [15:0] read_word;
    wire [7:0] cpu_bytes[0:3],map_bytes[0:3];
    wire [31:0] map_q={map_bytes[3],map_bytes[2],map_bytes[1],map_bytes[0]};
    wire [15:0] map_code=read_word[0]?map_q[31:16]:map_q[15:0];
    wire access_now=cpu_req && !seen && !reset;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: vram_lane
        fl_video_ram #(.ADDR_WIDTH(15)) storage(
            .clk(clk),.enable_a(access_now && !cpu_control),
            .write_a(cpu_write && cpu_be[lane]),.address_a(cpu_addr[16:2]),
            .address_b(read_word[15:1]),.data_a(cpu_data[8*lane+:8]),
            .q_a(cpu_bytes[lane]),.q_b(map_bytes[lane]));
    end endgenerate
    assign cpu_q=control_read?control_q:{cpu_bytes[3],cpu_bytes[2],cpu_bytes[1],cpu_bytes[0]};
    integer i;
    always @(posedge clk) begin
        cpu_ready<=0;
        if(reset) begin
            seen<=0;control_read<=0;control_q<=0;
            for(i=0;i<16;i=i+1) control[i]<=0;
        end else begin
            if(!cpu_req) seen<=0;
            if(access_now) begin
                seen<=1;cpu_ready<=1;control_read<=cpu_control;
                if(cpu_control) begin
                    control_q<={control[{cpu_addr[4:2],1'b1}],control[{cpu_addr[4:2],1'b0}]};
                    if(cpu_write) begin
                        if(cpu_be[0]) control[{cpu_addr[4:2],1'b0}][7:0]<=cpu_data[7:0];
                        if(cpu_be[1]) control[{cpu_addr[4:2],1'b0}][15:8]<=cpu_data[15:8];
                        if(cpu_be[2]) control[{cpu_addr[4:2],1'b1}][7:0]<=cpu_data[23:16];
                        if(cpu_be[3]) control[{cpu_addr[4:2],1'b1}][15:8]<=cpu_data[31:24];
                    end
                end
            end
        end
    end
    reg [4:0] state;
    localparam IDLE=0,SELECT=1,PARAM_WAIT=2,PARAM_GET=3,AFFINE=4,CHECK=5,
        MAP_WAIT=6,MAP_GET=7,ROW_CHECK=8,CACHE_WAIT=9,CACHE_GET=10,
        PIXELS=11,RELEASE_PIXELS=12,MASK=13,RELEASE_MASK=14,PAINT=15,NEXT=16;
    reg layer;
    reg map_pending; // map word for the next tile was requested from PAINT (prefetch)
    reg scanline_mode; // current pass walks a per-scanline record (layer 0, control[0]==0x8000)
    assign overwrite=layer || control[9][15];
    reg [8:0] road_solid_count; // solid pixels painted by layer 0 on the current line
    assign line_full=road_solid_count==9'd288;
    assign line_pri=params[1][7:4];
    reg [8:0] draw_y;
    reg [1:0] param_pair;
    wire [16:0] line_params=17'('he080)+({11'd0,draw_y[8:3]}<<8)+({14'd0,draw_y[2:0]}<<4);
    wire affine_busy,affine_done,position_valid,next_opaque;
    wire [11:0] source_x,source_y,next_source_x,next_source_y;
    wire [2:0] color;
    fl_c169_affine coordinates(.clk(clk),.reset(reset),.start(state==AFFINE),.consume(state==PAINT),
        .screen_y(draw_y),.scanline(scanline_mode),.word0(params[0]),
        .attributes(params[1]),.incxx(params[2]),.incxy(params[3]),
        .incyx(params[4]),.incyy(params[5]),.startx(params[6]),.starty(params[7]),
        .busy(affine_busy),.done(affine_done),.screen_x(paint_x),
        .source_x(source_x),.source_y(source_y),.opaque_position(position_valid),
        .next_source_x(next_source_x),.next_source_y(next_source_y),.next_opaque(next_opaque),
        .priority_value(priority_value),.color(color));
    wire [15:0] tile_address={source_x[11],source_y[11:4],source_x[10:4]};
    wire [15:0] next_tile_address={next_source_x[11],next_source_y[11:4],next_source_x[10:4]};
    // Row-cache index: fold the upper code bits into the 5 tile bits so tiles that
    // share code[4:0] along one scanline (the far road) stop evicting each other.
    // Tag code[13:5] still identifies the tile uniquely given the index.
    function automatic [4:0] cache_hash(input [13:0] t);
        cache_hash=t[4:0]^t[9:5]^{1'b0,t[13:10]};
    endfunction
    reg [15:0] last_map;
    reg map_valid,row_valid;
    reg [13:0] tile;
    reg [17:0] last_row;
    reg [127:0] pixels;
    reg [15:0] mask;
    // 512-entry row cache: index {hashed tile[4:0], source_y[3:0]}, tag tile[13:5].
    // (Measured: 256 entries {hash, row[2:0]} cost +10% road ROM words on the real
    // race frame -- the slowly advancing near/mid rows do reuse rows across lines.)
    reg [152:0] row_cache[0:511];
    reg [511:0] cache_valid;
    reg [8:0] cache_address;   // registered copy: write address for the fill in MASK
    reg [152:0] cache_q;
    reg cache_hit_valid;
    // Read address is presented combinationally in the state that learns the tile
    // (MAP_GET) or the row (ROW_CHECK), so cache_q is valid one state later without
    // a separate wait state.
    wire [8:0] cache_rd_address=state==MAP_GET ? {cache_hash(map_code[13:0]),source_y[3:0]} :
                                state==ROW_CHECK ? {cache_hash(tile),source_y[3:0]} : cache_address;
    always @(posedge clk) begin
        cache_q<=row_cache[cache_rd_address];cache_hit_valid<=cache_valid[cache_rd_address];
    end
    wire [15:0] mask_row=source_y[0]?{rom_data[23:16],rom_data[31:24]}:{rom_data[7:0],rom_data[15:8]};
    // Per-tile MASK-BLOCK cache: the mask fetch's wide read brings a 16-byte block =
    // 8 rows of one tile's mask (RSHAPE: 2 bytes/row, 32 bytes/tile), so a tile met
    // again on the next scanlines (a different source row, the far road's usual
    // case) needs only the pixel-row read. Index {hash(tile), source_y[3]} (64
    // entries), tag tile[13:5]. Read in CACHE_GET, checked after the pixel read.
    (* ramstyle = "MLAB, no_rw_check" *) reg [136:0] mask_cache[0:63];
    reg [63:0] mask_cache_valid;
    reg [5:0] mask_address;
    reg [136:0] mask_q;
    reg mask_hit_valid;
    wire [5:0] mask_rd_address=state==CACHE_GET ? {cache_hash(tile),source_y[3]} : mask_address;
    always @(posedge clk) begin
        mask_q<=mask_cache[mask_rd_address];mask_hit_valid<=mask_cache_valid[mask_rd_address];
    end
    wire mask_hit=mask_hit_valid && mask_q[136:128]==tile[13:5];
    // row r of the block = bytes 2r,2r+1, in the same swapped order as mask_row
    wire [15:0] mask_from_block={mask_q[16*source_y[2:0]+:8],mask_q[16*source_y[2:0]+8+:8]};
    assign paint=state==PAINT;
    // The 16-byte pixel row is ONE wide read (rom_data_wide); when the mask block is
    // not cached the mask word follows, so the pixel request holds the grant for it.
    assign rom_lock=state==PIXELS || (state==RELEASE_PIXELS && !mask_hit);
    assign solid=paint && position_valid && mask[15-source_x[3:0]];
    assign pen={2'b11,color,pixels[8*source_x[3:0]+:8]};
    integer parameter_index;
    always @(posedge clk) begin
        done<=0;
        if(reset) begin
            state<=IDLE;busy<=0;done<=0;rom_req<=0;rom_addr<=0;layer<=0;draw_y<=0;
            param_pair<=0;read_word<=0;last_map<=0;last_row<=0;
            map_valid<=0;row_valid<=0;tile<=0;pixels<=0;mask<=0;map_pending<=0;road_solid_count<=0;scanline_mode<=0;
            cache_valid<=0;mask_cache_valid<=0;mask_address<=0;cache_address<=0;
            dbg_pline_attr<=0;dbg_pline_sx<=0;dbg_road_lines<=0;
            dbg_road_posv<=0;dbg_road_solid<=0;dbg_grass_solid<=0;
            for(parameter_index=0;parameter_index<8;parameter_index=parameter_index+1) params[parameter_index]<=0;
        end else begin
            case(state)
                IDLE:if(start) begin draw_y<=line_y;layer<=1;busy<=1;state<=SELECT;end
                SELECT:begin
                    map_valid<=0;row_valid<=0;map_pending<=0;
                    if(!layer) road_solid_count<=0;
                    if(control[{layer,3'b001}][15]) state<=NEXT;
                    else if(!layer && control[0]==16'h8000) begin
                        read_word<=line_params[16:1];param_pair<=0;state<=PARAM_WAIT;
                        scanline_mode<=1;
                        dbg_road_lines<=dbg_road_lines+1'b1;
                    end else begin
                        for(parameter_index=0;parameter_index<8;parameter_index=parameter_index+1)
                            params[parameter_index]<=control[(layer?8:0)+parameter_index];
                        scanline_mode<=0;state<=AFFINE;
                    end
                end
                PARAM_WAIT:state<=PARAM_GET;
                PARAM_GET:begin
                    params[{param_pair,1'b0}]<=map_q[15:0];params[{param_pair,1'b1}]<=map_q[31:16];
                    if(param_pair==3) state<=AFFINE;
                    else begin read_word<=read_word+2;param_pair<=param_pair+1'b1;state<=PARAM_WAIT;end
                end
                AFFINE:state<=CHECK;
                CHECK:begin
                    if(!position_valid) state<=PAINT;
                    else if(map_pending) state<=MAP_GET; // prefetched from PAINT; this state is the RAM wait
                    else if(map_valid && last_map==tile_address)
                        state<=row_valid && last_row=={tile,source_y[3:0]} ? PAINT : ROW_CHECK;
                    else begin read_word<=tile_address;last_map<=tile_address;state<=MAP_WAIT;end
                end
                MAP_WAIT:state<=MAP_GET;
                MAP_GET:begin
                    tile<=map_code[13:0];map_valid<=1;map_pending<=0;
                    // Adjacent map cells often repeat the same code: the loaded row still applies.
                    if(row_valid && last_row=={map_code[13:0],source_y[3:0]}) state<=PAINT;
                    else begin
                        cache_address<={cache_hash(map_code[13:0]),source_y[3:0]};
                        last_row<={map_code[13:0],source_y[3:0]};
                        row_valid<=0;state<=CACHE_GET; // read issued this cycle via cache_rd_address
                    end
                end
                ROW_CHECK:begin
                    if(row_valid && last_row=={tile,source_y[3:0]}) state<=PAINT;
                    else begin
                        cache_address<={cache_hash(tile),source_y[3:0]};last_row<={tile,source_y[3:0]};
                        row_valid<=0;state<=CACHE_GET; // read issued this cycle via cache_rd_address
                    end
                end
                CACHE_WAIT:state<=CACHE_GET;
                CACHE_GET:begin
                    if(cache_hit_valid && cache_q[152:144]==tile[13:5]) begin
                        pixels<=cache_q[143:16];mask<=cache_q[15:0];row_valid<=1;state<=PAINT;
                    end else begin
                        rom_addr<=`FL_C169ROZ_BASE+{5'd0,tile[12:0],source_y[3:0],4'b0000};
                        rom_req<=1;state<=PIXELS;
                        mask_address<={cache_hash(tile),source_y[3]};   // mask block read issued now
                    end
                end
                PIXELS:if(rom_ready) begin
                    pixels<=rom_data_wide;rom_req<=0;state<=RELEASE_PIXELS;   // whole 16-byte row
                end
                RELEASE_PIXELS:if(!rom_ready) begin
                    if(mask_hit) begin
                        mask<=mask_from_block;row_valid<=1;
                        row_cache[cache_address]<={tile[13:5],pixels,mask_from_block};cache_valid[cache_address]<=1;
                        state<=PAINT;
                    end else begin
                        rom_req<=1;rom_addr<=`FL_C169ROZ_MASK_BASE+{7'd0,tile,source_y[3:1],2'b00};state<=MASK;
                    end
                end
                MASK:if(rom_ready) begin
                    mask<=mask_row;rom_req<=0;row_valid<=1;
                    row_cache[cache_address]<={tile[13:5],pixels,mask_row};cache_valid[cache_address]<=1;
                    mask_cache[mask_address]<={tile[13:5],rom_data_wide};mask_cache_valid[mask_address]<=1;
                    state<=RELEASE_MASK;
                end
                RELEASE_MASK:if(!rom_ready) state<=PAINT;
                PAINT:begin
                    if(paint_x==287) state<=NEXT;
                    // Fast path: next pixel stays in the loaded tile row and the buffer is
                    // known-empty (overwrite) -> paint back-to-back, 1 px/clk.
                    else if(overwrite && next_opaque && map_valid && last_map==next_tile_address
                            && row_valid && last_row=={tile,next_source_y[3:0]}) state<=PAINT;
                    else begin
                        // Tile crossing: request the next map word now so CHECK is the wait.
                        if(next_opaque && !(map_valid && last_map==next_tile_address)) begin
                            read_word<=next_tile_address;last_map<=next_tile_address;map_pending<=1;
                        end
                        state<=CHECK;
                    end
                end
                NEXT:if(layer) begin layer<=0;state<=SELECT;end
                     else begin busy<=0;done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
            if(access_now && cpu_write && !cpu_control) map_valid<=0;
            // h_road: sample the mid-screen line's per-line attrs/startx once loaded
            if(!layer && state==AFFINE && draw_y==9'd120) begin
                dbg_pline_attr<=params[1];dbg_pline_sx<=params[6];
            end
            // h_road: per-layer PAINT tallies (position_valid / solid / grass control)
            if(state==PAINT) begin
                if(!layer) begin
                    if(solid) road_solid_count<=road_solid_count+1'b1;
                    if(position_valid) dbg_road_posv<=dbg_road_posv+1'b1;
                    if(solid)          dbg_road_solid<=dbg_road_solid+1'b1;
                end else if(solid) dbg_grass_solid<=dbg_grass_solid+1'b1;
            end
        end
    end
endmodule
