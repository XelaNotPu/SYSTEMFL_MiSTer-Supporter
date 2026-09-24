// SPDX-License-Identifier: GPL-3.0-or-later
// All host inputs sampled together in the same clk domain as hps_io.
module fl_inputs(input wire clk, reset, tick,
    input wire [31:0] joy, input wire signed [7:0] steering_axis,
    input wire [7:0] paddle, accelerator,
    input wire [1:0] steering_mode, input wire analog_pedal,
    input wire freeze_screen, test_switch,
    input wire [7:0] port6,
    output reg [7:0] port7, output reg [7:0] adc5,adc6,adc7,
    // Cabinet select from the .mra config byte (ioctl index 10, bit 0):
    // 0 = Speed Racer (no brake: AN6 reads 0xff, IN2 = Start/Jump + weapons),
    // 1 = Final Lap R (AN6 = brake pedal, released 0x00 .. pressed 0xff; IN1 bit4 =
    //     2-position shifter, toggled by joystick slot 2; IN2 unused - its bit 0x80
    //     would FREEZE the game, so it is held idle).
    input wire flr_controls, input wire [7:0] brake);
    reg [7:0] digital_steer;
    reg [31:0] buttons;
    reg gear;
    always @(posedge clk) begin
        if(reset) begin digital_steer<=128; adc5<=128; adc6<=255; adc7<=0; buttons<=0; gear<=0; end
        else begin
            buttons<=joy;
            if(joy[6] && !buttons[6]) gear<=~gear;   // shifter: each press flips the lever
            if(tick) begin
                if(joy[1] && !joy[0]) digital_steer<=digital_steer<4 ? 8'd0 : digital_steer-8'd4;
                else if(joy[0] && !joy[1]) digital_steer<=digital_steer>251 ? 8'd255 : digital_steer+8'd4;
                else if(digital_steer<128) digital_steer<=digital_steer>124 ? 8'd128 : digital_steer+8'd4;
                else if(digital_steer>128) digital_steer<=digital_steer<132 ? 8'd128 : digital_steer-8'd4;
            end
            case(steering_mode)
                1:adc5<={~steering_axis[7],steering_axis[6:0]};
                2:adc5<=paddle;
                default:adc5<=digital_steer;
            endcase
            // Final Lap R brake pedal (AN6); Speed Racer has no brake ADC (MAME read_safe 0xff).
            adc6<=!flr_controls ? 8'd255 : analog_pedal ? brake : (joy[5] ? 8'd255 : 8'd0);
            adc7<=analog_pedal ? accelerator : (joy[4] ? 8'd255 : 8'd0);
        end
    end
    always @* begin
        case(port6[7:4])
            0:port7=8'hff;
            2:port7={~buttons[10],~(buttons[11]|test_switch),~buttons[9],1'b1,4'hf};
            4:port7={2'b11,~freeze_screen,~(flr_controls & gear),4'b1111};
            6:port7=flr_controls ? 8'hff : {~buttons[5],~buttons[7],~buttons[6],~buttons[8],4'hf};
            default:port7=8'hff;
        endcase
    end
endmodule
