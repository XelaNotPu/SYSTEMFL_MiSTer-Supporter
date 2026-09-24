// SPDX-License-Identifier: GPL-3.0-or-later
// System FL C169 scanline coordinate generator. Fixed point has eight fraction
// bits (MAME normalizes these same values by another <<8 for its 16.16 API).
//
// Semantics follow MAME namco_c169roz after PR #16136 (merged 2026-09-17, the
// Speed Racer road fix):
//  - Scanline records (FL layer 0 in mode 0x8000): increments are full 16-bit
//    signed values (bits 14-12 are NOT left/top), the record already holds the
//    line's start so no line*inc pitch is added (only the (36,3) analog front
//    porch), X wraps on the 4096 map, and Y wraps on a 3072-row ring when record
//    word 0 is 0x6000 (period word0>>3 == 0xC00): the firmware start is wrapped at
//    that period, then the analog offset is added, then the 12-bit chip wrap.
//  - Layer-wide walks: 12-bit signed increments with left/top in bits 14-12
//    (512-px steps) and size 512<<n. Wrap-on samples ((c & (size-1)) + left)
//    & 0xfff; wrap-off samples the full map only inside the visible window
//    [left, left+size) x [top, top+size) (window may cross 4096).
module fl_c169_affine(
    input wire clk,reset,start,consume,
    input wire [8:0] screen_y,
    input wire scanline,                  // per-scanline record walk (see above)
    input wire [15:0] word0,              // record word 0 (0x6000 => 3072-row Y ring)
    input wire [15:0] attributes,incxx,incxy,incyx,incyy,startx,starty,
    output reg busy,done,
    output reg [8:0] screen_x,
    output wire [11:0] source_x,source_y,
    output wire opaque_position,
    // Lookahead for the NEXT destination pixel (current + step), so the walker
    // can detect a tile crossing and prefetch while the current pixel paints.
    output wire [11:0] next_source_x,next_source_y,
    output wire next_opaque,
    output reg [3:0] priority_value,
    output reg [2:0] color
);
    function automatic signed [31:0] increment(input [15:0] value,input wide);
        increment=wide ? {{16{value[15]}},value} : {{20{value[15]}},value[11:0]};
    endfunction
    wire signed [31:0] xx=increment(incxx,scanline),xy=increment(incxy,scanline);
    wire signed [31:0] yx=increment(incyx,scanline),yy=increment(incyy,scanline);
    wire signed [31:0] origin_x={{16{startx[15]}},startx};
    wire signed [31:0] origin_y={{16{starty[15]}},starty};
    wire signed [31:0] line_y=$signed({23'd0,screen_y});
    wire signed [31:0] analog_x=32'sd36*xx+32'sd3*yx;
    wire signed [31:0] analog_y=32'sd36*xy+32'sd3*yy;
    reg signed [31:0] current_x,current_y,step_x,step_y,analog_y_r;
    reg enabled,wrap,scan_r,ring_r;
    reg [11:0] left_r,top_r;
    reg [12:0] size_r;
    wire signed [31:0] next_x=current_x+step_x,next_y=current_y+step_y;
    wire [11:0] size_mask=size_r[11:0]-12'd1;          // 512..4096 -> 0x1ff..0xfff
    wire signed [31:0] analog_rows=analog_y_r>>>8;       // MAME analog_y >> 16
    function automatic [11:0] map_x(input signed [31:0] c,input scan,input wrap_on,
                                    input [11:0] mask,input [11:0] left);
        map_x=(scan || !wrap_on) ? c[19:8] : ((c[19:8] & mask)+left);
    endfunction
    function automatic [11:0] ring_y(input signed [31:0] c,input signed [31:0] analog,
                                     input signed [31:0] rows);
        reg [11:0] py;reg [11:0] py2;reg signed [31:0] fw;
        begin
            fw=c-analog;                       // firmware coordinate (analog removed)
            py=fw[19:8];                       // 12-bit chip wrap
            py2=py>=12'd3072 ? py-12'd3072 : py; // % 3072 (py < 4096 < 2*3072)
            ring_y=py2+rows[11:0];             // + analog rows, 12-bit wrap
        end
    endfunction
    function automatic [11:0] map_y(input signed [31:0] c,input scan,input ring,input wrap_on,
                                    input [11:0] mask,input [11:0] top,
                                    input signed [31:0] analog,input signed [31:0] rows);
        // the 3072-row ring only exists on the wrap-on path (MAME: inside `if (params.wrap)`)
        map_y=scan ? ((ring && wrap_on) ? ring_y(c,analog,rows) : c[19:8])
                   : (!wrap_on ? c[19:8] : ((c[19:8] & mask)+top));
    endfunction
    function automatic in_window(input signed [31:0] cx,input signed [31:0] cy,
                                 input [11:0] left,input [11:0] top,input [12:0] size);
        reg [11:0] wx,wy;reg [13:0] x1,y1;reg in_x,in_y;
        begin
            wx=cx[19:8];wy=cy[19:8];x1={2'd0,left}+{1'b0,size};y1={2'd0,top}+{1'b0,size};
            in_x=(x1<=14'd4096) ? (wx>=left && {2'd0,wx}<x1) : (wx>=left || {2'd0,wx}<x1-14'd4096);
            in_y=(y1<=14'd4096) ? (wy>=top  && {2'd0,wy}<y1) : (wy>=top  || {2'd0,wy}<y1-14'd4096);
            in_window=in_x && in_y;
        end
    endfunction
    assign source_x=map_x(current_x,scan_r,wrap,size_mask,left_r);
    assign source_y=map_y(current_y,scan_r,ring_r,wrap,size_mask,top_r,analog_y_r,analog_rows);
    assign next_source_x=map_x(next_x,scan_r,wrap,size_mask,left_r);
    assign next_source_y=map_y(next_y,scan_r,ring_r,wrap,size_mask,top_r,analog_y_r,analog_rows);
    assign opaque_position=busy && enabled && (wrap || in_window(current_x,current_y,left_r,top_r,size_r));
    assign next_opaque=busy && enabled && (wrap || in_window(next_x,next_y,left_r,top_r,size_r));
    always @(posedge clk) begin
        done<=0;
        if(reset) begin
            busy<=0;done<=0;screen_x<=0;current_x<=0;current_y<=0;
            step_x<=0;step_y<=0;enabled<=0;wrap<=0;priority_value<=0;color<=0;
            scan_r<=0;ring_r<=0;left_r<=0;top_r<=0;size_r<=0;analog_y_r<=0;
        end else if(!busy) begin
            if(start) begin
                // analog front porch always; line pitch only for layer-wide walks
                current_x<=(origin_x<<<4)+analog_x+(scanline ? 32'sd0 : line_y*yx);
                current_y<=(origin_y<<<4)+analog_y+(scanline ? 32'sd0 : line_y*yy);
                step_x<=xx;step_y<=xy;screen_x<=0;
                enabled<=!attributes[15];wrap<=!attributes[11];
                scan_r<=scanline;ring_r<=scanline && word0[15:3]==13'h0C00;
                left_r<=scanline ? 12'd0 : {incxx[14:12],9'd0};
                top_r<=scanline ? 12'd0 : {incxy[14:12],9'd0};
                size_r<=13'd512<<attributes[9:8];
                analog_y_r<=analog_y;
                priority_value<=attributes[7:4];color<=attributes[2:0];busy<=1;
            end
        end else if(consume) begin
            if(screen_x==287) begin busy<=0;done<=1;end
            else begin
                screen_x<=screen_x+1'b1;current_x<=current_x+step_x;current_y<=current_y+step_y;
            end
        end
    end
endmodule
