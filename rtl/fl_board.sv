// SPDX-License-Identifier: GPL-3.0-or-later
// Shared board substrate for hardware and simulation. Rendering is being added.
module fl_board(
    input wire clk,reset,pause,
    input wire bios_wr,input wire [13:0] bios_addr,input wire [7:0] bios_data,
    input wire [7:0] adc5,adc6,adc7,port7,output wire [7:0] port6,
    output wire ce_pixel,hsync,vsync,de,output wire [8:0] x,y,
    output wire line_start,frame_start,
    output wire [23:0] video_rgb,
    output wire [31:0] video_missed_lines,video_completed_lines,
    output wire signed [15:0] audio_l,audio_r,
    output wire mem_req,mem_write,output wire [25:0] mem_addr,
    output wire [31:0] mem_wdata,output wire [3:0] mem_be,
    input wire mem_ready,input wire [31:0] mem_rdata,
    input wire [127:0] mem_rdata_wide,   // fl_sdram rdata_wide: the word's whole 16-byte block
    input wire [4:0] debug_reg_addr,
    output wire [31:0] debug_pc,debug_opcode,debug_ac,debug_reg,debug_process_control,debug_cpu_addr,
    output wire halted,retired,boot_bank,
    output wire [23:0] mcu_pc,output wire [7:0] mcu_opcode,
    output wire mcu_halted,mcu_retired,
    output wire [31:0] mailbox_writes,
    output wire [95:0] audio_debug,output wire [191:0] renderer_debug,
    output wire [191:0] c169_debug,
    // C355 object-RAM write-queue telemetry: cycles spent full (cumulative) and
    // high-water depth. A full queue stalls the CPU until the next vblank snapshot.
    output reg [31:0] spr_queue_full_cycles,output reg [11:0] spr_queue_hiwater,
    // Performance counters (FLP0 probe): i960 instructions retired, SDRAM grants to the CPU and to
    // everyone. boost_force = DEVELOPMENT experiment: the CPU/MCU always win the SDRAM arbiter.
    input wire boost_force,
    output reg [31:0] perf_retired,perf_cpu_grants,perf_all_grants,
    output wire [31:0] perf_wait,perf_ifetch,perf_data_rd,perf_data_wr,perf_frames,perf_dbuf_hit,
    // Road framebuffer: the MiSTer DDRAM port (Avalon-MM, 64-bit), on clk.
    output wire ddr_rd,ddr_we,output wire [28:0] ddr_addr,output wire [7:0] ddr_burstcnt,
    output wire [63:0] ddr_din,output wire [7:0] ddr_be,
    input wire ddr_busy,input wire [63:0] ddr_dout,input wire ddr_dout_ready
);
    `include "rtl/fl_rom_layout.svh"
    wire cpu_req,cpu_wr,cpu_ready,cpu_q_wide_valid;
    wire [127:0] cpu_q_wide;
    wire [31:0] cpu_data,cpu_q;
    wire [3:0] cpu_be,irq,irq_ack;
    wire [31:0] sprite_bank;
    fl_video_timing raster(.clk(clk),.reset(reset),.ce_pixel(ce_pixel),.x(x),.y(y),
        .hsync(hsync),.vsync(vsync),.de(de),.line_start(line_start),.frame_start(frame_start));
    i960ka cpu(.clk(clk),.reset(reset),.pause(pause),.irq(irq),
        .req(cpu_req),.write(cpu_wr),.addr(debug_cpu_addr),.wdata(cpu_data),.be(cpu_be),
        .ready(cpu_ready),.rdata(cpu_q),.rdata_wide(cpu_q_wide),.rdata_wide_valid(cpu_q_wide_valid),.halted(halted),.retired(retired),
        .perf_wait(perf_wait),.perf_ifetch(perf_ifetch),.perf_data_rd(perf_data_rd),.perf_data_wr(perf_data_wr),.perf_frames(perf_frames),.perf_dbuf_hit(perf_dbuf_hit),
        .debug_pc(debug_pc),.debug_opcode(debug_opcode),.debug_ac(debug_ac),
        .debug_reg_addr(debug_reg_addr),.debug_reg_data(debug_reg),.debug_process_control(debug_process_control));
    wire cpu_mem_req,cpu_mem_write;
    wire [25:0] cpu_mem_addr;
    wire [31:0] cpu_mem_data;
    wire [3:0] cpu_mem_be;
    wire [6:0] client_ready;
    wire sprite_req,sprite_ready;wire [31:0] sprite_q;
    wire sprite_mem_req,sprite_mem_write,sprite_rom_req;
    wire [25:0] sprite_mem_addr,sprite_rom_addr;wire [31:0] sprite_mem_data;wire [3:0] sprite_mem_be;
    wire road_req,road_ready;wire [31:0] road_q;
    wire tile_req,tile_ready;wire [31:0] tile_q;
    wire shared_req,shared_ready,palette_req,palette_ready;
    wire [31:0] shared_q,palette_q;
    fl_bus bus(.clk(clk),.reset(reset),.req(cpu_req),.write(cpu_wr),.addr(debug_cpu_addr),
        .wdata(cpu_data),.be(cpu_be),.ready(cpu_ready),.rdata(cpu_q),.rdata_wide(cpu_q_wide),.rdata_wide_valid(cpu_q_wide_valid),.boot_bank(boot_bank),
        .irq_ack(irq_ack),.sprite_bank(sprite_bank),.mem_req(cpu_mem_req),.mem_write(cpu_mem_write),
        .mem_addr(cpu_mem_addr),.mem_wdata(cpu_mem_data),.mem_be(cpu_mem_be),
        .mem_ready(client_ready[0]),.mem_rdata(mem_rdata),.mem_rdata_wide(mem_rdata_wide),
        .shared_req(shared_req),.shared_ready(shared_ready),.shared_rdata(shared_q),
        .sprite_req(sprite_req),.sprite_ready(sprite_ready),.sprite_rdata(sprite_q),
        .road_req(road_req),.road_ready(road_ready),.road_rdata(road_q),
        .tile_req(tile_req),.tile_ready(tile_ready),.tile_rdata(tile_q),
        .palette_req(palette_req),.palette_ready(palette_ready),.palette_rdata(palette_q));
    wire [15:0] raster_line,clip_left,clip_right,clip_top,clip_bottom;
    wire [12:0] video_pen;
    wire [23:0] palette_rgb;
    wire pixel_valid,tile_rom_req,road_rom_req,tile_valid,road_valid,road_rom_lock,sprite_rom_lock,tile_rom_lock;
    // Screen blanked by the game (C116 window right edge = 0, an empty clip): give the
    // CPU/MCU first pick of the SDRAM so scene loads run at full speed (see fl_client_arb).
    wire video_blanked=clip_right==16'd0;
    wire [8:0] road_query_y;   // tile compositor -> road compositor: row being composed
    wire [4:0] road_row_q;     // road compositor -> tile compositor: {fully solid, road pri}
    wire [25:0] road_rom_addr;
    wire [12:0] tile_pen,road_pen;
    wire [3:0] tile_priority,road_priority;
    wire [31:0] tile_missed,tile_completed,road_missed,road_completed;
    wire sprite_valid;wire [11:0] sprite_pen;wire [3:0] sprite_priority;
    wire [31:0] sprite_missed,sprite_completed;
    fl_video_mix mixer(.road_valid(road_valid),.tile_valid(tile_valid),.sprite_valid(sprite_valid),
        .road_pen(road_pen),.tile_pen(tile_pen),.sprite_pen(sprite_pen),
        .road_priority(road_priority),.tile_priority(tile_priority),.sprite_priority(sprite_priority),
        .pen(video_pen),.pixel_valid(pixel_valid));
    assign video_missed_lines=tile_missed+road_missed+sprite_missed;
    assign renderer_debug={tile_missed,road_missed,sprite_missed,tile_completed,road_completed,sprite_completed};
    assign video_completed_lines=tile_completed+road_completed+sprite_completed;
    wire [25:0] tile_rom_addr;
    fl_tile_video video(.clk(clk),.reset(reset),.line_start(line_start),.x(x),.y(y),
        .cpu_req(tile_req),.cpu_write(cpu_wr),.cpu_control(debug_cpu_addr[21]),
        .cpu_addr(debug_cpu_addr[15:0]),.cpu_data(cpu_data),.cpu_be(cpu_be),.cpu_ready(tile_ready),.cpu_q(tile_q),
        .rom_req(tile_rom_req),.rom_addr(tile_rom_addr),.rom_ready(client_ready[3]),.rom_data(mem_rdata),.rom_data_wide(mem_rdata_wide),
        .pen(tile_pen),.pixel_priority(tile_priority),.pixel_valid(tile_valid),.missed_lines(tile_missed),.completed_lines(tile_completed),
        .rom_lock(tile_rom_lock),.lead(tile_lead),.road_query_y(road_query_y),.road_row_q(road_row_q));
    fl_road_video road_video(.clk(clk),.reset(reset),.line_start(line_start),.x(x),.y(y),
        .cpu_req(road_req),.cpu_write(cpu_wr),.cpu_control(debug_cpu_addr[20]),
        .cpu_addr(debug_cpu_addr[16:0]),.cpu_data(cpu_data),.cpu_be(cpu_be),.cpu_ready(road_ready),.cpu_q(road_q),
        .rom_req(road_rom_req),.rom_addr(road_rom_addr),.rom_ready(client_ready[4]),.rom_data(mem_rdata),.rom_data_wide(mem_rdata_wide),
        .pen(road_pen),.priority_value(road_priority),.pixel_valid(road_valid),
        .missed_lines(road_missed),.completed_lines(road_completed),.rom_lock(road_rom_lock),
        .road_query_y(road_query_y),.road_query_q(road_row_q),.dbg_c169(c169_debug),.lead(road_lead),
        .ddr_rd(fb_rd[0]),.ddr_we(fb_we[0]),.ddr_addr(fb_addr[0]),.ddr_burstcnt(fb_burstcnt[0]),.ddr_din(fb_din[0]),.ddr_be(fb_be[0]),
        .ddr_busy(fb_busy[0]),.ddr_dout(fb_dout),.ddr_dout_ready(fb_dout_ready[0]));
    // The two layer framebuffers share the one DDRAM port, one transaction at a time.
    wire [1:0] fb_rd,fb_we,fb_busy,fb_dout_ready;
    wire [1:0][28:0] fb_addr;wire [1:0][7:0] fb_burstcnt,fb_be;wire [1:0][63:0] fb_din;wire [63:0] fb_dout;
    fl_ddr_mux ddr_mux(.clk(clk),.reset(reset),
        .m_rd(fb_rd),.m_we(fb_we),.m_addr(fb_addr),.m_burstcnt(fb_burstcnt),.m_din(fb_din),.m_be(fb_be),
        .m_busy(fb_busy),.m_dout_ready(fb_dout_ready),.m_dout(fb_dout),
        .ddr_rd(ddr_rd),.ddr_we(ddr_we),.ddr_addr(ddr_addr),.ddr_burstcnt(ddr_burstcnt),.ddr_din(ddr_din),.ddr_be(ddr_be),
        .ddr_busy(ddr_busy),.ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dout_ready));
    fl_sprite_video sprite_video(.clk(clk),.reset(reset),.line_start(line_start),.x(x),.y(y),.sprite_bank(sprite_bank),
        .cpu_req(sprite_req),.cpu_write(cpu_wr),.cpu_addr(debug_cpu_addr[16:0]),.cpu_data(cpu_data),.cpu_be(cpu_be),
        .cpu_ready(sprite_ready),.cpu_q(sprite_q),
        .mem_req(sprite_mem_req),.mem_write(sprite_mem_write),.mem_addr(sprite_mem_addr),.mem_data(sprite_mem_data),.mem_be(sprite_mem_be),
        .mem_ready(client_ready[5]),.mem_q(mem_rdata),.rom_req(sprite_rom_req),.rom_addr(sprite_rom_addr),.rom_ready(client_ready[6]),.rom_data(mem_rdata),.rom_data_wide(mem_rdata_wide),
        .pen(sprite_pen),.priority_value(sprite_priority),.pixel_valid(sprite_valid),.missed_lines(sprite_missed),.completed_lines(sprite_completed),.rom_lock(sprite_rom_lock),
        .queue_full(spr_queue_full),.queued_writes(spr_queued_writes),.lead(sprite_lead),
        .ddr_rd(fb_rd[1]),.ddr_we(fb_we[1]),.ddr_addr(fb_addr[1]),.ddr_burstcnt(fb_burstcnt[1]),.ddr_din(fb_din[1]),.ddr_be(fb_be[1]),
        .ddr_busy(fb_busy[1]),.ddr_dout(fb_dout),.ddr_dout_ready(fb_dout_ready[1]));
    wire spr_queue_full;
    wire [11:0] spr_queued_writes;
    wire [2:0] tile_lead,road_lead,sprite_lead;
    always @(posedge clk) begin
        if(reset) begin spr_queue_full_cycles<=0; spr_queue_hiwater<=0; end
        else begin
            if(spr_queue_full) spr_queue_full_cycles<=spr_queue_full_cycles+1'b1;
            if(spr_queued_writes>spr_queue_hiwater) spr_queue_hiwater<=spr_queued_writes;
        end
    end
    wire in_clip=({7'd0,x}+16'h4b)>=clip_left && ({7'd0,x}+16'h4b)<clip_right &&
        ({7'd0,y}+16'h21)>=clip_top && ({7'd0,y}+16'h21)<clip_bottom;
    assign video_rgb=pixel_valid && in_clip ? palette_rgb : 24'd0;
    fl_c116 palette(.clk(clk),.reset(reset),.req(palette_req),.write(cpu_wr),
        .addr(debug_cpu_addr[14:0]),.wdata(cpu_data),.be(cpu_be),.ready(palette_ready),.rdata(palette_q),
        .pen(video_pen),.rgb(palette_rgb),.clip_left(clip_left),.clip_right(clip_right),.clip_top(clip_top),.clip_bottom(clip_bottom),.raster_line(raster_line));
    fl_irq interrupts(.clk(clk),.reset(reset),.ce_pixel(ce_pixel),.x(x),.y(y),
        .raster_line(raster_line),.acknowledge(irq_ack),.irq(irq));
    reg [12:0] mcu_phase;
    wire mcu_ce=mcu_phase+14'd2016>=6250 && !pause;
    reg [19:0] mcu_irq_phase;
    reg mcu_irq_tick;
    wire audio_ce;
    fl_audio_clock audio_clock(.clk(clk),.reset(reset),.pause(pause),.sample_ce(audio_ce));
    always @(posedge clk) begin
        if(reset) begin mcu_phase<=0; mcu_irq_phase<=0; mcu_irq_tick<=0; end
        else if(!pause) begin
            mcu_phase<=13'(mcu_ce ? mcu_phase+14'd2016-6250 : mcu_phase+14'd2016);
            // MAME System FL drives both external MCU sources at 60 Hz.
            // Hold a tick across one MCU enable so the CPU cannot miss it.
            if(mcu_ce) begin
                mcu_irq_tick<=0;
                if(mcu_irq_phase==268799) begin mcu_irq_phase<=0; mcu_irq_tick<=1; end
                else mcu_irq_phase<=mcu_irq_phase+1'b1;
            end
        end
    end
    // IRQ pulses remain high until the following MCU enable edge.
    wire [23:0] mcu_addr;
    wire [7:0] mcu_out,mcu_in;
    wire mcu_rd,mcu_wr,mcu_ready;
    fl_c75 mcu(.clk(clk),.ce(mcu_ce),.reset(reset),.bios_wr(bios_wr),.bios_addr(bios_addr),.bios_din(bios_data),
        .irq0(mcu_irq_tick),.irq1(1'b0),.irq2(mcu_irq_tick),
        .in_adc0(8'hff),.in_adc1(8'hff),.in_adc2(8'hff),.in_adc3(8'hff),.in_adc4(8'hff),
        .in_adc5(adc5),.in_adc6(adc6),.in_adc7(adc7),.port6_out(port6),.port7_in(port7),
        .ext_addr(mcu_addr),.ext_dout(mcu_out),.ext_din(mcu_in),.ext_rd(mcu_rd),.ext_wr(mcu_wr),.ext_ready(mcu_ready),
        .dbg_pc(mcu_pc),.dbg_opcode(mcu_opcode),.dbg_valid(mcu_retired),.dbg_halted(mcu_halted),
        .dbg_x(),.dbg_ram80(),.dbg_ram83());
    wire mcu_shared_req,mcu_shared_write,mcu_shared_ready,mcu_mem_req;
    wire [14:0] mcu_shared_addr;
    wire [7:0] mcu_shared_data,mcu_shared_q;
    wire [25:0] mcu_mem_addr;
    wire sound_wr;
    wire [11:0] sound_addr;
    wire [7:0] sound_data,sound_q;
    fl_mcu_bus mcu_bus(.clk(clk),.reset(reset),.ce(mcu_ce),.rd(mcu_rd),.wr(mcu_wr),.addr(mcu_addr),.dout(mcu_out),
        .ready(mcu_ready),.din(mcu_in),.shared_req(mcu_shared_req),.shared_write(mcu_shared_write),
        .shared_addr(mcu_shared_addr),.shared_data(mcu_shared_data),.shared_ready(mcu_shared_ready),.shared_q(mcu_shared_q),
        .mem_req(mcu_mem_req),.mem_addr(mcu_mem_addr),.mem_ready(client_ready[1]),.mem_q(mem_rdata),
        .sound_wr(sound_wr),.sound_addr(sound_addr),.sound_data(sound_data),.sound_q(sound_q));
    wire [31:0] shared_offset=debug_cpu_addr-32'h30284000;
    fl_shared_ram shared(.clk(clk),.reset(reset),.cpu_req(shared_req),.cpu_wr(cpu_wr),
        .cpu_addr(shared_offset[14:2]),.cpu_din(cpu_data),.cpu_be(cpu_be),.cpu_dout(shared_q),.cpu_ack(shared_ready),
        .mcu_req(mcu_shared_req),.mcu_wr(mcu_shared_write),.mcu_addr(mcu_shared_addr),.mcu_din(mcu_shared_data),
        .mcu_dout(mcu_shared_q),.mcu_ack(mcu_shared_ready));
    reg [31:0] mailbox_count;
    assign mailbox_writes=mailbox_count;
    always @(posedge clk)
        if(reset) mailbox_count<=0;
        else if(mcu_shared_ready && mcu_shared_write && mcu_shared_addr==15'h6000) mailbox_count<=mailbox_count+1'b1;
    wire [23:0] wave_addr;
    wire wave_req;
    c352 sound(.clk(clk),.reset(reset),.sample_ce(audio_ce),.cs_addr(sound_addr),.cs_din(sound_data),
        .cs_wr(sound_wr),.cs_rdata(sound_q),.rom_addr(wave_addr),.rom_rd(wave_req),
        .rom_data(mem_rdata),.rom_ready(client_ready[2]),.dbg_busy_cnt(),.dbg_tick_count(audio_debug[95:64]),.dbg_mix_count(audio_debug[63:32]),
        .dbg_drop_count(audio_debug[31:0]),.audio_l(audio_l),.audio_r(audio_r));
    wire [25:0] wave_mem_addr=`FL_C352_BASE+{4'd0,wave_addr[21:0]};
    // HI = clients 6..2 (sprite_rom, sprite_mem, road_rom, tile_rom, wave/audio) get
    // priority over CPU(0)/MCU(1): the video ROM fetches have hard scanline deadlines
    // and audio must not drop; CPU/MCU are latency-tolerant and anti-starvation-bounded.
    always @(posedge clk) begin
        if(reset) begin perf_retired<=0;perf_cpu_grants<=0;perf_all_grants<=0;end
        else begin
            if(retired) perf_retired<=perf_retired+1'b1;
            if(client_ready[0]) perf_cpu_grants<=perf_cpu_grants+1'b1;
            if(|client_ready) perf_all_grants<=perf_all_grants+1'b1;
        end
    end
    fl_client_arb #(.N(7),.HI(7'b1111100)) memory_arb(.clk(clk),.reset(reset),
        .client_req({sprite_rom_req,sprite_mem_req,road_rom_req,tile_rom_req,wave_req,mcu_mem_req,cpu_mem_req}),.client_write({1'b0,sprite_mem_write,4'b0000,cpu_mem_write}),
        // grant hold for the multi-word row fetches (C355 sprite rom, C169 road rom); C123 later
        .client_lock({sprite_rom_lock,1'b0,road_rom_lock,tile_rom_lock,3'b000}),.boost_lo(video_blanked || boost_force),
        // deadline urgency: engines report lines of slack; audio (2) is always due now;
        // the CPU's object-RAM path (5) sits mid-way; CPU/MCU are low tier (ignored)
        .client_urgency({sprite_lead,3'd3,road_lead,tile_lead,3'd0,3'd7,3'd7}),
        .client_addr({sprite_rom_addr,sprite_mem_addr,road_rom_addr,tile_rom_addr,wave_mem_addr,mcu_mem_addr,cpu_mem_addr}),.client_data({32'd0,sprite_mem_data,128'd0,cpu_mem_data}),
        .client_be({4'hf,sprite_mem_be,16'hffff,cpu_mem_be}),.client_ready(client_ready),
        .req(mem_req),.write(mem_write),.addr(mem_addr),.data(mem_wdata),.be(mem_be),.ready(mem_ready));
endmodule
