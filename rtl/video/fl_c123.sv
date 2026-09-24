// SPDX-License-Identifier: GPL-3.0-or-later
// System FL C123: four 64x64 scrolling and two 36x28 fixed tilemaps.
// Independent implementation from the pinned MAME C123 behavior.
// CPU aperture is 64 KiB, with little-endian 16-bit tile/control words.
// A draw request returns one 8-pixel source row plus its starting phase.
// Caller consumes phase..7 (or phase..0 when reversed), then requests again.
// Pixel colors are meaningful only where opaque is set; empty rows return zero.
module fl_c123(
    input wire clk,reset,
    input wire cpu_req,cpu_write,cpu_control,input wire [15:0] cpu_addr,
    input wire [31:0] cpu_data,input wire [3:0] cpu_be,
    output reg cpu_ready,output wire [31:0] cpu_q,
    input wire draw_req,draw_skip,input wire [2:0] layer,input wire [8:0] x,y,
    output wire draw_busy,output reg draw_ready,
    output reg [63:0] pixels,output reg [7:0] opaque,
    output reg [2:0] phase,color,output reg reverse,
    output reg [3:0] priority_value,
    output reg rom_req,output reg [25:0] rom_addr,
    input wire rom_ready,input wire [31:0] rom_data,input wire [127:0] rom_data_wide,
    // Bus-grant hold: a tile row is mask -> pixel lo -> pixel hi, issued back to
    // back; holding the grant makes the row one round of contention, not three.
    output wire rom_lock,
    // Per-layer control bits for the compositor's layer skipping.
    output wire [5:0] layer_disabled,   // control[0x20/2+l] bit 3
    output wire [17:0] layer_pri        // {control[0x20/2+l][2:0]} x6, layer 0 in bits [2:0]
);
    `include "rtl/fl_rom_layout.svh"
    reg [15:0] control[0:31];
    reg seen,control_read;
    reg [31:0] control_q;
    wire access_now=cpu_req && !seen && !reset;
    wire [7:0] cpu_bytes[0:3];
    wire [7:0] map_bytes[0:3];
    reg [14:0] map_address;
    wire [14:0] requested_map=layer<4 ? {1'b0,layer[1:0],source_y[8:3],source_x[8:3]} :
        (layer==4 ? 15'h4008 : 15'h4408)+({9'd0,source_y[8:3]}<<5)+
        ({9'd0,source_y[8:3]}<<2)+{9'd0,source_x[8:3]};
    // Present the next address before its capture edge, retaining the same
    // one-clock RAM latency without an extra address-register wait state.
    wire [14:0] map_read_address=state==IDLE && draw_req ? requested_map : map_address;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: vram_lane
        fl_video_ram #(.ADDR_WIDTH(14)) storage(
            .clk(clk),.enable_a(access_now && !cpu_control),
            .write_a(cpu_write && cpu_be[lane]),.address_a(cpu_addr[15:2]),
            .address_b(map_read_address[14:1]),.data_a(cpu_data[8*lane+:8]),
            .q_a(cpu_bytes[lane]),.q_b(map_bytes[lane]));
    end endgenerate
    assign cpu_q=control_read ? control_q : {cpu_bytes[3],cpu_bytes[2],cpu_bytes[1],cpu_bytes[0]};
    integer i;
    always @(posedge clk) begin
        cpu_ready<=0;
        if(reset) begin
            seen<=0; control_read<=0; control_q<=0;
            for(i=0;i<32;i=i+1) control[i]<=0;
        end else begin
            if(!cpu_req) seen<=0;
            if(access_now) begin
                seen<=1;cpu_ready<=1;control_read<=cpu_control;
                if(cpu_control) begin
                    control_q<={control[{cpu_addr[5:2],1'b1}],control[{cpu_addr[5:2],1'b0}]};
                    if(cpu_write) begin
                        if(cpu_be[0]) control[{cpu_addr[5:2],1'b0}][7:0]<=cpu_data[7:0];
                        if(cpu_be[1]) control[{cpu_addr[5:2],1'b0}][15:8]<=cpu_data[15:8];
                        if(cpu_be[2]) control[{cpu_addr[5:2],1'b1}][7:0]<=cpu_data[23:16];
                        if(cpu_be[3]) control[{cpu_addr[5:2],1'b1}][15:8]<=cpu_data[31:24];
                    end
                end
            end
        end
    end
    reg [8:0] source_x,source_y;
    reg [5:0] offset_x;
    wire flip=control[1][15];
    always @* begin
        case(layer)
            0:offset_x=48;1:offset_x=46;2:offset_x=45;default:offset_x=44;
        endcase
        if(layer<4) begin
            source_x=x+control[{layer[1:0],2'b01}][8:0]+{3'd0,offset_x};
            source_y=y+control[{layer[1:0],2'b11}][8:0]+9'd24;
            if(flip) begin source_x=~source_x;source_y=~source_y;end
        end else begin
            source_x=flip ? 9'd287-x : x;
            source_y=flip ? 9'd223-y : y;
        end
    end
    // Immutable ROM rows share a direct-mapped cache across all six layers.
    // Validity resets on core reset (including any ROM download).
    // 256 entries (was 512): index {code[4:0],row}, tag code[15:5]. The C123 audit measured
    // conflict re-fetches at 0.25% of words with 512 entries; halving returns 2 M10K.
    reg [82:0] row_cache[0:255]; // tag[10:0], eight colors, eight mask bits
    reg [255:0] cache_valid;
    reg [7:0] cache_address;
    reg [82:0] cache_q;
    reg cache_hit_valid;
    wire [7:0] cache_read_address=state==MAP_GET ? {map_code[4:0],row} : cache_address;
    always @(posedge clk) begin
        cache_q<=row_cache[cache_read_address];cache_hit_valid<=cache_valid[cache_read_address];
    end
    // A mask word covers four source rows. Retain it independently from
    // pixel rows so adjacent scanlines do not refetch the same immutable word.
    reg [39:0] mask_cache[0:511];
    reg [511:0] mask_valid;
    reg [39:0] mask_q;
    reg mask_q_valid;
    wire [8:0] mask_address=state==MAP_GET ? {map_code[7:0],row[2]} : {tile[7:0],row[2]};
    always @(posedge clk) begin
        mask_q<=mask_cache[mask_address];mask_q_valid<=mask_valid[mask_address];
    end
    reg [2:0] row;
    reg [15:0] tile;
    wire [15:0] map_code=map_address[0] ? {map_bytes[3],map_bytes[2]} : {map_bytes[1],map_bytes[0]};
    reg [3:0] state;
    localparam IDLE=0,MAP_WAIT=1,MAP_GET=2,PIXEL_LO=3,RELEASE_LO=4,
        PIXEL_HI=5,RELEASE_HI=6,MASK=7,RELEASE_MASK=8,DONE=9,CACHE_WAIT=10,CACHE_GET=11;
    assign draw_busy=state!=IDLE;
    // MASK/PIXEL_LO are each followed by another word of the same row (PIXEL_HI is last).
    // The 8-byte pixel row is ONE wide read (rom_data_wide, low or high half of the
    // 16-byte block by rom_addr[3]); only the mask word, which a pixel read may
    // follow, holds the grant.
    assign rom_lock=state==MASK || state==RELEASE_MASK;
    genvar lyr;
    generate for(lyr=0;lyr<6;lyr=lyr+1) begin: layer_bits
        assign layer_disabled[lyr]=control[16+lyr][3];
        assign layer_pri[3*lyr+:3]=control[16+lyr][2:0];
    end endgenerate
    always @(posedge clk) begin
        draw_ready<=0;
        if(reset) begin
            cache_valid<=0;mask_valid<=0;cache_address<=0;state<=IDLE;rom_req<=0;rom_addr<=0;map_address<=0;
            pixels<=0;opaque<=0;phase<=0;reverse<=0;color<=0;priority_value<=0;row<=0;tile<=0;
        end else case(state)
            IDLE:if(draw_req) begin
                phase<=source_x[2:0];row<=source_y[2:0];reverse<=flip;
                color<=control[24+layer][2:0];priority_value<={control[16+layer][2:0],1'b0};
                if(layer>=6 || x>=288 || y>=224 || control[16+layer][3]) begin
                    opaque<=0;pixels<=0;state<=DONE;
                end else begin
                    map_address<=requested_map;state<=MAP_GET;
                end
            end
            MAP_GET:begin
                tile<=map_code;cache_address<={map_code[4:0],row};state<=CACHE_GET;
            end
            CACHE_GET:begin
                opaque<=mask_q[31:0]>>(8*row[1:0]);
                // The compositor may already cover this complete run with
                // higher-priority pixels. Do not cache this visibility result.
                if(draw_skip) begin
                    pixels<=0;opaque<=0;draw_ready<=1;state<=IDLE;
                end else if(cache_hit_valid && cache_q[82:72]==tile[15:5]) begin
                    pixels<=cache_q[71:8];opaque<=cache_q[7:0];draw_ready<=1;state<=IDLE;
                end else if(mask_q_valid && mask_q[39:32]==tile[15:8]) begin
                    if((8'(mask_q[31:0]>>(8*row[1:0])))==0) begin
                        pixels<=0;opaque<=0;draw_ready<=1;state<=IDLE;
                        row_cache[cache_address]<={tile[15:5],72'd0};cache_valid[cache_address]<=1;
                    end else begin
                        rom_addr<=`FL_C123TMAP_BASE+{4'd0,tile,row,3'b000};rom_req<=1;state<=PIXEL_LO;
                    end
                end else begin
                    rom_addr<=`FL_C123TMAP_MASK_BASE+{7'd0,tile,row[2],2'b00};rom_req<=1;state<=MASK;
                end
            end
            MASK:if(rom_ready) begin
                mask_cache[{tile[7:0],row[2]}]<={tile[15:8],rom_data};
                mask_valid[{tile[7:0],row[2]}]<=1;
                opaque<=rom_data>>(8*row[1:0]);rom_req<=0;state<=RELEASE_MASK;
            end
            RELEASE_MASK:if(!rom_ready) begin
                if(opaque==0) begin
                    pixels<=0;draw_ready<=1;state<=IDLE;
                    row_cache[cache_address]<={tile[15:5],72'd0};cache_valid[cache_address]<=1;
                end else begin
                    rom_addr<=`FL_C123TMAP_BASE+{4'd0,tile,row,3'b000};rom_req<=1;state<=PIXEL_LO;
                end
            end
            PIXEL_LO:if(rom_ready) begin
                pixels<=rom_addr[3] ? rom_data_wide[127:64] : rom_data_wide[63:0];rom_req<=0;state<=RELEASE_LO;
            end
            RELEASE_LO:if(!rom_ready) begin
                row_cache[cache_address]<={tile[15:5],pixels,opaque};cache_valid[cache_address]<=1;
                draw_ready<=1;state<=IDLE;
            end
            DONE:begin draw_ready<=1;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
