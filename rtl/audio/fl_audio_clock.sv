// SPDX-License-Identifier: GPL-3.0-or-later
// System FL C352: 48.384 MHz / 2 / 288 = 84 kHz voice updates.
// The MiSTer output mixer resamples this native cadence independently.
module fl_audio_clock(input wire clk,reset,pause,output wire sample_ce);
    reg [14:0] phase;
    wire [15:0] next_phase={1'b0,phase}+16'd42;
    assign sample_ce=next_phase>=16'd25000 && !pause;
    always @(posedge clk) begin
        if(reset) phase<=0;
        else if(!pause) phase<=15'(sample_ce ? next_phase-16'd25000 : next_phase);
    end
endmodule
