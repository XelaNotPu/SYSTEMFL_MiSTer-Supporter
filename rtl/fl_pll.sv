// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer video clock switches require a PLL-driven CLK_VIDEO.
// clk2x (100 MHz, same VCO, phase 0) clocks the SDRAM controller: exactly 2x the
// core clock so the 50 MHz clients and the controller are timed as related
// clocks (the SUPER22 / Genesis pattern) with no asynchronous crossing.
module fl_pll(input wire refclk, output wire clk,clk2x,locked);
    altera_pll #(.reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),.number_of_clocks(2),
        .output_clock_frequency0("50.0 MHz"),.phase_shift0("0 ps"),.duty_cycle0(50),
        .output_clock_frequency1("100.0 MHz"),.phase_shift1("0 ps"),.duty_cycle1(50),
        .pll_type("General"),.pll_subtype("General")) core_pll(
        .refclk(refclk),.rst(1'b0),.outclk({clk2x,clk}),.locked(locked),.fbclk(1'b0),.fboutclk());
endmodule
