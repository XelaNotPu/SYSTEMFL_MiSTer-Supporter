# Core logic uses a 50 MHz PLL driven by the framework's CLK_50M input; the SDRAM
# controller runs on the same PLL's second output at exactly 100 MHz (2x, phase 0).
# The 50 MHz clients and the 100 MHz controller exchange request/ready/data as
# plain related-clock paths (no synchronisers), so BOTH outputs must sit in ONE
# synchronous clock group for STA to time those crossings (SUPER22 b47 pattern).
set fl_clock_pin   {emu|clock_gen|core_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set fl_clock2x_pin {emu|clock_gen|core_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}

# SDRAM_CLK is forwarded through an ALTDDIO_OUT on the 100 MHz clock (inverted);
# like the SUPER22 / Genesis controllers the SDRAM pins carry no I/O delay
# constraints: the data-valid window is set by the board round trip (DDIO
# clock-to-out + device tAC + DQ input path) and the controller consumes DQ at
# READ+4 for that reason (tb_sdram sweeps that window; validate on hardware).

# sys/sys_top.sdc expects a conventional *|pll|pll_inst hierarchy. This
# core's PLL has a different name, so explicitly extend the framework's
# domain separation. Keep the core clock and its 2x SDRAM clock together.
# The framework selects HDMI/core clocks and data together (sys_top.v),
# and crosses scaler memory via its existing dual-clock memory interfaces.
set_clock_groups -asynchronous \
    -group [get_clocks [list $fl_clock_pin $fl_clock2x_pin]] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]
