// SPDX-License-Identifier: GPL-3.0-or-later
// DEVELOPMENT top: integrated C123/C169/C355 video with diagnostic/JTAG access.
module emu(
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='z;
    // USER_OUT is driven by the DB9/DB15 (joydb) block further down -- see "PATREON: DB9/DB15".
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='z;
    // DDR3 holds the road-layer framebuffer (fl_road_video); the port runs on the core clock.
    assign DDRAM_CLK=clk;
    assign VGA_SL=0; assign VGA_F1=0; assign VGA_SCALER=0; assign VGA_DISABLE=0;
    assign HDMI_FREEZE=0; assign HDMI_BLACKOUT=0; assign HDMI_BOB_DEINT=0;
    assign AUDIO_S=1; assign AUDIO_MIX=0;
    assign LED_DISK=0; assign LED_POWER=0; assign BUTTONS=0;
    assign VIDEO_ARX=13'd4; assign VIDEO_ARY=13'd3;
    wire clk,clk2x,pll_locked;
    fl_pll clock_gen(.refclk(CLK_50M),.clk(clk),.clk2x(clk2x),.locked(pll_locked));
    reg [7:0] power_count=0;
    always @(posedge clk) if(!pll_locked) power_count<=0;
        else if(!(&power_count)) power_count<=power_count+1'b1;
    wire cold_reset=RESET || !(&power_count) || !pll_locked;
    wire [127:0] status;
    wire [1:0] buttons;
    wire [31:0] joy0_USB;   // [MiSTer-DB9] raw USB pad from hps_io (pre DB9/DB15 merge)
    wire [31:0] joystick;   // pad seen by the core = USB pad or DB9/DB15 pad
    wire [15:0] analog_l,analog_r;
    wire [7:0] paddle;
    wire downloading,ioctl_wr;
    wire [15:0] ioctl_index;
    wire [26:0] ioctl_addr;
    wire [7:0] ioctl_data;
    wire ioctl_wait,rom_wait,nvram_wait,pause;
    wire [10:0] ps2_key;
    wire uploading,nvram_upload_req;
    wire [7:0] nvram_host_q;
    // Build type (mister_development_standards.md): DEBUG=1 is the DEVELOPMENT build with the
    // JTAG/ISSP probes and the Development OSD page; DEBUG=0 (PATREON/GITHUB) eliminates the
    // probes and hides/ignores the debug controls. tools/build_release.sh sets it for a build.
    localparam DEBUG=0;   // PATREON release configuration (as compiled); 1 = DEVELOPMENT, 2 = FLD0 probe only
    localparam CONF_STR={
        "SYSTEMFL;;",
        "-;",
        "H1-,DEVELOPMENT BUILD;",
        "O[2:1],Steering,Joystick,Analog axis,Paddle;",
        "O[3],Accelerator,Button,Analog axis;",
        "O[64],Pause when OSD is open,Off,On;",
        // PATREON: DB9/DB15 pads on the USER_IO port (joydb). Speed Racer / Final Lap R are
        // racing games, not light-gun games, so the option is always available (standards
        // "DB9/DB15 support ... must be included for ordinary and racing games").
        "O[102:101],UserIO Joystick,Off,Saturn,DB9 MD,DB15;",
        "-;",
        // PATREON: CRT Adjust (rtl/video/crt_adjust*.sv, rmonic79, GPLv3) -- analog H-Size /
        // H-Position / V-Shift from the OSD without the CRT losing lock. H2 (status_menumask[2])
        // hides the three adjustments while CRT Adjust is Off; H1 hides the debug items (DEBUG=0).
        "P2,CRT Adjust;",
        "P2-;",
        "P2O[42],CRT Adjust,Off,On;",
        "H2P2O[47:43],H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H2P2O[54:48],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H2P2O[59:55],V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P2-;",
        "-;",
        "H1P1,Development;",
        "H1P1O[4],CPU hold,Off,On;",
        "H1P1O[5],Diagnostic display,CPU PC,Inputs;",
        "H1P1-,C123 / C169 / C355 video;",
        "T[0],Reset;",
        // slot 8 = Pause (user 2026-09-23: "pause button is not mapped"): toggles the core pause
        // (same path as "Pause when OSD is open"); keyboard P too. joystick[12].
        "J1,Accelerator,Start / Jump,Weapon 1,Weapon 2,Weapon 3,Coin,Service,Test,Pause;",
        "jn,A,B,X,Y,L,R,Select,Start;",
        "V,Development 0"
    };
    hps_io #(.CONF_STR(CONF_STR)) host(
        .clk_sys(clk),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(),
        // H1 = debug items hidden in release builds (DEBUG=0); H2 = CRT Adjust sliders hidden while Off.
        .status(status),.buttons(buttons),.status_menumask({13'd0,~status[42],DEBUG ? 1'b0 : 1'b1,1'b0}),
        .joystick_0(joy0_USB),.joystick_l_analog_0(analog_l),
        .joy_raw(OSD_STATUS ? joydb_1_mapped : 16'b0),   // [MiSTer-DB9] pad drives OSD nav
        .joystick_r_analog_0(analog_r),.paddle_0(paddle),
        .ioctl_download(downloading),.ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_data),
        .ioctl_wait(ioctl_wait),.ioctl_din(nvram_host_q),.ps2_key(ps2_key),
        .ioctl_upload(uploading),.ioctl_upload_req(nvram_upload_req),.ioctl_upload_index(8'd9)
    );

    // ============ PATREON: DB9/DB15 joystick input on USER_IO (joydb) ============
    // Sega DB9 (Megadrive) / Saturn / DB15 pads on the USER_IO port, via the unified
    // MiSTer-DB9 wrapper (sys/joydb*.{sv,v}, byte-identical to SUPER22_MiSTer/sys/ and to
    // the MiSTer-DB9 framework fork, fork_ci_template/sys/). Off by default, so USB and
    // keyboard behaviour is unchanged. The decoded pad replaces the USB pad on the same
    // 32-bit `joystick` bus the core already consumes (fl_inputs), so J1 slot order is
    // untouched: [3:0]=R,L,D,U  [4]=Accelerator [5]=Start/Jump [6..8]=Weapon 1..3
    // [9]=Coin [10]=Service [11]=Test.
    //
    // The MiSTer-DB9 framework deltas are imported into sys/: USER_IN/USER_OUT are 8-bit
    // with a per-pin push-pull mask USER_PP (sys_top.v drives the strobe pins actively
    // instead of open-drain), USER_IO[7] is the reclaimed SD_SPI_CS pin PIN_AE15 (DB9
    // pin 8), and hps_io.sv exposes joy_raw (UIO 0x0F) so the pad can navigate the OSD.
    wire         CLK_JOY = CLK_50M;                      // fixed 50 MHz for the joydb strobes
    wire   [1:0] joy_type = status[102:101];             // 0=Off 1=Saturn 2=DB9MD 3=DB15
    wire         joy_2p   = 1'b0;                        // System FL is a 1-player cabinet
    wire   [7:0] USER_OUT_DRIVE, USER_PP_DRIVE;
    wire  [15:0] joydb_1,joydb_2,joydb_1_mapped,joydb_2_mapped,joy_raw_payload;
    wire         joydb_1ena,joydb_2ena;

    // Identity-map bootstrap for joydb_remap. As in SUPER22, the UIO 0xFD db9_map selector
    // stream is not part of this framework (hps_io.sv has no db9_remap_* outputs), so the
    // matrix is loaded once at reset with the identity permutation.
    reg  [2:0]  joydb_boot_word = 3'd1;
    wire        joydb_boot_busy = (joydb_boot_word <= 3'd3);
    wire [15:0] joydb_boot_din  = (joydb_boot_word==3'd1) ? 16'h7654
                                : (joydb_boot_word==3'd2) ? 16'hBA98
                                :                           16'hFEDC;
    always @(posedge clk) if (joydb_boot_busy) joydb_boot_word <= joydb_boot_word + 1'd1;

    joydb joydb
    (
        .clk(CLK_JOY),.clk_sys(clk),.USER_IN(USER_IN),
        .OSD_STATUS(OSD_STATUS),.snac_active(1'b0),.mt32_primary_active(1'b0),
        .joy_type(joy_type),.joy_2p(joy_2p),.saturn_unlocked(1'b0),
        .USER_OUT_DRIVE(USER_OUT_DRIVE),.USER_PP_DRIVE(USER_PP_DRIVE),.USER_OSD(),
        .joydb_1(joydb_1),.joydb_2(joydb_2),
        .joydb_1ena(joydb_1ena),.joydb_2ena(joydb_2ena),
        .pad_1_6btn(),.pad_2_6btn(),
        .remap_cmd(joydb_boot_busy),.remap_byte_cnt({3'd0,joydb_boot_word}),
        .remap_din(joydb_boot_din),
        .joydb_1_mapped(joydb_1_mapped),.joydb_2_mapped(joydb_2_mapped),
        .joy_raw(joy_raw_payload)
    );
    assign USER_OUT = USER_OUT_DRIVE;   // [MiSTer-DB9] driven by joydb
    assign USER_PP  = USER_PP_DRIVE;    // [MiSTer-DB9] per-pin push-pull mask

    // Merge the DB9/DB15 pad into the USB pad; held at 0 while the OSD is open (the pad
    // drives the menu through hps_io's joy_raw instead). joydb_1ena is high only when a
    // pad of that player is detected (or the OSD autodetect probe is running).
    assign joystick = joydb_1ena ? (OSD_STATUS ? 32'd0 : {16'd0,joydb_1_mapped}) : joy0_USB;

    wire [8:0] x,y;
    wire [23:0] video_rgb;
    wire [31:0] video_missed_lines,video_completed_lines;
    wire [95:0] audio_debug;wire [191:0] renderer_debug;
    wire ce_pix,line_start,frame_start;
    // CLK_VIDEO stays the 50 MHz core clock; CE_PIXEL comes from the CRT Adjust wrapper
    // (rtl/video/fl_crtadj.sv), which passes the native ce_pix straight through when
    // CRT Adjust is Off and re-times it for H-Size when it is On.
    assign CLK_VIDEO=clk;
    wire core_hs,core_vs,core_de;
    // Vertical blank only (fl_video_timing: de = x<288 && y<224), needed by crt_adjust to gate
    // the read side one line late; horizontal blank is just ~core_de inside the wrapper.
    wire core_vb=y>=9'd224;
    wire [7:0] adc5,adc6,adc7,port7,mcu_port6;
    // .mra-supplied bytes: <switches> DIPs arrive at ioctl index 254 (bit 0 = Freeze
    // Screen, the only System FL DIP); the cabinet/config byte at index 10 (bit 0 =
    // Final Lap R controls, see fl_inputs). Both default to 0 = Speed Racer, no freeze.
    reg [7:0] dip_sw,game_config;
    always @(posedge clk) begin
        if(cold_reset) begin dip_sw<=0; game_config<=0; end
        else if(ioctl_wr && ioctl_addr==27'd0) begin
            if(ioctl_index==16'd254) dip_sw<=ioctl_data;
            if(ioctl_index==16'd10) game_config<=ioctl_data;
        end
    end
    fl_inputs controls(.clk(clk),.reset(cold_reset),.tick(frame_start),.joy(joystick),
        .steering_axis(analog_l[7:0]),.paddle(paddle),.accelerator({~analog_r[15],analog_r[14:8]}),
        .steering_mode(status[2:1]),.analog_pedal(status[3]),
        .freeze_screen(dip_sw[0]),.test_switch(1'b0),.port6(mcu_port6),.port7(port7),
        .flr_controls(game_config[0]),.brake({~analog_l[15],analog_l[14:8]}),
        .adc5(adc5),.adc6(adc6),.adc7(adc7));

    wire initialized,loaded,load_error;
    wire [26:0] received;
    wire load_req;
    wire [25:0] load_addr;
    wire [31:0] load_data;
    wire [3:0] load_be;
    wire sd_ready;
    wire load_ready,board_ready;
    fl_download loader(.clk(clk),.reset(cold_reset),.initialized(initialized),
        .download(downloading),.wr(ioctl_wr),.index(ioctl_index),.address(ioctl_addr),.data(ioctl_data),
        .wait_host(rom_wait),.mem_req(load_req),.mem_addr(load_addr),.mem_data(load_data),
        .mem_be(load_be),.mem_ready(load_ready),.loaded(loaded),.error(load_error),.received(received));

    wire [8:0] debug_control;   // [8] = DEVELOPMENT: CPU/MCU always win the SDRAM arbiter (boost_force)
    wire bios_wr,bios_loaded,bios_error;
    wire [13:0] bios_addr;
    wire [7:0] bios_data;
    fl_bios_loader bios_loader(.clk(clk),.reset(cold_reset),.download(downloading),.wr(ioctl_wr),
        .index(ioctl_index),.address(ioctl_addr),.data(ioctl_data),.bios_wr(bios_wr),
        .bios_addr(bios_addr),.bios_data(bios_data),.loaded(bios_loaded),.error(bios_error));
    wire nvram_ready,nvram_error,nvram_req,nvram_mem_ready;
    wire [25:0] nvram_addr;
    wire [31:0] nvram_data;
    wire [3:0] nvram_be;
    assign ioctl_wait=rom_wait || nvram_wait;
    wire cpu_reset=cold_reset || status[0] || buttons[1] || !loaded || !bios_loaded || !nvram_ready || downloading || debug_control[5];
    wire halted,retired,boot_bank,mcu_halted,mcu_retired;
    wire [31:0] debug_pc,debug_opcode,debug_ac,debug_reg,debug_process_control,cpu_addr,mailbox_writes;
    wire [23:0] mcu_pc;
    wire [7:0] mcu_opcode;
    wire board_req,board_wr;
    wire [25:0] board_addr;
    wire [31:0] board_data,sd_data;
    wire [127:0] sd_data_wide;
    wire [3:0] board_be;
    // ---- Pause: OSD-open option (status[64]), the Pause button (J1 slot 8 = joystick[12]) and the
    // keyboard P key toggle a latch (cleared by reset); DEVELOPMENT builds also have the OSD CPU hold.
    reg kb_pause=0,kb_stb_d=0,pause_btn_d=0,pause_tgl=0;
    wire pause_btn=joystick[12] || kb_pause;
    always @(posedge clk) begin
        kb_stb_d<=ps2_key[10];
        if(kb_stb_d!=ps2_key[10] && ps2_key[8:0]==9'h04D) kb_pause<=ps2_key[9];   // 'P'
        pause_btn_d<=pause_btn;
        if(cpu_reset) pause_tgl<=0;
        else if(pause_btn && !pause_btn_d) pause_tgl<=~pause_tgl;
    end
    assign pause=(DEBUG && status[4]) || debug_control[6] || (status[64] && OSD_STATUS) || pause_tgl;
    // ---- PATREON pause screen: the fleet pause_overlay (rtl/video/pause_overlay.v, MLAB ROMs from
    // rtl/pause_assets/*.mif generated by tools/gen_pause_assets.py from the shared
    // pause_src/pause.txt, sha256-tracked) replaces the picture while paused. PAUSE_SCREEN=0
    // (GITHUB builds, per the standards) keeps the paused game picture instead.
    localparam PAUSE_SCREEN=1;
    wire pause_show=PAUSE_SCREEN && pause;
    fl_board board(.clk(clk),.reset(cpu_reset),
        .pause(pause),
        .bios_wr(bios_wr),.bios_addr(bios_addr),.bios_data(bios_data),
        .adc5(adc5),.adc6(adc6),.adc7(adc7),.port7(port7),.port6(mcu_port6),
        .ce_pixel(ce_pix),.hsync(core_hs),.vsync(core_vs),.de(core_de),.x(x),.y(y),
        .video_rgb(video_rgb),.video_missed_lines(video_missed_lines),.video_completed_lines(video_completed_lines),
        .line_start(line_start),.frame_start(frame_start),.audio_l(AUDIO_L),.audio_r(AUDIO_R),
        .mem_req(board_req),.mem_write(board_wr),.mem_addr(board_addr),.mem_wdata(board_data),
        .mem_be(board_be),.mem_ready(board_ready),.mem_rdata(sd_data),.mem_rdata_wide(sd_data_wide),
        .debug_reg_addr(debug_control[4:0]),.debug_pc(debug_pc),.debug_opcode(debug_opcode),
        .debug_ac(debug_ac),.debug_reg(debug_reg),.debug_process_control(debug_process_control),
        .debug_cpu_addr(cpu_addr),.halted(halted),.retired(retired),.boot_bank(boot_bank),
        .mcu_pc(mcu_pc),.mcu_opcode(mcu_opcode),.mcu_halted(mcu_halted),.mcu_retired(mcu_retired),
        .mailbox_writes(mailbox_writes),.audio_debug(audio_debug),.renderer_debug(renderer_debug),
        .c169_debug(c169_debug),.spr_queue_full_cycles(spr_queue_full_cycles),.spr_queue_hiwater(spr_queue_hiwater),
        .boost_force(DEBUG && debug_control[8]),.perf_retired(perf_retired),.perf_cpu_grants(perf_cpu_grants),.perf_all_grants(perf_all_grants),
        .perf_wait(perf_wait),.perf_ifetch(perf_ifetch),.perf_data_rd(perf_data_rd),.perf_data_wr(perf_data_wr),.perf_frames(perf_frames),.perf_dbuf_hit(perf_dbuf_hit),
        .ddr_rd(DDRAM_RD),.ddr_we(DDRAM_WE),.ddr_addr(DDRAM_ADDR),.ddr_burstcnt(DDRAM_BURSTCNT),.ddr_din(DDRAM_DIN),.ddr_be(DDRAM_BE),
        .ddr_busy(DDRAM_BUSY),.ddr_dout(DDRAM_DOUT),.ddr_dout_ready(DDRAM_DOUT_READY));
    wire [191:0] c169_debug;
    wire [31:0] perf_retired,perf_cpu_grants,perf_all_grants,perf_wait,perf_ifetch,perf_data_rd,perf_data_wr,perf_frames,perf_dbuf_hit;
    wire [31:0] spr_queue_full_cycles;
    wire [11:0] spr_queue_hiwater;
    wire mem_req,mem_write;
    wire [25:0] mem_addr;
    wire [31:0] mem_data;
    wire [3:0] mem_be;
    fl_nvram nvram(.clk(clk),.reset(cold_reset),.initialized(initialized),
        .download(downloading),.upload(uploading),.host_wr(ioctl_wr),.index(ioctl_index),
        .address(ioctl_addr),.host_data(ioctl_data),.wait_host(nvram_wait),.host_q(nvram_host_q),
        .upload_req(nvram_upload_req),.ready(nvram_ready),.error(nvram_error),
        .game_write(board_req && board_ready && board_wr),.game_addr(board_addr),
        .game_data(board_data),.game_be(board_be),
        .mem_req(nvram_req),.mem_addr(nvram_addr),.mem_data(nvram_data),.mem_be(nvram_be),.mem_ready(nvram_mem_ready));
    fl_client_arb #(.N(3)) arbiter(.clk(clk),.reset(cold_reset),.client_lock(3'b000),.boost_lo(1'b0),.client_urgency(9'd0),
        .client_req({board_req,nvram_req,load_req}),.client_write({board_wr,2'b11}),
        .client_addr({board_addr,nvram_addr,load_addr}),.client_data({board_data,nvram_data,load_data}),
        .client_be({board_be,nvram_be,load_be}),.client_ready({board_ready,nvram_mem_ready,load_ready}),
        .req(mem_req),.write(mem_write),.addr(mem_addr),.data(mem_data),.be(mem_be),.ready(sd_ready));
    // SDRAM controller in the 100 MHz domain (see fl_sdram.sv / fl_pll.sv).
    fl_sdram memory(.clk(clk2x),.reset(cold_reset),.req(mem_req),
        .write(mem_write),.addr(mem_addr),.wdata(mem_data),.be(mem_be),
        .ready(sd_ready),.rdata(sd_data),.rdata_wide(sd_data_wide),.initialized(initialized),
        .sd_clk(),.sd_cke(SDRAM_CKE),.sd_a(SDRAM_A),.sd_ba(SDRAM_BA),
        .sd_dq(SDRAM_DQ),.sd_dqm({SDRAM_DQMH,SDRAM_DQML}),
        .sd_cs(SDRAM_nCS),.sd_ras(SDRAM_nRAS),.sd_cas(SDRAM_nCAS),.sd_we(SDRAM_nWE));
    // Forwarded SDRAM clock: inverted clk2x through the I/O DDIO register (the
    // SUPER22/Genesis recipe), so its clock-to-out is deterministic.
    altddio_out #(.extend_oe_disable("OFF"),.intended_device_family("Cyclone V"),
        .invert_output("OFF"),.lpm_hint("UNUSED"),.lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"),.power_up_high("OFF"),.width(1)) sdramclk_ddr(
        .datain_h(1'b0),.datain_l(1'b1),.outclock(clk2x),.dataout(SDRAM_CLK),
        .aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0));

    generate if(DEBUG) begin : g_debug
    // JTAG captures are sampled in the same clock domain as the board state.
    // Source bit 7 selects input diagnostics while preserving CPU visibility
    // at its default zero setting. No reset/pause bits change when selecting it.
    wire [31:0] probe_ac=debug_control[7] ? {adc5,adc6,adc7,mcu_port6} : debug_ac;
    wire [31:0] probe_reg=debug_control[7] ? joystick : debug_reg;
    wire [31:0] probe_addr=debug_control[7] ? {status[7:0],16'd0,port7} : cpu_addr;
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLD0"),
        .probe_width(192),.source_width(9),.source_initial_value("0"),
        .enable_metastability("YES")) debug_port(
        .probe({debug_pc,debug_opcode,probe_ac,probe_reg,probe_addr,
                received,boot_bank,load_error,loaded,initialized,halted}),
        .source(debug_control),.source_clk(clk),.source_ena(1'b1));
    if(DEBUG==1) begin : g_probes_full
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLM0"),
        .probe_width(128),.source_width(1),.enable_metastability("YES")) mcu_debug_port(
        .probe({mcu_pc,mcu_opcode,mailbox_writes,debug_process_control,29'd0,bios_error,bios_loaded,mcu_halted}),
        .source(),.source_clk(clk),.source_ena(1'b1));
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLV0"),
        .probe_width(64),.source_width(1),.enable_metastability("YES")) video_debug_port(
        // FLV0 now carries the C355 write-queue telemetry (the per-engine miss counters
        // live in FLX0): {queue_full_cycles[31:0], 4'd0, queue_hiwater[11:0], 16'd0}.
        .probe({spr_queue_full_cycles,4'd0,spr_queue_hiwater,16'd0}),.source(),.source_clk(clk),.source_ena(1'b1));
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLA0"),
        .probe_width(96),.source_width(1),.enable_metastability("YES")) audio_debug_port(
        .probe(audio_debug),.source(),.source_clk(clk),.source_ena(1'b1));
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLX0"),
        .probe_width(192),.source_width(1),.enable_metastability("YES")) renderer_debug_port(
        .probe(renderer_debug),.source(),.source_clk(clk),.source_ena(1'b1));
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLC0"),
        .probe_width(192),.source_width(1),.enable_metastability("YES")) c169_debug_port(
        .probe(c169_debug),.source(),.source_clk(clk),.source_ena(1'b1));
    // FLP0 (IDX 6): {retired, cpu grants, all grants, signature F1F1F1F1} - read twice for rates.
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLP0"),
        .probe_width(128),.source_width(1),.enable_metastability("YES")) perf_probe(
        .probe({perf_retired,perf_cpu_grants,perf_all_grants,32'hF1F1F1F1}),.source(),.source_clk(clk),.source_ena(1'b1));
    // FLP1 (IDX 7): {wait cycles, ifetch reads, data reads, data writes, call-frame stores, read-buffer hits}
    altsource_probe #(.sld_auto_instance_index("YES"),.instance_id("FLP1"),
        .probe_width(192),.source_width(1),.enable_metastability("YES")) perf_probe1(
        .probe({perf_wait,perf_ifetch,perf_data_rd,perf_data_wr,perf_frames,perf_dbuf_hit}),.source(),.source_clk(clk),.source_ena(1'b1));
    end
    end else begin : g_release
        assign debug_control=9'd0;   // no JTAG probes in PATREON/GITHUB builds
    end endgenerate
    wire bit_pixel=debug_pc[31-x[7:3]];
    wire [23:0] diagnostic_rgb={y<32 && bit_pixel ? 8'hff : 8'd0,adc5,adc7};
    // Native picture, exactly as it used to be assigned straight to VGA_*.
    wire [23:0] core_rgb=!core_de ? 24'd0 : (DEBUG && status[5]) ? diagnostic_rgb : video_rgb;
    // pause_overlay registers its output on ce_pix (one pixel later, also on the passthrough path),
    // so the syncs are delayed by the same pixel before CRT Adjust.
    wire [7:0] ovl_r,ovl_g,ovl_b;
    reg ovl_hs,ovl_vs,ovl_de,ovl_vb;
    always @(posedge clk) if(ce_pix) begin ovl_hs<=core_hs;ovl_vs<=core_vs;ovl_de<=core_de;ovl_vb<=core_vb;end
    pause_overlay overlay(.clk(clk),.ce_pix(ce_pix),.hblank(!core_de),.vblank(core_vb),.enable(pause_show),
        .rotate180(1'b0),.vertical(1'b0),
        .vid_r_in(core_rgb[23:16]),.vid_g_in(core_rgb[15:8]),.vid_b_in(core_rgb[7:0]),
        .vid_r_out(ovl_r),.vid_g_out(ovl_g),.vid_b_out(ovl_b));
    // PATREON: CRT Adjust at the emu video boundary. Off => the native picture and syncs with one
    // fixed pixel of pipeline delay; On => H-Size / H-Position / V-Shift from OSD page 2.
    fl_crtadj #(.HTOTAL(384),.VTOTAL(264),.CE_NUM(756),.CE_DEN(6250),.HSTEPS(24),.USE_MLAB(1)) crtadj(
        .clk(clk),.ce_pix(ce_pix),
        .r(ovl_r),.g(ovl_g),.b(ovl_b),
        .hs(ovl_hs),.vs(ovl_vs),.de(ovl_de),.vb(ovl_vb),
        .cfg(status[59:42]),
        .vga_r(VGA_R),.vga_g(VGA_G),.vga_b(VGA_B),
        .vga_hs(VGA_HS),.vga_vs(VGA_VS),.vga_de(VGA_DE),.ce_pixel(CE_PIXEL));
    assign LED_USER=downloading || halted || mcu_halted || load_error || bios_error || nvram_error;
endmodule
